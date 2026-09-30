<#
.SYNOPSIS
  Build script for soulseek-wrapper.aar (.NET Android class library -> AAR).

.DESCRIPTION
  Compiles the C# SoulseekWrapper project into an Android AAR using .NET 9 +
  .NET Android workload, then copies the output into the Flutter Android
  project's libs directory so it is picked up by `fileTree(... *.aar)`.

  ARCHITECTURE NOTE:
  .NET Android has a Catch-22 for class libraries that need Android Callable
  Wrappers (ACW) generated from [Register] attributes:
    * AndroidApplication=false (default for Library) -> _CreateAar target runs,
      but _GenerateJavaStubs does NOT -> no Java stubs, empty AAR.
    * AndroidApplication=true -> _GenerateJavaStubs runs (ACW created), but
      _CreateAar is NOT in the build order -> APK is built, not AAR.

  Solution: build with AndroidApplication=true to get the ACW + native runtime,
  then manually package an AAR from the intermediate artifacts:
    - classes/         -> classes.jar (ACW stubs)
    - mono.android.jar + java_runtime_net6.jar + java-interop.jar + crypto jar
      -> classes.jar (runtime Java)
    - build-APK lib/<abi>/*.so -> jni/<abi>/*.so (full Mono runtime incl. libmonosgen-2.0.so)
    - android/assets/  -> assets/
    - android/AndroidManifest.xml -> AndroidManifest.xml

.PARAMETER Configuration
  Build configuration: "Release" (default) or "Debug".

.PARAMETER Abis
  Android ABIs to target. Default: arm64-v8a (what the shipped AAR contains).
  Also accepted: armeabi-v7a, x64 (packed as jni/x86_64, e.g. for emulators).
  Note: each extra ABI adds a full copy of the .NET runtime to the fat release APK.

.EXAMPLE
  .\build_aar.ps1
  .\build_aar.ps1 -Configuration Debug -Abis arm64-v8a,x64
#>

param(
    [string]$Configuration = "Release",
    [string[]]$Abis = @("arm64-v8a")
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectPath = Join-Path $ScriptDir "SoulseekWrapper.csproj"
$OutputLibsDir = Join-Path $ScriptDir "..\android\app\libs"

# Map friendly ABI names to .NET Android RIDs / native subfolder names.
$AbiMap = @{
    "arm64-v8a"   = "arm64-v8a"
    "armeabi-v7a" = "arm"
    "x64"         = "x86_64"
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " soulseek-wrapper AAR build" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Project:      $ProjectPath"
Write-Host "Configuration:$Configuration"
Write-Host "ABIs:         $($Abis -join ', ')"
Write-Host "Output:       $OutputLibsDir"
Write-Host ""

# --- 1. Verify .NET SDK ---
Write-Host "[1/6] Checking .NET SDK..." -ForegroundColor Yellow
try {
    $dotnetVersion = (dotnet --version 2>$null)
    if (-not $dotnetVersion) {
        throw "dotnet not found on PATH"
    }
    Write-Host "  .NET SDK version: $dotnetVersion" -ForegroundColor Green
} catch {
    Write-Host "ERROR: .NET SDK not found. Install .NET 9 SDK." -ForegroundColor Red
    Write-Host "  https://dotnet.microsoft.com/download/dotnet/9.0" -ForegroundColor Gray
    exit 1
}

# --- 2. Verify .NET Android workload ---
Write-Host "[2/6] Checking .NET Android workload..." -ForegroundColor Yellow
$workloads = (dotnet workload list 2>$null) -join "`n"
if ($workloads -notmatch "android") {
    Write-Host "ERROR: .NET Android workload is not installed." -ForegroundColor Red
    Write-Host "  Install with: dotnet workload install android" -ForegroundColor Gray
    exit 1
}
Write-Host "  .NET Android workload: installed" -ForegroundColor Green

# --- 3. Restore ---
Write-Host "[3/6] Restoring NuGet packages..." -ForegroundColor Yellow
& dotnet restore $ProjectPath
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: dotnet restore failed (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "  Restore: OK" -ForegroundColor Green

# --- 4. Build (AndroidApplication=true for ACW generation) ---
Write-Host "[4/6] Building with ACW generation..." -ForegroundColor Yellow

# Build with AndroidRuntimeIdentifiers for multi-ABI.
# AndroidApplication=true is set in the .csproj so _GenerateJavaStubs runs.
# NB: dotnet build re-tokenizes -p: values on ';' (=> MSB1006 "Property is
# not valid"), so the separator is escaped as %3B; MSBuild unescapes it back
# to ';' when the property is set. Works for any number of ABIs.
$abiList = ($Abis -join ";") -replace ";", "%3B"
& dotnet build $ProjectPath `
    -c $Configuration `
    -p:AndroidPackageFormat=aar `
    -p:AndroidRuntimeIdentifiers="$abiList" `
    -p:AndroidLinkMode=None `
    -p:PublishTrimmed=false `
    -p:RunAOTCompilation=false

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: dotnet build failed (exit $LASTEXITCODE)" -ForegroundColor Red
    exit $LASTEXITCODE
}
Write-Host "  Build: OK" -ForegroundColor Green

# --- 5. Manually package AAR from intermediate artifacts ---
Write-Host "[5/6] Packaging AAR from intermediate artifacts..." -ForegroundColor Yellow

$objAndroidDir = Join-Path $ScriptDir "obj\$Configuration\net9.0-android\android"
$classesDir = Join-Path $objAndroidDir "bin\classes"
# NOTE: app_shared_libraries/ is no longer used for .so extraction.
# .NET Android only places libxamarin-app.so + assemblies blob there (without
# the required "lib" prefix), and omits the Mono runtime (libmonosgen-2.0.so).
# The full native runtime is extracted from the build-APK instead (see jni step).
$assetsDir = Join-Path $objAndroidDir "assets"
$manifestPath = Join-Path $objAndroidDir "AndroidManifest.xml"

# Note: Java interface ISoulseekEventSink is compiled by .NET Android via
# <AndroidJavaSource> in the .csproj - no manual javac needed.
# However, .NET Android places binding .class files in a separate
# "binding\bin\classes" directory, not the main "android\bin\classes".
# We merge them into the main classes dir before building classes.jar.
$bindingClassesDir = Join-Path $ScriptDir "obj\$Configuration\net9.0-android\binding\bin\classes"
if (Test-Path $bindingClassesDir) {
    Write-Host "  Merging binding classes (ISoulseekEventSink)..." -ForegroundColor Gray
    Copy-Item -Path (Join-Path $bindingClassesDir '*') -Destination $classesDir -Recurse -Force
    $bindingCount = (Get-ChildItem $bindingClassesDir -Recurse -Filter *.class).Count
    Write-Host "  Binding classes merged: $bindingCount file(s)" -ForegroundColor Gray
}

# Remove R.class and R$*.class from the classes directory.
# .NET Android generates an R class for the library's resources, but Gradle
# also generates its own R.jar for the AAR's resources. Having both causes
# R8 to fail with "Type soulseek.wrapper.R is defined multiple times".
# The Gradle-generated R class is the correct one; we must not bundle ours.
$rClassDir = Join-Path $classesDir "soulseek\wrapper"
if (Test-Path $rClassDir) {
    $rFiles = Get-ChildItem $rClassDir -Filter "R*.class"
    foreach ($rFile in $rFiles) {
        Remove-Item $rFile.FullName -Force
        Write-Host "  Removed: $($rFile.Name) (conflicts with Gradle R.jar)" -ForegroundColor Gray
    }
}

# Staging directory for AAR contents.
$stagingDir = Join-Path $ScriptDir "obj\$Configuration\aar-staging"
if (Test-Path $stagingDir) { Remove-Item -Recurse -Force $stagingDir }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

# classes.jar from compiled .class files.
if (-not (Test-Path $classesDir)) {
    Write-Host "jar (JDK): not found" -ForegroundColor Red
    Write-Host "  _GenerateJavaStubs may not have run. Check AndroidApplication=true in .csproj." -ForegroundColor Gray
    exit 1
}

# Build classes.jar. Prefer jar (from JDK) for proper JAR format with manifest.
# Look for jar on PATH first, then Android Studio bundled JBR.
$jarExe = $null
$pathJar = Get-Command jar -ErrorAction SilentlyContinue
if ($pathJar) {
    $jarExe = $pathJar.Source
} else {
    $jbrCandidates = @(
        "$env:LOCALAPPDATA\Android\Android Studio\jbr\bin\jar.exe",
        "C:\Program Files\Android\Android Studio\jbr\bin\jar.exe",
        "C:\Program Files\Java\jdk-17.0.3\bin\jar.exe"
    )
    foreach ($j in $jbrCandidates) {
        if (Test-Path $j) { $jarExe = $j; break }
    }
}

$classesJar = Join-Path $stagingDir "classes.jar"
if ($jarExe) {
    Write-Host "  Using jar: $jarExe" -ForegroundColor Gray
    Push-Location $classesDir
    try {
        # Extract runtime Java classes needed by the generated ACW stubs.
        # SoulseekBridge.java references:
        #   mono.android.IGCUserPeer  -> java_runtime_net6.jar (NOT in mono.android.jar)
        #   mono.android.Runtime      -> java_runtime_net6.jar (NOT in mono.android.jar)
        #   mono.android.TypeManager  -> mono.android.jar
        # The two jars have NO overlapping classes in mono/android/, so both
        # can be extracted safely without R8 "defined multiple times" errors.

        # 1) mono.android.jar - reference API jar (TypeManager, etc.)
        $monoAndroidJar = "C:\Program Files\dotnet\packs\Microsoft.Android.Ref.35\35.0.105\ref\net9.0\mono.android.jar"
        if (-not (Test-Path $monoAndroidJar)) {
            $found = Get-ChildItem -Path "C:\Program Files\dotnet\packs" -Recurse -Filter "mono.android.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $monoAndroidJar = $found.FullName }
        }
        if (Test-Path $monoAndroidJar) {
            Write-Host "  Extracting mono.android.jar classes..." -ForegroundColor Gray
            & $jarExe xf "$monoAndroidJar"
            # Clean up META-INF from mono.android.jar to avoid merge conflicts.
            $metaInf = Join-Path $classesDir "META-INF"
            if (Test-Path $metaInf) { Remove-Item -Recurse -Force $metaInf }
        }

        # 2) java_runtime_net6.jar - runtime implementation (IGCUserPeer, Runtime, GCUserPeer, etc.)
        $javaRuntimeJar = "C:\Program Files\dotnet\packs\Microsoft.Android.Sdk.Windows\35.0.105\tools\java_runtime_net6.jar"
        if (-not (Test-Path $javaRuntimeJar)) {
            $foundRt = Get-ChildItem -Path "C:\Program Files\dotnet\packs" -Recurse -Filter "java_runtime_net6.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundRt) { $javaRuntimeJar = $foundRt.FullName }
        }
        if (Test-Path $javaRuntimeJar) {
            Write-Host "  Extracting java_runtime_net6.jar (IGCUserPeer, Runtime)..." -ForegroundColor Gray
            & $jarExe xf "$javaRuntimeJar"
            # Clean up META-INF to avoid merge conflicts.
            $metaInf2 = Join-Path $classesDir "META-INF"
            if (Test-Path $metaInf2) { Remove-Item -Recurse -Force $metaInf2 }
        } else {
            Write-Host "  WARNING: java_runtime_net6.jar not found - IGCUserPeer will be missing!" -ForegroundColor Yellow
        }

        # 3) libSystem.Security.Cryptography.Native.Android.jar - Java classes required by
        #    the native crypto library's JNI_OnLoad. Without these classes, the app crashes
        #    at startup with SIGABRT: "GetClassGRef: class net/dot/android/crypto/
        #    DotnetProxyTrustManager was not found" inside libSystem.Security.Cryptography.
        #    Native.Android.so's JNI_OnLoad (called by MonoRuntimeProvider.attachInfo).
        #    .NET Android normally merges these into classes.dex when building an APK, but
        #    since we manually package the AAR we must extract them ourselves.
        #    The jar ships in the .NET runtime NuGet pack alongside the .so (NOT in the
        #    Android SDK ref packs), so we search the runtime packs directory for it.
        $cryptoJar = $null
        $cryptoJarCandidates = Get-ChildItem -Path "C:\Program Files\dotnet\packs\Microsoft.NETCore.App.Runtime.Mono.android-arm64" -Recurse -Filter "libSystem.Security.Cryptography.Native.Android.jar" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($cryptoJarCandidates) {
            $cryptoJar = $cryptoJarCandidates.FullName
        } else {
            $found = Get-ChildItem -Path "C:\Program Files\dotnet\packs" -Recurse -Filter "libSystem.Security.Cryptography.Native.Android.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $cryptoJar = $found.FullName }
        }
        if ($cryptoJar -and (Test-Path $cryptoJar)) {
            Write-Host "  Extracting crypto jar (DotnetProxyTrustManager, DotnetX509KeyManager, PalPbkdf2)..." -ForegroundColor Gray
            Write-Host "    Source: $cryptoJar" -ForegroundColor DarkGray
            & $jarExe xf "$cryptoJar"
            # Clean up META-INF to avoid merge conflicts.
            $metaInf3 = Join-Path $classesDir "META-INF"
            if (Test-Path $metaInf3) { Remove-Item -Recurse -Force $metaInf3 }
        } else {
            Write-Host "  WARNING: libSystem.Security.Cryptography.Native.Android.jar not found!" -ForegroundColor Yellow
            Write-Host "    The app will crash at startup: GetClassGRef: DotnetProxyTrustManager not found" -ForegroundColor DarkYellow
        }

        # 4) java-interop.jar - Java classes required by the Mono runtime's JNI
        #    initialization (Java.Interop). When the .NET runtime starts, it calls
        #    FindClass("net/dot/jni/ManagedPeer") via JNI. If this class is absent
        #    from the DEX, the runtime throws:
        #      TypeInitializationException: The type initializer for
        #      'Java.Interop.ManagedPeer' threw an exception.
        #        ---> Could not determine Java type corresponding to
        #      `Java.Lang.ClassNotFoundException, Mono.Android, ...`
        #    This cascade crashes the app before any managed code runs.
        #    .NET Android normally merges java-interop.jar into classes.dex when
        #    building an APK; since we manually package the AAR we must extract it
        #    ourselves. The jar ships in the Android SDK tools directory alongside
        #    java_runtime_net6.jar.
        $javaInteropJar = "C:\Program Files\dotnet\packs\Microsoft.Android.Sdk.Windows\35.0.105\tools\java-interop.jar"
        if (-not (Test-Path $javaInteropJar)) {
            $foundJi = Get-ChildItem -Path "C:\Program Files\dotnet\packs" -Recurse -Filter "java-interop.jar" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($foundJi) { $javaInteropJar = $foundJi.FullName }
        }
        if (Test-Path $javaInteropJar) {
            Write-Host "  Extracting java-interop.jar (net/dot/jni/ManagedPeer, JavaProxyThrowable)..." -ForegroundColor Gray
            Write-Host "    Source: $javaInteropJar" -ForegroundColor DarkGray
            & $jarExe xf "$javaInteropJar"
            # Clean up META-INF to avoid merge conflicts.
            $metaInf4 = Join-Path $classesDir "META-INF"
            if (Test-Path $metaInf4) { Remove-Item -Recurse -Force $metaInf4 }
        } else {
            Write-Host "  WARNING: java-interop.jar not found!" -ForegroundColor Yellow
            Write-Host "    The app will crash at startup: FindClass(net/dot/jni/ManagedPeer) -> ClassNotFoundException" -ForegroundColor DarkYellow
        }

        # Build classes.jar: ACW stubs + Java interface + mono.android + runtime + crypto + interop classes.
        & $jarExe cf $classesJar .
        if ($LASTEXITCODE -ne 0) { throw "jar failed with exit $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
    Write-Host "  classes.jar: created (ACW + Java interface + mono.android + runtime)" -ForegroundColor Gray
} else {
    # Fallback: zip the classes and rename.
    Write-Host "  WARNING: jar not found, using Compress-Archive fallback" -ForegroundColor Yellow
    $tempZip = Join-Path $stagingDir "classes.zip"
    Compress-Archive -Path (Join-Path $classesDir '*') -DestinationPath $tempZip -Force
    Move-Item $tempZip $classesJar -Force
    Write-Host "  classes.jar: created via Compress-Archive" -ForegroundColor Gray
}

# jni/<abi>/*.so
#
# CRITICAL: .NET Android places the FULL native runtime (libmonosgen-2.0.so,
# libmonodroid.so, libSystem.Native.so, libSystem.IO.Compression.Native.so,
# libSystem.Security.Cryptography.Native.Android.so,
# libmono-component-marshal-ilgen.so, libassemblies.<abi>.blob.so,
# libxamarin-app.so) in the build-APK's lib/<abi>/, NOT in
# app_shared_libraries/ (which only contains libxamarin-app.so + the
# assemblies blob, and even those are missing the required "lib" prefix).
#
# The previous implementation copied only from app_shared_libraries/, which
# produced an AAR without libmonosgen-2.0.so. At app startup,
# mono.MonoRuntimeProvider.attachInfo() calls System.loadLibrary("monosgen-2.0"),
# which throws UnsatisfiedLinkError: "dlopen failed: library
# libmonosgen-2.0.so not found" and crashes the app before Application.onCreate.
#
# Fix: extract the complete native runtime from the build-APK that .NET Android
# produces (soulseek.wrapper*.apk). The APK's lib/<abi>/ already contains every
# .so with the correct "lib" prefix, ready to be copied into the AAR jni/<abi>/.
$jniDir = Join-Path $stagingDir "jni"
New-Item -ItemType Directory -Path $jniDir -Force | Out-Null
$copiedSo = 0

# Locate the build-APK produced by .NET Android (prefer unsigned; fall back to signed).
$apkDir = Join-Path $ScriptDir "bin\$Configuration\net9.0-android"
$buildApk = Get-ChildItem -Path $apkDir -Filter "soulseek.wrapper*.apk" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '-Signed' } | Select-Object -First 1
if (-not $buildApk) {
    $buildApk = Get-ChildItem -Path $apkDir -Filter "soulseek.wrapper*.apk" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
if (-not $buildApk) {
    Write-Host "ERROR: build-APK not found in $apkDir" -ForegroundColor Red
    Write-Host "  .NET Android did not produce an APK; cannot extract native runtime .so." -ForegroundColor Gray
    Write-Host "  Without libmonosgen-2.0.so the app crashes at startup (MonoRuntimeProvider)." -ForegroundColor Gray
    exit 1
}
Write-Host "  Extracting native runtime from build-APK: $($buildApk.Name)" -ForegroundColor Gray

# Unpack the build-APK (it's a zip) to a temp dir. Expand-Archive requires .zip.
$apkExtractZip = Join-Path $ScriptDir "obj\$Configuration\apk-extract.zip"
$apkExtractDir = Join-Path $ScriptDir "obj\$Configuration\apk-extract"
if (Test-Path $apkExtractDir) { Remove-Item -Recurse -Force $apkExtractDir }
Copy-Item $buildApk.FullName $apkExtractZip -Force
Expand-Archive $apkExtractZip -DestinationPath $apkExtractDir -Force

# ABI mapping: friendly name -> APK lib/ folder name.
# (Note: app_shared_libraries used "arm" for armeabi-v7a, but the APK lib/
#  folder uses the canonical "armeabi-v7a".)
$ApkAbiMap = @{
    "arm64-v8a"   = "arm64-v8a"
    "armeabi-v7a" = "armeabi-v7a"
    "x64"         = "x86_64"
}

foreach ($abi in $Abis) {
    $apkAbi = $ApkAbiMap[$abi]
    $soDir = Join-Path $apkExtractDir "lib\$apkAbi"
    if (Test-Path $soDir) {
        # jni/<abi> must use the canonical Android ABI name (x86_64, not x64),
        # otherwise AGP's mergeNativeLibs fails with "... is not an ABI".
        $destAbiDir = Join-Path $jniDir $apkAbi
        New-Item -ItemType Directory -Path $destAbiDir -Force | Out-Null
        Get-ChildItem $soDir -Filter *.so | ForEach-Object {
            Copy-Item $_.FullName $destAbiDir -Force
            $copiedSo++
        }
        $soCount = (Get-ChildItem $destAbiDir -Filter *.so).Count
        Write-Host "  jni/$apkAbi : $soCount .so files (incl. libmonosgen-2.0.so runtime)" -ForegroundColor Gray
    } else {
        Write-Host "  WARNING: no .so for $abi at $soDir (ABI not built by .NET Android)" -ForegroundColor Yellow
    }
}

# assets/ (.NET assemblies + machine.config)
if (Test-Path $assetsDir) {
    $destAssets = Join-Path $stagingDir "assets"
    Copy-Item $assetsDir $destAssets -Recurse -Force
    $assetCount = (Get-ChildItem $destAssets -Recurse -File).Count
    Write-Host "  assets: $assetCount files" -ForegroundColor Gray
}

# AndroidManifest.xml
if (Test-Path $manifestPath) {
    Copy-Item $manifestPath (Join-Path $stagingDir "AndroidManifest.xml") -Force
    Write-Host "  AndroidManifest.xml: copied" -ForegroundColor Gray
}

# Package the AAR (it's a zip).
$aarDir = Join-Path $ScriptDir "bin\$Configuration"
if (-not (Test-Path $aarDir)) { New-Item -ItemType Directory -Path $aarDir -Force | Out-Null }
$aarPath = Join-Path $aarDir "soulseek-wrapper.aar"
if (Test-Path $aarPath) { Remove-Item $aarPath -Force }

# Compress-Archive only supports .zip extension; create .zip then rename to .aar.
$tempZip = Join-Path $aarDir "soulseek-wrapper.zip"
if (Test-Path $tempZip) { Remove-Item $tempZip -Force }

$oldProgress = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'
try {
    Compress-Archive -Path (Join-Path $stagingDir '*') -DestinationPath $tempZip -Force
} finally {
    $ProgressPreference = $oldProgress
}
Move-Item $tempZip $aarPath -Force

$aarSize = (Get-Item $aarPath).Length
$aarMB = [math]::Round($aarSize / 1MB, 2)
Write-Host "  AAR: $aarPath ($aarMB MB)" -ForegroundColor Green

# --- 6. Copy AAR to android/app/libs ---
Write-Host "[6/6] Copying AAR to android/app/libs..." -ForegroundColor Yellow

if (-not (Test-Path $OutputLibsDir)) {
    New-Item -ItemType Directory -Path $OutputLibsDir -Force | Out-Null
    Write-Host "  Created: $OutputLibsDir" -ForegroundColor Gray
}

$destAar = Join-Path $OutputLibsDir "soulseek-wrapper.aar"
Copy-Item $aarPath $destAar -Force
Write-Host "  Copied: soulseek-wrapper.aar ($aarMB MB)" -ForegroundColor Green

# --- Summary ---
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " BUILD COMPLETE" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AAR:        $aarPath"
Write-Host "  Size:       $aarMB MB"
Write-Host "  .so files:  $copiedSo"
Write-Host "  Target dir: $OutputLibsDir"
Write-Host ""
Write-Host "Notes:" -ForegroundColor Yellow
Write-Host "  - The AAR contains .NET runtime (libxamarin-app.so + assemblies blob)."
Write-Host "    Kotlin calls SoulseekBridge via JNI; the Mono runtime is bootstrapped"
Write-Host "    by the Java stubs (MonoRuntimeProvider)."
Write-Host "  - Trim/AOT are currently disabled for reliability. Re-enable in"
Write-Host "    SoulseekWrapper.csproj for smaller output once the bridge is verified."
Write-Host ""
