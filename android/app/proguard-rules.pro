## 1. Flutter 引擎基礎規則
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.editing.** { *; }
-keep class io.flutter.plugin.common.** { *; }
-keep class io.flutter.embedding.** { *; }
-keep class io.flutter.plugins.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

## 2. 保持原生 MethodChannel 通訊不被混淆
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

## 3. 處理 AndroidX 和支援庫
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**
-keep class androidx.** { *; }
-dontwarn androidx.**

## 4. 針對 Flutter 3.x 特定的引擎入口
-keep class io.flutter.embedding.android.FlutterActivity { *; }
-keep class io.flutter.embedding.android.FlutterFragment { *; }
-keep class io.flutter.embedding.android.FlutterView { *; }

## 5. 常見第三方插件兼容 (如需使用 Firebase 或 OkHttp)
-dontwarn okio.**
-dontwarn javax.annotation.**
-keepnames class com.fasterxml.jackson.** { *; }
-keepnames class com.google.api.** { *; }

## 6. 避免壓縮掉 Native 方法
-keepclasseswithmembernames class * {
    native <methods>;
}
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
-keep class tv.danmaku.ijk.media.player.** {*; }
-dontwarn tv.danmaku.ijk.media.**
-keep interface tv.danmaku.ijk.media.player.** { *; }
## 7. TVBox 爬虫宿主契约（catvod-api.jar）
# spider.jar 在运行时才由 DexClassLoader 加载，R8 静态分析看不到任何引用，
# 不加 keep 会把 catvod-api 里的类整体当死代码删掉，随后反射加载
# spider.jar 时基类找不到 → NoClassDefFoundError。
# 同理类名与方法名都不能混淆：spider.jar 里的类是按字面名继承 Spider 的。
-keep class com.github.catvod.** { *; }
-keep interface com.github.catvod.** { *; }
-dontwarn com.github.catvod.**

# 宿主侧桥接类由 Dart 按固定名字调用，混淆后方法名变化会破坏协议。
-keep class com.mystyle.purelive.tv.VodSpiderBridge { *; }

# okhttp3/OkHttp 由 okhttp 4.12.0 自身提供，catvod 的 Util 只读它的 VERSION
# 静态字段（见 THIRD_PARTY_NOTICES.md 里那次误判纠正）。显式 keep 是防御性的。
-keep class okhttp3.OkHttp { *; }

# QuickJS 运行时（#63）。
# com.fongmi.quickjs.QuickJS / QuickJSContext 的方法由 libquickjs-wrapper.so 通过
# JNI 按字面名查找，混淆后 native 注册会直接失败，所以整包保留。
# catvod 的 com.github.catvod.utils.Js 还会反射实例化
# com.fongmi.quickjs.RuntimeEntry，类名同样不能变。
-keep class com.fongmi.quickjs.** { *; }
-keep interface com.fongmi.quickjs.** { *; }
-dontwarn com.fongmi.quickjs.**

# 注意：不要 -keep com.dylibso.chicory.**。
# 那是 wrapper-java.jar 里附带的纯 Java WASM 解释器，只有 com.fongmi.quickjs.Wasm*
# 引用它，而 Wasm* 在 native 路径下没有调用方；放开 keep 会让 APK 多出约 700 KB
# 死代码。这里只消除「被裁掉之后的残留引用」告警。
-dontwarn com.dylibso.**

# Python 运行时（#64）。
# com.chaquo.python.** 的 Java↔Python 互操作大量依赖反射（PyObject 方法解析、
# android 模块的 initialize/import 回调），必须整包保留；Chaquopy 自身带有
# consumer rules，这里再声明一次是为了防止被 minify 顺手裁掉。
# com.fongmi.chaquo.** 是 Python 侧通过 `from com.github.catvod import Proxy`
# 这类语句反向引用的宿主类，名字同样不能变。
-keep class com.chaquo.** { *; }
-dontwarn com.chaquo.**
-keep class com.fongmi.chaquo.** { *; }
-dontwarn com.fongmi.chaquo.**
-keep class com.github.catvod.runtime.PythonRuntime { *; }

# SpiderDebug / Path 通过 com.orhanobut.logger 输出日志。该库大量依赖反射与
# 泛型擦除后的 StringBuilder 拼接，R8 全量混淆会让日志直接抛异常；而多数
# spider 在 init 阶段就会打日志，异常会冒泡成失败。关掉它的混淆。
-keep class com.orhanobut.logger.** { *; }
-dontwarn com.orhanobut.logger.**

# net/OkDns 的 DoH 走 okhttp-dnsoverhttps，内部引用 Kotlin 协程与 metadata。
-dontwarn okhttp3.dnsoverhttps.**
-dontwarn org.jetbrains.annotations.**

-dontwarn org.slf4j.**
-dontwarn com.hierynomus.**
-dontwarn javax.annotation.**
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
