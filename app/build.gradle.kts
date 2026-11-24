plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val supabaseUrl = providers.gradleProperty("SUPABASE_URL").orElse("").get()
val supabaseAnonKey = providers.gradleProperty("SUPABASE_ANON_KEY").orElse("").get()
val publicProfileBaseUrl = providers.gradleProperty("PUBLIC_PROFILE_BASE_URL").orElse("").get()

android {
    namespace = "zw.co.tempest.tapcard"
    compileSdk = 35

    defaultConfig {
        applicationId = "zw.co.tempest.tapcard"
        minSdk = 26
        targetSdk = 35
        versionCode = 6
        versionName = "1.5.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "SUPABASE_URL", "\"$supabaseUrl\"")
        buildConfigField("String", "SUPABASE_ANON_KEY", "\"$supabaseAnonKey\"")
        buildConfigField("String", "PUBLIC_PROFILE_BASE_URL", "\"$publicProfileBaseUrl\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.10.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
}
