# ProGuard / R8 keep rules for the Soulseek .NET wrapper integration.
#
# Flutter's Gradle plugin force-enables R8 shrinking (isMinifyEnabled = true)
# for release builds by default (see FlutterPlugin.kt ~line 262). R8 removes
# any class that has no Java/Kotlin reference — even if the class is loaded
# via JNI from native code.
#
# The .NET Android runtime ships several Java helper classes that are ONLY
# referenced from native libraries' JNI_OnLoad / JNI calls:
#
#   • net.dot.android.crypto.*  — loaded by libSystem.Security.Cryptography.
#     Native.Android.so's JNI_OnLoad. Without these, the app crashes at
#     startup with SIGABRT:
#       "GetClassGRef: class net/dot/android/crypto/DotnetProxyTrustManager
#        was not found"
#
#   • mono.android.*            — loaded by libmonodroid.so / libxamarin-app.so.
#     These survive R8 in normal .NET Android builds because the generated
#     ACW stubs reference them, but we keep them explicitly for safety.
#
#   • mono.MonoRuntimeProvider  — declared in the AAR's AndroidManifest as a
#     <provider>, so R8 keeps it. Listed here for documentation.
#
# This file is automatically picked up by FlutterPlugin.kt (line 277-278):
#   if (File("${project.projectDir}/proguard-rules.pro").exists()) {
#       proguardFile("proguard-rules.pro")
#   }

# ──────────────────────────────────────────────────────────────────────────────
# CRITICAL: Disable obfuscation entirely.
#
# R8 not only *removes* unused classes (shrinking) but also *renames* them
# (obfuscation).  The .NET Android / Mono runtime performs JNI FindClass()
# lookups using the ORIGINAL Java class names (e.g. "mono/ManagedPeer",
# "mono/android/TypeManager").  If R8 renames "mono.ManagedPeer" → "mono.a",
# the JNI lookup fails with ClassNotFoundException, which cascades into a
# TypeInitializationException in Java.Interop.ManagedPeer — crashing the app
# at startup before any managed code runs.
#
# -dontobfuscate keeps all class/method names intact while still allowing R8
# to *remove* genuinely unused code (tree-shaking).  The -keep rules below
# prevent removal of the JNI-referenced classes.
# ──────────────────────────────────────────────────────────────────────────────
-dontobfuscate

# --- .NET Android crypto PAL classes (JNI-referenced, no Java/Kotlin refs) ---
-keep class net.dot.android.crypto.** { *; }

# --- Java.Interop classes (JNI-referenced by Mono runtime, no Java/Kotlin refs) ---
# The .NET runtime calls FindClass("net/dot/jni/ManagedPeer") during JNI init.
-keep class net.dot.jni.** { *; }

# --- .NET Android / Xamarin mono runtime classes (JNI-referenced) ---
# Keep the ENTIRE mono.** package — the runtime references many classes
# (ManagedPeer, TypeManager, Runtime, MonoRuntimeProvider, MonoPackageManager,
# GCUserPeer, etc.) via JNI by their original names.
-keep class mono.** { *; }

# --- Soulseek wrapper ACW stub (JNI-referenced from Kotlin, but keep for safety) ---
-keep class soulseek.wrapper.** { *; }
