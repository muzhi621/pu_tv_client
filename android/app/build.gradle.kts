import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

// Signing material lives outside version control. When it is missing the build
// still succeeds and falls back to the debug key, so a checkout without the
// release keystore can be built and run.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use(::load)
    }
}
val releaseStoreFile = keystoreProperties.getProperty("storeFile")?.let(::file)
val hasReleaseSigning = listOf("keyAlias", "keyPassword", "storePassword").all {
    !keystoreProperties.getProperty(it).isNullOrBlank()
} && releaseStoreFile?.isFile == true

android {
    namespace = "com.mystyle.purelive.tv"

    buildFeatures {
        buildConfig = true
    }

    // 电视端只保留中文：AGP 会把 app 与所有依赖库里 values-xx 的非中文语言
    // 资源在打包时剔除（默认 values/ 与 values-zh* 保留）。系统为非中文时
    // 第三方库回退到默认字符串，不会缺资源崩溃。
    // 注意：这只作用于 Android res；应用内 easy_localization 的
    // assets/translations/{zh,en}.json 属于 Flutter asset，不受影响。
    androidResources {
        localeFilters += listOf("zh")
    }

    // 电视盒子下载/侧载的是 APK 文件本身，体积优先。
    // 默认（extractNativeLibs=false）要求 .so 以「未压缩 + 页对齐」存进 APK，
    // 仅四个大库就占 62 MB；改成 legacy packaging 后 .so 走 deflate 压缩，
    // 实测整包可从 74 MB 降到约 38 MB。代价是安装时系统把 .so 解压到
    // /data/app/.../lib，安装后 APK + 解压库合计约 100 MB、首次安装稍慢。
    // 业务逻辑与 native 加载方式（System.loadLibrary）完全不变。
    // 回退：删掉本块 + 清单里的 android:extractNativeLibs="true" 即可。
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // Pinned rather than inherited so the TV build does not silently shift when
    // the Flutter SDK bumps its defaults.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.mystyle.purelive.tv"
        // FFmpeg (ffmpeg_kit_extended_flutter) requires API 26; the DASH merge
        // relay in media_core_ingest shells out to it for bilibili's split
        // audio+video streams. The compat branch keeps Flutter's lower floor
        // and uses mpv's audio-files side channel instead.
        minSdk = 26
        targetSdk = 37
        multiDexEnabled = true
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = releaseStoreFile
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    // Two renderer variants share one applicationId, so a device treats them
    // as the same app and the user simply picks which APK to install:
    //   impeller — engine default renderer, no manifest override
    //   skia     — legacy renderer for boxes where Impeller misbehaves
    //   (the EnableImpeller opt-out lives in src/skia/AndroidManifest.xml and
    //   only merges into the skia variant)
    flavorDimensions += "renderer"
    productFlavors {
        create("impeller") { dimension = "renderer" }
        create("skia") { dimension = "renderer" }
    }

    buildTypes {
        // Debug builds reuse the release key when it is available, so a debug
        // APK can replace an installed release build without uninstalling first.
        val signing = if (hasReleaseSigning) {
            signingConfigs.getByName("release")
        } else {
            signingConfigs.getByName("debug")
        }
        release {
            signingConfig = signing
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                file("proguard-rules.pro")
            )
        }
        debug {
            signingConfig = signing
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
