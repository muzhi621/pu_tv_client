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
    namespace = "com.mystyle.sutv.tv"

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

    // 这里刻意保持 target 17（现有链路都在 17 上验证过），但**编译用的 JDK
    // 必须是 21**：catvod-api.jar 是上游用 Java 21 编的（class major 65），
    // javac 17 读不了，会报 "class file has wrong version 65.0, should be 61.0"。
    // 之前只有 Kotlin 引用这个 jar（Kotlin 编译器不校验 class 版本）所以问题
    // 一直没暴露，加入 src/main/java/com/github/catvod 的 Java 源码后才触发。
    // 对应 CI 配置见 .github/workflows/*.yml 的 java-version: "21"。
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "com.mystyle.sutv.tv"
        // FFmpeg (ffmpeg_kit_extended_flutter) requires API 26; the DASH merge
        // relay in media_core_ingest shells out to it for bilibili's split
        // audio+video streams. The compat branch keeps Flutter's lower floor
        // and uses mpv's audio-files side channel instead.
        minSdk = 26
        // **刻意保持 36，不要跟着升到 37。**
        //
        // Android 17（SDK 37）新增行为变更「Safer DCL」：targetSdk >= 37 且
        // 设备是 Android 17+ 时，`System.load()` 加载的文件**必须只读**，否则抛
        //   UnsatisfiedLinkError: Attempt to load writable file: <path>
        //
        // TVBox 生态的加固 jar（wexguard / ftyguard）必然踩中：它们把 native 库
        // 从 jar 内 assets 释放到自己的 cacheDir 再 `System.load`，写出来的文件
        // 一定是 app 可写的（FileOutputStream 默认权限），宿主**无法**在它
        // 写完之后、load 之前插手把文件改成只读。
        //
        // 触发条件是「设备 Android 17+」**且**「targetSdk >= 37」两条同时成立，
        // 缺一条就保持旧的宽松行为。所以降到 36 即可恢复（compileSdk 仍保持 37，
        // 新 API 照常可用）。上游 FongMi 同样是 37，在 Android 17 上跑这些加固
        // jar 也是坏的——我们降到 36 是刻意向 TVBox 生态兼容。
        //
        // 代价：Android 17 其余按 targetSdk 37 门控的行为变更（本地网络访问默认
        // 拦截、大屏方向限制等）不再对我们生效，这些限制对本项目都是多余的。
        targetSdk = 36
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
    //   impeller — engine default renderer, autoselects Vulkan/GLES backend
    //   skia     — compatibility build, kept under the legacy "skia" name so
    //   existing downloads/update links keep working; it uses the same engine
    //   renderer selection (src/skia/AndroidManifest.xml deliberately sets no
    //   renderer override: the old EnableImpeller=false path black-screens on
    //   Flutter 3.50, and ImpellerBackend is ignored in release builds)
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

/**
 * TVBox 爬虫运行时宿主依赖。
 *
 * 第三方 spider.jar 是用 `compileOnly` 编译的（见 FongMi/CatVodSpider 的
 * app/build.gradle），jar 里只有 `com.github.catvod.spider.*` 等业务类，
 * 而下面这些「宿主契约」必须由 APK 自己提供，否则反射加载时立刻
 * NoClassDefFoundError：
 *
 *   com.github.catvod.crawler.Spider   基类，jar 里的类全继承它
 *   com.github.catvod.net.*            OkHttp 封装（Spider.net 字段）
 *   com.github.catvod.utils.*          Local / Js / Dialog / Task / Decoder
 *
 * catvod-api.jar 只有 148 KB，直接打进 classes.dex 供 DexClassLoader 的
 * parent 使用——这正是 TVBox 家族的通行做法。
 *
 * 注意 androidx.preference：catvod-api 的 utils.Prefers 只用到
 * PreferenceManager.getDefaultSharedPreferences 一个静态方法，但这里**不能**
 * 自己写同名 shim——构建实测该库已随其他插件作为传递依赖进入 classpath
 * （preference-1.2.1-runtime.jar），自建 shim 会让 R8 报
 * "Type androidx.preference.PreferenceManager is defined multiple times"。
 */
dependencies {
    implementation(files("libs/catvod-api.jar"))

    // QuickJS 的 Java 绑定（com.fongmi.quickjs.QuickJS / QuickJSContext / ModuleBytecodeCache…），
    // 来自 FongMi/TV 的 quickjs/libs/wrapper-java.jar（commit b27ba75，GPL-3.0）。
    // 该 jar 里还带了 com.dylibso.chicory（纯 Java WASM 解释器），只有 com.fongmi.quickjs.Wasm*
    // 引它，而 Wasm* 自身没有静态调用方，release 构建时由 R8 一并裁掉。
    // 配套的 libquickjs-wrapper.so 见 src/main/jniLibs/{arm64-v8a,armeabi-v7a}。
    implementation(files("libs/quickjs-wrapper.jar"))

    // com.fongmi.quickjs.utils.HtmlQuery 用 jsoup 实现 JS 侧的 html 选择器
    // （Selector.evaluatorOf / NodeTraversor / DataNode 等），版本与上游一致。
    implementation("org.jsoup:jsoup:1.23.2")

    // catvod-api 的 net 包全部方法签名直接暴露 okhttp3 类型，版本需 >= 3.14。
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    // gson 2.11 才引入 Strictness，catvod-api 的 utils 用到了它。
    implementation("com.google.code.gson:gson:2.11.0")
    // com.github.catvod.utils.Task / Decoder 用 Futures、MoreExecutors。
    // R8 会按实际引用裁剪，最终增量只有几十 KB。
    implementation("com.google.guava:guava:33.8.0-android")

    // ---- 以下是 src/main/java/com/github/catvod 那批「运行时实现类」的依赖 ----
    // 这些类不在 catvod-api.jar 里（上游 apiJar task 是白名单导出，只导出 spider
    // 编译需要的契约类），由宿主 App 提供实现。缺任何一个，spider 走到对应分支
    // 就是 NoClassDefFoundError。

    // net/OkHttp 用 ArrayMap 收集请求头。
    implementation("androidx.collection:collection:1.4.5")
    // crawler/SpiderDebug 与 utils/Path 用 Logger.t(tag).d(msg)、Printer。
    // 与上游同款（libs.logger = com.orhanobut:logger:2.2.0），API 完全一致。
    implementation("com.orhanobut:logger:2.2.0")
    // utils/Prefers 用 PreferenceManager。上游 preference = 1.2.1。
    // 注意：此前曾因手写 PreferenceManager shim 与这个包的传递依赖重复而编译失败，
    // 现在改为显式声明同一 artifact，由 Gradle 去重。
    implementation("androidx.preference:preference:1.2.1")
    // net/Download$MainThread 用 androidx.core.os.HandlerCompat。
    implementation("androidx.core:core:1.13.1")
    // net/OkDns 用 okhttp3.dnsoverhttps.DnsOverHttps 做 DoH 解析。
    implementation("com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0")
    // net/OkHttp 用 HttpLoggingInterceptor。版本必须与 okhttp 保持一致，
    // 混版本会导致 Interceptor 接口不匹配。
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
}
