import java.util.Properties

plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val configuredGoogleMapsApiKey = project.findProperty("GOOGLE_MAPS_API_KEY")?.toString()
    ?: System.getenv("GOOGLE_MAPS_API_KEY")
    ?: "REPLACE_WITH_GOOGLE_MAPS_API_KEY"

val signingProperties = Properties()
val signingPropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = signingPropertiesFile.isFile && run {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !signingProperties.getProperty(it).isNullOrBlank() }
}

android {
    namespace = "com.farmanorte.farmanorte_domiciliarios"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.farmanorte.farmanorte_domiciliarios"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        manifestPlaceholders["googleMapsApiKey"] = configuredGoogleMapsApiKey
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfigs.create("farmanorteRelease") {
                    storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
                    storePassword = signingProperties.getProperty("storePassword")
                    keyAlias = signingProperties.getProperty("keyAlias")
                    keyPassword = signingProperties.getProperty("keyPassword")
                }
                signingConfig = signingConfigs.getByName("farmanorteRelease")
            } else if (project.findProperty("allowDebugSigning") == "true") {
                // Solo para QA local. Nunca usar esta bandera para entregar el APK.
                signingConfig = signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "Falta android/key.properties. Configura un keystore de release; " +
                        "usa -PallowDebugSigning=true únicamente para una compilación local de QA."
                )
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
