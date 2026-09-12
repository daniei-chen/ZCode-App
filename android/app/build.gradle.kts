import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
    val required = listOf("keyAlias", "keyPassword", "storeFile", "storePassword")
    val missing = required.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    require(missing.isEmpty()) {
        "android/key.properties is missing: ${missing.joinToString()}; refusing a release build"
    }
}

android {
    namespace = "com.zcode.app"
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
        applicationId = "com.zcode.app"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 发布契约是 arm64 单包。`--target-platform` 只过滤 Flutter 自家库
    // （libflutter/libapp），插件 AAR 的原生库（ML Kit、camera 等）仍会按
    // 三 ABI 打进去，且新 gradle 插件无视 ndk.abiFilters——只能在 AGP
    // packaging 层强制剔除（v1.0.7 CI 实测）。
    packaging {
        jniLibs {
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/x86_64/**",
            )
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Never fall back to the debug key. The release task below fails
            // when the official keystore is absent instead of producing an
            // apparently publishable APK with the wrong upgrade identity.
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

val requireReleaseSigning = tasks.register("requireReleaseSigning") {
    doLast {
        if (!keystorePropertiesFile.exists()) {
            throw GradleException(
                "Release signing is required. Restore android/key.properties and the release keystore first.",
            )
        }
    }
}

tasks.configureEach {
    val task = name.lowercase()
    if (task == "assemblerelease" ||
        task == "bundlerelease" ||
        task == "packagerelease") {
        dependsOn(requireReleaseSigning)
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
