plugins {
    id("com.android.application")
}

android {
    namespace = "com.healthconnect.export"
}

dependencies {
    implementation("androidx.health.connect:connect-client:1.1.0")
    implementation("androidx.work:work-runtime-ktx:2.12.0")
    implementation("androidx.documentfile:documentfile:1.0.1")
}
