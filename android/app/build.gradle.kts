import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Загружаем данные подписи из android/key.properties (если файл есть).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}


android {
    namespace = "com.player.player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.player.player"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        // Hotfix 3.0.1 — стабильный релиз: versionName снова берётся из
        // pubspec (flutter.versionName), как и до беты 3.0.0-beta.
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // Resolve storeFile relative to the android/ directory so the
                // path in key.properties matches the actual file location
                // (e.g. app/player-release.jks -> android/app/player-release.jks).
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Всегда подписываем постоянным release-ключом.
            // Если key.properties нет — намеренно роняем сборку, чтобы
            // случайно не раздать debug-подписанный APK: у debug-keystore
            // на каждой машине свой сертификат, и такой APK не встанет
            // поверх у пользователей (INSTALL_FAILED_UPDATE_INCOMPATIBLE).
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "android/key.properties не найден. Release-сборка требует постоянный release-keystore."
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }
}


flutter {
    source = "../.."
}

dependencies {
    // Required by flutter_local_notifications for Java 8+ core library APIs.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")

    // VolumeProviderCompat + MediaSessionCompat для remote volume
    // (управление громкостью в фоне и на локскрине через MediaSession).
    implementation("androidx.media:media:1.7.0")

    // Soulseek .NET wrapper (AAR) — собирается из soulseek-wrapper/ через build_aar.ps1
    // и копируется в android/app/libs/. Содержит SoulseekBridge (JNI-вызываемый адаптер
    // протокола Soulseek). Аудиобайты остаются в нативном слое; через Platform Channel
    // идут только метаданные и команды.
    implementation(fileTree(mapOf("dir" to "libs", "include" to listOf("*.aar", "*.jar"))))

    // MasterKey / EncryptedSharedPreferences для SecureStorageDiagnostics.
    // Та же версия, что у flutter_secure_storage 9.2.4 — библиотека уже в
    // APK через плагин, здесь она нужна только на compile classpath app.
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Kotlin Coroutines — нужна для Kotlin-стороны Platform Channel (Фаза 2):
    // мост между асинхронными вызовами SoulseekBridge (блокирующие C# методы) и корутинами.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
