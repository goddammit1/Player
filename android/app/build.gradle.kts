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
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
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
    // VolumeProviderCompat + MediaSessionCompat для remote volume
    // (управление громкостью в фоне и на локскрине через MediaSession).
    implementation("androidx.media:media:1.7.0")
}
