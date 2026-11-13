pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.4.0" apply false
    // AGP 9 compiles Kotlin itself; declaring the standalone Kotlin Gradle
    // Plugin as well duplicates the compiler used by the vendored plugins.
    //
    // Python 运行时（#64）。17.2.0 官方声明支持 AGP 7.3～9.5，本项目是 9.4.0；
    // 且 17.0.0 专门修过「Chaquopy 与 Android 插件都写在 settings.gradle 的
    // plugins 块里」这个 Flutter 场景（chaquopy#1289）。
    // 插件本体与 com.chaquo.python.runtime:chaquopy_java 都在 Maven Central，
    // 不需要额外仓库。Python 版本固定在 3.10：3.11 及更早才支持 32 位 ABI，
    // 而本项目的 v7a 包必须保留。
    id("com.chaquo.python") version "17.2.0" apply false
}

include(":app")
