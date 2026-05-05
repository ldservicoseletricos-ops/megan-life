plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    
    buildFeatures {
        buildConfig = true
    }
namespace = "com.luiz.meganlife"
    compileSdk = 36

    ndkVersion = "28.2.13676358"

    defaultConfig {
        
        val picovoiceAccessKey = project.findProperty("PICOVOICE_ACCESS_KEY")?.toString()
            ?: System.getenv("PICOVOICE_ACCESS_KEY")
            ?: ""
        buildConfigField("String", "PICOVOICE_ACCESS_KEY", "\"$picovoiceAccessKey\"")
applicationId = "com.luiz.meganlife"
        minSdk = 26
        targetSdk = 36
        versionCode = 702
        versionName = "7.0.2"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("ai.picovoice:porcupine-android:4.0.0")
}
