package com.mystyle.sutv.tv

import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import dalvik.system.DexClassLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile

/**
 * TVBox 爬虫（spider.jar）宿主桥。
 *
 * ## 背景
 *
 * TVBox 生态里，一个「源」由一份 json 配置 + 一个 spider.jar 组成。站点
 * 里 `api` 以 `csp_` 开头表示「这个站点的逻辑在 jar 里」，宿主需要：
 *
 *   1. 把 jar 落到本地并交给 DexClassLoader
 *   2. 反射 new `com.github.catvod.spider.<名字>` 并调用 `init(Context, ext)`
 *   3. 之后按站点调用 homeContent / categoryContent / detailContent /
 *      searchContent / playerContent，方法返回**原始 json 字符串**
 *
 * 第 3 步返回的是 json 文本而不是对象，是有意为之：字段结构由各 spider
 * 自己决定，宿主只做透传解析，Dart 侧拿到的就是原文，遇到不认识的字段
 * 也不会丢。
 *
 * ## 三个必须踩准的点
 *
 * - **jar 不自带基类**。第三方 spider 用 `compileOnly` 编 catvod-api.jar，
 *   产物里只有业务类。基类 `com.github.catvod.crawler.Spider` 及
 *   net/utils 由本 app 提供（见 build.gradle.kts 的 dependencies），
 *   DexClassLoader 的 parent 设为 app 的 ClassLoader 即可命中。
 * - **targetSdk 34+ 要求 dex 文件只读**。Android 14 起 DexClassLoader
 *   拒绝加载可写文件，因此下载完成后必须先 chmod 只读再交给加载器。
 * - **init 只能调一次，且两参优先**。FongMi / Q 版基类的
 *   `init(Context, String)` 默认实现都会自己转调 `init(Context)`；若宿主
 *   再补调一次一参版，override 了两参版的 spider 会被重复初始化甚至重置
 *   状态（FongMi `SpiderLoader.createSpider` 就只调两参版）。只有极老的
 *   jar 才只有一参签名，那种情况才退到一参。
 *
 * ## 为什么每个方法都返回结构化的失败原因
 *
 * 这套链路在本机无法验证（没有 Android 运行时），只能真机跑。失败时
 * 光说「失败了」没有意义——必须能区分「jar 下不下来」「类名不对」
 * 「缺宿主依赖」「spider 自己抛异常」四种情况，否则排查成本极高。
 */
internal class VodSpiderBridge(
    private val context: Context,
    binaryMessenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "VodSpider"
        private const val CHANNEL = "pure_live/vod_spider"

        /** 与 Dart 侧约定的调用超时；spider 内部会发网络请求，放宽到 40s。 */
        private const val CALL_TIMEOUT_SECONDS = 40L

        private const val MAX_JAR_BYTES = 32L * 1024 * 1024
        private const val JAR_DIR = "vod_spider"
        private const val DEX_DIR = "vod_spider_dex"

        /** dex 字符串池里的 spider 类描述符：`Lcom/github/catvod/spider/Xxx;`。 */
        private val DEX_CLASS_RE = Regex("Lcom/github/catvod/spider/([A-Za-z0-9_$]{1,80});")

        /** dex 字符串池里的可打印串（ASCII），用于加固/保护模式探测。 */
        private val DEX_STRING_RE = Regex("[\\x20-\\x7e]{4,120}")

        /**
         * 基础链路必须提供的契约类（全部来自 catvod-api.jar 与宿主三方库）。
         * 只查 `Spider` 一个是不够的：jar 里的 Spider/Net/Json 会互相引用，
         * 少任何一个都会在反射调用时才 NoClassDefFoundError。
         */
        private val REQUIRED_HOST_CLASSES = listOf(
            "com.github.catvod.crawler.Spider",
            "com.github.catvod.crawler.SpiderDebug",
            "com.github.catvod.Proxy",
            "com.github.catvod.Runtime",
            "com.github.catvod.net.Net",
            "com.github.catvod.net.Download",
            "com.github.catvod.utils.Json",
            "com.github.catvod.utils.Path",
            "com.github.catvod.utils.Prefers",
            "com.github.catvod.utils.Util",
            "com.github.catvod.utils.UriUtil",
            "com.github.catvod.utils.Archive",
            "com.github.catvod.utils.Crypto",
            "com.github.catvod.utils.Decoder",
            "com.github.catvod.utils.Dialog",
            "com.github.catvod.utils.Js",
            "com.github.catvod.utils.Local",
            "com.github.catvod.utils.Task",
            "okhttp3.OkHttpClient",
            "com.google.gson.Gson",
            "com.google.common.util.concurrent.MoreExecutors",
            // utils/Js 走 RuntimeModule.QUICKJS.entry(...)，类必须存在（#63）。
            "com.github.catvod.utils.RuntimeModule",
        )

        /**
         * 由宿主 App 提供的运行时实现类。
         *
         * FongMi 的 `apiJar` task 是**白名单导出**（见其根 build.gradle 的 include
         * 列表：`net/Net*.class` 匹配不到 `OkHttp`/`CacheOptions`），所以这批类
         * 只在宿主里存在。我们的宿主源码在 `src/main/java/com/github/catvod/`
         * 下（14 个文件，来源与许可证见各文件头），这里逐个核实它们真的进了
         * APK —— R8 配置漏写或依赖漏声明都会导致整批消失。
         */
        private val RUNTIME_HOST_CLASSES = listOf(
            "com.github.catvod.net.OkHttp",
            "com.github.catvod.net.OkDns",
            "com.github.catvod.net.CacheOptions",
            "com.github.catvod.net.OkAuthenticator",
            "com.github.catvod.net.OkProxySelector",
            "com.github.catvod.net.ProxyRedirectInterceptor",
            "com.github.catvod.net.interceptor.RequestInterceptor",
            "com.github.catvod.net.interceptor.ResponseInterceptor",
            "com.github.catvod.net.interceptor.AuthInterceptor",
            "com.github.catvod.utils.Auth",
            "com.github.catvod.bean.Doh",
            // okhttp 4.12 自带：catvod 的 Util 读它的 VERSION 拼 UA。
            "okhttp3.OkHttp",
            // SpiderDebug / Path 的日志出口。
            "com.orhanobut.logger.Logger",
            // Prefers 的存储入口 / Download 的线程切换。
            "androidx.preference.PreferenceManager",
            "androidx.core.os.HandlerCompat",
            // ---- QuickJS 运行时（#63）：实现已编进 APK，缺了就是构建配置问题 ----
            "com.github.catvod.runtime.RuntimePlugin",
            "com.github.catvod.runtime.QuickJsRuntime",
            "com.fongmi.quickjs.RuntimeEntry",
            "com.fongmi.quickjs.host.Host",
            // RuntimeModule 读 assets / PackageAbi 供字节码缓存分目录，
            // Trans 供 JS 侧的 s2t/t2s。
            "com.github.catvod.utils.PackageAbi",
            "com.github.catvod.utils.Trans",
            // HtmlQuery 的 DOM 选择器实现。
            "org.jsoup.Jsoup",
        )

        /**
         * 可选能力：缺了不报错，只影响特定站点特性。
         *
         * 目前没有剩余项 —— QuickJS 已在 #63 内置并升到必检。保留这个分组是
         * 为了后续接 Python / Node.js 运行时（#64）时有一个「可降级」的口子。
         */
        private val OPTIONAL_HOST_CLASSES = emptyList<String>()
    }

    private val channel = MethodChannel(binaryMessenger, CHANNEL)
    private val executor = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val http = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .build()

    /** siteKey -> 已初始化好的 spider 实例。站点维度复用，避免每次操作都重建。 */
    private val spiders = ConcurrentHashMap<String, SpiderHandle>()

    /** jar 绝对路径 -> 已加载的 ClassLoader，同一 jar 下多个站点共用一个。 */
    private val classLoaders = ConcurrentHashMap<String, DexClassLoader>()

    /** 本次进程内已强刷重下过的 jar URL：类找不到时的重试每 URL 只做一次。 */
    private val refreshedJars = ConcurrentHashMap.newKeySet<String>()

    /**
     * jar 的 `Init.init` 最近一次失败的原因。
     *
     * 为什么必须留住它：加固 jar 的 `Init.init` 会触发 `DexNative.<clinit>`
     * （读 jar 内 assets 的 so → `System.load` → 解密内层 dex）。这一步失败后，
     * ART 把 `DexNative` 标记为 erroneous，之后实例化 Guard 类时只会抛
     * `NoClassDefFoundError: com.github.catvod.spider.DexNative` —— 只有一个类名，
     * 真正的原因（`UnsatisfiedLinkError` / `SecurityException` / 文件缺失）全丢了。
     * 站点失败时把它一起报出来，才能判断是「jar 与站点不匹配」还是
     * 「native 库加载失败」。
     */
    @Volatile
    private var initFailure: Throwable? = null

    private class SpiderHandle(
        val siteKey: String,
        val api: String,
        val className: String,
        val jarPath: String,
        val instance: Any,
        val initModes: List<String>,
    )

    init {
        // catvod 的 Runtime 是 Path / RuntimeModule 取 Context 的唯一入口：
        // 没有它，Runtime.context() 直接 NPE。#63 之前宿主从未设置，
        // 只是因为当时没有代码路径真的走到那里才没暴露。
        runCatching { com.github.catvod.Runtime.set(context) }
            .onFailure { Log.w(TAG, "Runtime.set(context) 失败，QuickJS 可能不可用", it) }
        channel.setMethodCallHandler(this)
    }

    /**
     * jar 里的 `Init` 需要的 Context。
     *
     * **必须是 Application，不能是 Activity。** 这不是风格问题，是硬约束：
     * 加固 jar 的 `Init.init(Context)` 字节码是
     * `move-object v1,v2 → check-cast v1, Landroid/app/Application → iput-object`，
     * 传 Activity 必然抛 ClassCastException，于是 `Init` 单例上的 Application
     * 字段留空，后面 `DexNative.<clinit>` 调 `Init.context().getCacheDir()`
     * 直接 NPE（现场报错：Attempt to invoke virtual method 'java.io.File
     * android.content.Context.getCacheDir()' on a null object reference）。
     *
     * 上游 FongMi 的 `JarLoader.initDex` 传的是 `App.get()`（Application），
     * 这里对齐上游。
     */
    private fun jarInitContext(): Context =
        context.applicationContext ?: context

    fun dispose() {
        channel.setMethodCallHandler(null)
        for (handle in spiders.values) {
            runCatching { callQuietly(handle.instance, "destroy") }
        }
        spiders.clear()
        classLoaders.clear()
        executor.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val action: (MethodCall) -> Any? = when (call.method) {
            "diagnostics" -> ::handleDiagnostics
            "inspectJar" -> ::handleInspectJar
            "prepareSite" -> ::handlePrepareSite
            "invoke" -> ::handleInvoke
            "releaseSite" -> ::handleReleaseSite
            "clearCache" -> ::handleClearCache
            else -> {
                result.notImplemented()
                return
            }
        }
        executor.execute {
            try {
                val value = action(call)
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                Log.w(TAG, "channel ${call.method} failed", error)
                val payload = failurePayload(error)
                mainHandler.post { result.success(payload) }
            }
        }
    }

    // ---------------------------------------------------------------- 诊断

    /**
     * 环境自检。真机第一次接入时先看这个：能区分「宿主依赖缺失」
     * 「jar 没下载」「类名解析错」三类问题。
     */
    private fun handleDiagnostics(call: MethodCall): Map<String, Any?> {
        val missingHost = REQUIRED_HOST_CLASSES.filter { !classAvailable(it) }
        // 运行时实现类现在是我们自己编进 APK 的源码，缺了就是构建配置出问题，
        // 与基础契约类同样致命（spider 调 safeDns / Decoder 立刻炸），所以
        // 一并计入 ok。可选能力（QuickJS）缺了只提示，不影响 ok。
        val missingRuntime = RUNTIME_HOST_CLASSES.filter { !classAvailable(it) }
        val missingOptional = OPTIONAL_HOST_CLASSES.filter { !classAvailable(it) }
        val jarFiles = jarDir().listFiles()?.filter { it.isFile }?.sortedBy { it.name }.orEmpty()
        return mapOf(
            "ok" to (missingHost.isEmpty() && missingRuntime.isEmpty()),
            "androidSdk" to Build.VERSION.SDK_INT,
            "androidRelease" to Build.VERSION.RELEASE,
            "abis" to Build.SUPPORTED_ABIS.toList(),
            "hostClassesMissing" to missingHost,
            "runtimeClassesMissing" to missingRuntime,
            "optionalClassesMissing" to missingOptional,
            // QuickJS 是否可用（#63）：installed=so 在，checked=真求值成功。
            "quickjs" to probeQuickJs(),
            "loadedSites" to spiders.keys.toList(),
            "cachedJars" to jarFiles.map {
                mapOf("name" to it.name, "bytes" to it.length(), "readOnly" to !it.canWrite())
            },
        )
    }

    /**
     * 下载并解析一个 jar，返回里面所有 `com.github.catvod.spider.*` 类名。
     *
     * jar 本质是 zip，直接读 entry 名比用已废弃的 DexFile 更稳，也能顺手
     * 判断 jar 是否自带 Spider 基类（决定要不要依赖宿主）。
     */
    private fun handleInspectJar(call: MethodCall): Map<String, Any?> {
        val url = requireUrl(call.argument<String>("url"))
        val force = call.argument<Boolean>("force") == true
        val jar = ensureJar(url, force)

        // 类名要同时认 .class 条目与 classes*.dex：伪装成 png/jpg 的 jar
        // 里只有 dex，只扫 .class 会一个类都列不出来，看不出「jar 到底
        // 有没有本站点的类」。
        val classNames = spiderClassNames(jar)
        var hasBaseClass = false
        var dexCount = 0
        ZipFile(jar).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                val name = entry.name
                when {
                    name.endsWith(".class") -> {
                        val className = name.removeSuffix(".class").replace('/', '.')
                        if (className == "com.github.catvod.crawler.Spider") hasBaseClass = true
                    }
                    name.matches(Regex("classes\\d*\\.dex")) -> {
                        dexCount++
                        val bytes = zip.getInputStream(entry).use { it.readBytes() }
                        if (dexContains(bytes, "Lcom/github/catvod/crawler/Spider;")) hasBaseClass = true
                    }
                }
            }
        }

        return mapOf(
            "ok" to true,
            "jarPath" to jar.absolutePath,
            "bytes" to jar.length(),
            "readOnly" to !jar.canWrite(),
            "dexCount" to dexCount,
            "bundlesBaseClass" to hasBaseClass,
            "spiders" to classNames.sorted(),
        )
    }

    // ------------------------------------------------------------ 站点准备

    /**
     * 为一个站点建实例并完成 init。
     *
     * `api` 的三种写法都接受：
     *   - `csp_Ali`            → com.github.catvod.spider.Ali（TVBox 标准写法）
     *   - `Ali`                → 同上（部分配置省略前缀）
     *   - 全限定类名            → 原样使用，便于接自编译的 jar
     */
    private fun handlePrepareSite(call: MethodCall): Map<String, Any?> {
        val siteKey = call.argument<String>("siteKey")?.trim()
            ?: throw IllegalArgumentException("缺少 siteKey")
        val api = call.argument<String>("api")?.trim()
            ?: throw IllegalArgumentException("缺少 api")
        val jarUrl = requireUrl(call.argument<String>("jarUrl"))
        val ext = call.argument<String>("ext").orEmpty()
        val jarMd5 = call.argument<String>("jarMd5").orEmpty().trim()
        val force = call.argument<Boolean>("force") == true

        if (!force) {
            spiders[siteKey]?.let { existing ->
                return success("reused", existing)
            }
        } else {
            spiders.remove(siteKey)?.let { runCatching { callQuietly(it.instance, "destroy") } }
        }

        var jar = ensureJar(jarUrl, false, jarMd5)
        var clazz: Class<*>? = resolveClassOrNull(classLoaderFor(jar), jar, api)

        if (clazz == null) {
            // 找不到类时先怀疑缓存过期：jar URL 常被原地换内容（同 URL 不同
            // 包），缓存永不过期就会拿旧包配新站点名。同一 URL 每次进程只
            // 强刷一次，避免「类确实不在」时反复下载。
            if (refreshedJars.add(jarUrl)) {
                jar = ensureJar(jarUrl, true, jarMd5)
                clazz = resolveClassOrNull(classLoaderFor(jar), jar, api)
            }
        }

        if (clazz == null) {
            val wanted = resolveClassName(api)
            val available = spiderClassNames(jar).sorted()
            throw BridgeException(
                "class_not_found",
                "在 jar 里找不到类 $wanted（$api）。jar 内实际类名：" +
                    (if (available.isEmpty()) "(无 com.github.catvod.spider 类)"
                     else available.take(40).joinToString(", ")) +
                    "。请确认该 jar 与本站点匹配；站点级 jar 丢失时可用 inspect.jar 查看。",
                null,
            )
        }

        val instance = try {
            clazz.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        } catch (error: Throwable) {
            throw BridgeException(
                "instantiate_failed",
                describeInstantiateFailure(clazz, jar, error),
                error,
            )
        }

        val initModes = initSpider(instance, clazz, ext)

        val handle = SpiderHandle(siteKey, api, clazz.name, jar.absolutePath, instance, initModes)
        spiders[siteKey] = handle
        return success("created", handle)
    }

    /**
     * init 只调一次，两参优先。
     *
     * FongMi 与 Q 版基类的 `init(Context, String)` 默认实现都会自己转调
     * `init(Context)`，所以宿主再补调一参版属于重复初始化：override 了
     * 两参版的 spider 可能被重置状态。FongMi 自己的
     * `SpiderLoader.createSpider` 也只调 `spider.init(context, ext)`。
     *
     * 只有「两参签名整个继承链都找不到」的极老 jar 才退到一参；此时用
     * getMethod（沿继承链）而不是 getDeclaredMethod，避免漏掉父类实现。
     */
    private fun initSpider(instance: Any, clazz: Class<*>, ext: String): List<String> {
        val two = findMethod(clazz, "init", Context::class.java, String::class.java)
        if (two != null) {
            two.invoke(instance, context, ext)
            return listOf("init(Context,String)")
        }
        val one = findMethod(clazz, "init", Context::class.java)
        if (one != null) {
            one.isAccessible = true
            one.invoke(instance, context)
            return listOf("init(Context)")
        }
        // 没有 init 不算致命：基类方法都是空实现，部分纯静态 spider 也能跑。
        return listOf("no-init")
    }

    // --------------------------------------------------------------- 调用

    /**
     * 统一入口。method 决定参数怎么取，返回值统一是 spider 给的原始 json 文本。
     */
    private fun handleInvoke(call: MethodCall): Map<String, Any?> {
        val siteKey = call.argument<String>("siteKey")?.trim()
            ?: throw IllegalArgumentException("缺少 siteKey")
        val method = call.argument<String>("method")?.trim()
            ?: throw IllegalArgumentException("缺少 method")
        val handle = spiders[siteKey]
            ?: throw BridgeException(
                "site_not_prepared",
                "站点 $siteKey 还没有 prepareSite，请先准备再调用。",
                null,
            )

        val clazz = handle.instance.javaClass
        val started = System.currentTimeMillis()
        val value: Any? = when (method) {
            "homeContent" -> {
                val filter = call.argument<Boolean>("filter") == true
                invokeTyped(clazz, handle.instance, "homeContent", arrayOf<Class<*>>(Boolean::class.javaPrimitiveType!!), arrayOf<Any?>(filter))
            }
            "homeVideoContent" -> {
                invokeTyped(clazz, handle.instance, "homeVideoContent", emptyArray<Class<*>>(), emptyArray<Any?>())
            }
            "categoryContent" -> {
                val tid = call.argument<String>("tid").orEmpty()
                val pg = call.argument<String>("pg").orEmpty().ifEmpty { "1" }
                val filter = call.argument<Boolean>("filter") == true
                val extend = stringMap(call.argument<Map<*, *>>("extend"))
                invokeTyped(
                    clazz, handle.instance, "categoryContent",
                    arrayOf<Class<*>>(
                        String::class.java,
                        String::class.java,
                        Boolean::class.javaPrimitiveType!!,
                        HashMap::class.java,
                    ),
                    arrayOf<Any?>(tid, pg, filter, extend),
                )
            }
            "detailContent" -> {
                val ids = stringList(call.argument<List<*>>("ids"))
                invokeTyped(
                    clazz, handle.instance, "detailContent",
                    arrayOf<Class<*>>(List::class.java), arrayOf<Any?>(ids),
                )
            }
            "searchContent" -> {
                val key = call.argument<String>("key").orEmpty()
                val quick = call.argument<Boolean>("quick") == true
                val pg = call.argument<String>("pg")?.trim().orEmpty()
                if (pg.isNotEmpty()) {
                    // 三参版是 Q 版新增；老 spider 没有就退回两参，不要把结果显示成空。
                    val three = findMethodOrNull(
                        clazz, "searchContent",
                        String::class.java, Boolean::class.javaPrimitiveType!!, String::class.java,
                    )
                    if (three != null && three.declaringClass != baseSpiderClass()) {
                        three.invoke(handle.instance, key, quick, pg)
                    } else {
                        invokeTyped(
                            clazz, handle.instance, "searchContent",
                            arrayOf<Class<*>>(String::class.java, Boolean::class.javaPrimitiveType!!),
                            arrayOf<Any?>(key, quick),
                        )
                    }
                } else {
                    invokeTyped(
                        clazz, handle.instance, "searchContent",
                        arrayOf<Class<*>>(String::class.java, Boolean::class.javaPrimitiveType!!),
                        arrayOf<Any?>(key, quick),
                    )
                }
            }
            "playerContent" -> {
                val flag = call.argument<String>("flag").orEmpty()
                val id = call.argument<String>("id").orEmpty()
                val vipFlags = stringList(call.argument<List<*>>("vipFlags"))
                invokeTyped(
                    clazz, handle.instance, "playerContent",
                    arrayOf<Class<*>>(String::class.java, String::class.java, List::class.java),
                    arrayOf<Any?>(flag, id, vipFlags),
                )
            }
            "liveContent" -> {
                val url = call.argument<String>("url").orEmpty()
                invokeTyped(clazz, handle.instance, "liveContent", arrayOf<Class<*>>(String::class.java), arrayOf<Any?>(url))
            }
            "action" -> {
                val action = call.argument<String>("action").orEmpty()
                invokeTyped(clazz, handle.instance, "action", arrayOf<Class<*>>(String::class.java), arrayOf<Any?>(action))
            }
            "isVideoFormat" -> {
                val url = call.argument<String>("url").orEmpty()
                invokeTyped(clazz, handle.instance, "isVideoFormat", arrayOf<Class<*>>(String::class.java), arrayOf<Any?>(url))
            }
            "manualVideoCheck" -> {
                invokeTyped(clazz, handle.instance, "manualVideoCheck", emptyArray<Class<*>>(), emptyArray<Any?>())
            }
            else -> throw BridgeException(
                "unsupported_method",
                "不支持的 spider 方法 $method",
                null,
            )
        }

        return mapOf(
            "ok" to true,
            "siteKey" to siteKey,
            "method" to method,
            "value" to (value as? String),
            "boolValue" to (value as? Boolean),
            "elapsedMs" to (System.currentTimeMillis() - started),
        )
    }

    private fun handleReleaseSite(call: MethodCall): Map<String, Any?> {
        val siteKey = call.argument<String>("siteKey")?.trim().orEmpty()
        if (siteKey.isEmpty()) {
            // 空 key 视为全量释放，切源或退出影音板块时用。
            spiders.values.forEach { handle -> runCatching { callQuietly(handle.instance, "destroy") } }
            spiders.clear()
            return mapOf("ok" to true, "released" to "all")
        }
        val removed = spiders.remove(siteKey)
        removed?.let { runCatching { callQuietly(it.instance, "destroy") } }
        return mapOf("ok" to true, "released" to siteKey, "existed" to (removed != null))
    }

    private fun handleClearCache(call: MethodCall): Map<String, Any?> {
        spiders.values.forEach { handle -> runCatching { callQuietly(handle.instance, "destroy") } }
        spiders.clear()
        classLoaders.clear()
        // 清缓存后要重新允许「类找不到就强刷重试」，否则本次进程不再重下。
        refreshedJars.clear()
        var removed = 0
        listOf(jarDir(), dexDir()).forEach { dir ->
            dir.listFiles()?.forEach { file ->
                if (file.deleteRecursively()) removed++
            }
        }
        return mapOf("ok" to true, "removed" to removed)
    }

    // ------------------------------------------------------------- jar 管理

    private fun jarDir(): File = File(context.filesDir, JAR_DIR).apply { mkdirs() }

    private fun dexDir(): File = File(context.codeCacheDir, DEX_DIR).apply { mkdirs() }

    /**
     * 保证 jar 已落盘且只读。
     *
     * 只读不是洁癖：targetSdk 34 起，Android 会拒绝 DexClassLoader 加载
     * 可写文件（否则任意应用都能在 dex 加载后改写字节码）。所以下载先写
     * 临时文件，chmod 只读后再原子改名，避免半截文件被当成有效 jar。
     *
     * [expectedMd5] 是配置 `url;md5;<hash>` 声明的校验和（#61）：缓存文件
     * 对不上就当过期重下，下载结果对不上直接失败——第三方 jar URL 被原地
     * 换包是常态，缓存又永不过期，没有校验就只能靠清缓存自救。
     */
    private fun ensureJar(url: String, force: Boolean, expectedMd5: String = ""): File {
        val want = expectedMd5.trim().lowercase()
        val target = File(jarDir(), "${sha1(url)}.jar")
        if (!force && target.isFile && target.length() > 0L) {
            if (want.isEmpty() || md5Of(target) == want) {
                ensureReadOnly(target)
                return target
            }
            // 声明的 md5 与缓存不符：配置换了包，缓存作废，走下面重新下载。
        }

        val tmp = File(jarDir(), "${sha1(url)}.jar.part")
        if (tmp.exists()) tmp.delete()

        val request = Request.Builder().url(url).get().build()
        http.newCall(request).execute().use { response ->
            if (!response.isSuccessful) {
                throw BridgeException(
                    "jar_download_failed",
                    "下载 spider jar 失败：HTTP ${response.code}（$url）",
                    null,
                )
            }
            val body = response.body ?: throw BridgeException(
                "jar_download_failed", "spider jar 响应为空（$url）", null,
            )
            val declared = body.contentLength()
            if (declared > MAX_JAR_BYTES) {
                throw BridgeException(
                    "jar_too_large",
                    "spider jar 大小 ${declared / 1024 / 1024} MB 超过上限 ${MAX_JAR_BYTES / 1024 / 1024} MB",
                    null,
                )
            }
            body.byteStream().use { input ->
                tmp.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_JAR_BYTES) {
                            tmp.delete()
                            throw BridgeException(
                                "jar_too_large",
                                "spider jar 超过上限 ${MAX_JAR_BYTES / 1024 / 1024} MB",
                                null,
                            )
                        }
                        output.write(buffer, 0, read)
                    }
                }
            }
        }

        if (tmp.length() == 0L) {
            tmp.delete()
            throw BridgeException("jar_empty", "spider jar 下载结果为空（$url）", null)
        }
        if (want.isNotEmpty() && md5Of(tmp) != want) {
            tmp.delete()
            throw BridgeException(
                "jar_md5_mismatch",
                "spider jar 与配置声明的 md5 不符（$url），可能是镜像未同步或被替换，已拒绝加载。",
                null,
            )
        }

        ensureReadOnly(tmp)
        // 同路径换包：旧 ClassLoader 持有的是旧 dex，必须失效，否则重试
        // 还是拿旧类。
        classLoaders.remove(target.absolutePath)
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            // 某些 ROM 在只读状态下拒绝 rename，退化为「直接用 .part」也可以，
            // 但不能留下两个文件让下次判断混乱，所以这里明确失败。
            val fallback = tmp.copyTo(target, overwrite = true)
            tmp.delete()
            ensureReadOnly(fallback)
            return fallback
        }
        return target
    }

    private fun md5Of(file: File): String =
        file.inputStream().use { input ->
            val digest = MessageDigest.getInstance("MD5")
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
            digest.digest().joinToString("") { "%02x".format(it) }
        }

    private fun ensureReadOnly(file: File) {
        if (file.canWrite()) {
            file.setReadOnly()
        }
        if (file.canWrite()) {
            // 极少数机型 setReadOnly 对 owner 无效，直接上 chmod。
            runCatching { Runtime.getRuntime().exec(arrayOf("chmod", "444", file.absolutePath)).waitFor() }
        }
    }

    private fun classLoaderFor(jar: File): DexClassLoader =
        classLoaders.getOrPut(jar.absolutePath) {
            // 优化目录带上文件身份：同一路径换包后要让 dexopt 重新跑，
            // 否则旧 odex 配新 jar。
            val outDir = File(
                dexDir(),
                sha1("${jar.absolutePath}:${jar.length()}:${jar.lastModified()}").take(16),
            ).apply { mkdirs() }
            // parent 传 app 的 ClassLoader，spider.jar 里对 Spider / net / utils
            // 的引用才能解析到本 APK 的 classes.dex。
            //
            // 第三个参数（librarySearchPath）**不能传 null**：加固 jar 的
            // `DexNative.<clinit>` 会把 jar 内 assets 的 so 释放到缓存目录再
            // `System.load`，它自己声明的 native 方法（getLoader/getSpider）
            // 由这个 so 注册。librarySearchPath 为空时该 loader 找不到任何
            // .so，native 方法一律 UnsatisfiedLinkError。
            // 上游 FongMi 的 JarLoader 同样传了 cachePath（见其 JarLoader.load）。
            val loader = DexClassLoader(
                jar.absolutePath,
                outDir.absolutePath,
                outDir.absolutePath,
                javaClass.classLoader,
            )
            // FongMi/tvbox 的 JarLoader 在加载 jar 后会调
            // com.github.catvod.spider.Init.init(Context)（JarLoader.load 的既定
            // 步骤）。Guard 系 jar（wexguard/ftyguard 加固）靠它解密内层
            // DexClassLoader，不调则 Guard 类实例化后不可用。
            maybeInvokeJarInit(jar, loader)

            // 兜底：有些 jar 没有可调用的 Init 入口（或入口签名不匹配），
            // 但 Guard 系的 `Init` 单例上仍带着一个 Application 字段，
            // 直接把它写上，保证 `Init.context()` 不返回 null。
            ensureJarInitContext(jar, loader)
            loader
        }

    /**
     * 按 TVBox 契约初始化 jar 运行时：调用 jar 自带 `Init` 里所有
     * 「静态 + 首参 Context」的方法。
     *
     * 为什么不写死 `Init.init(Context)`：加固包（wexguard / ftyguard）的
     * 入口不止一个——jar 里同时有 `Init`、`Init$Loader`，方法名也不统一
     * （init / load / prepare），只认一个签名必然漏调，症状就是 Guard 类
     * 实例化时 `Context` 为 null 或找不到内层类（`DexNative`）。
     * 逐个调用并把成功的方法名与失败原因写进日志，加固包出问题时只有
     * 这行日志能说明到底卡在哪一步。
     *
     * **传入的 Context 必须是 Application**（见 [jarInitContext]）：加固包
     * 的 `Init.init` 内部 `check-cast` 成 Application，传 Activity 直接
     * ClassCastException。
     *
     * 但防白嫖 jar 的 Init 会校验宿主包名并 `Process.killProcess`——进程被杀
     * 比站点不可用严重得多。dex 里同时出现 killProcess 与 getPackageName
     * 就视为带这种保护，跳过原 Init（宁可这个 jar 的 Guard 类不可用）。
     */
    private fun maybeInvokeJarInit(jar: File, loader: ClassLoader) {
        if (dexStringsOf(jar).containsAll(listOf("killProcess", "getPackageName"))) {
            Log.w(TAG, "jar Init 含 killProcess 包名校验，跳过 Init 调用：${jar.name}")
            return
        }

        val contextClass = android.content.Context::class.java
        val initContext = jarInitContext()
        val invoked = mutableListOf<String>()
        val failed = mutableListOf<String>()

        for (className in listOf(
            "com.github.catvod.spider.Init",
            "com.github.catvod.spider.Init\$Loader",
        )) {
            val clazz = runCatching { Class.forName(className, true, loader) }.getOrNull() ?: continue

            for (method in clazz.declaredMethods) {
                if (!java.lang.reflect.Modifier.isStatic(method.modifiers)) continue

                val params = method.parameterTypes
                // 只调「首参能吃 Context、其余参数是 String」的入口：
                // 这类方法就是要宿主把环境交进去，其余静态方法（工具函数）
                // 乱调只会制造副作用。无参的 load / init 也是合法入口
                // （FongMi 的 Init.load() 就在 Context 之后单独跑）。
                val acceptsContext = params.isNotEmpty() && params[0].isAssignableFrom(contextClass)
                val tailIsString = params.drop(1).all { it == String::class.java }
                val zeroArgEntry = params.isEmpty() && method.name in setOf("load", "init", "prepare")
                if (!zeroArgEntry && (!acceptsContext || !tailIsString)) continue

                val args = params.mapIndexed { index, _ ->
                    if (index == 0) initContext else "" as Any?
                }.toTypedArray()

                val label = "${clazz.simpleName}.${method.name}/${params.size}"
                runCatching {
                    method.isAccessible = true
                    method.invoke(null, *args)
                }.onSuccess {
                    invoked += label
                }.onFailure {
                    // 真实原因必须留住：见 [initFailure] 的说明。加固 jar 的
                    // `Init.init` 内部会触发 `DexNative.<clinit>`，那一步失败后
                    // 只会以 `NoClassDefFoundError: ...DexNative` 的形式暴露，
                    // 真实原因全丢。
                    initFailure = it.cause ?: it
                    failed += "$label: ${it.cause?.javaClass?.simpleName ?: it.javaClass.simpleName}"
                    Log.w(TAG, "jar Init 调用失败 $label（${jar.name}）", it)
                }
            }
        }

        if (invoked.isEmpty() && failed.isEmpty()) {
            Log.w(TAG, "jar 无可用 Init 入口（${jar.name}）")
        } else {
            Log.i(TAG, "jar Init 完成 ${jar.name}: ok=[${invoked.joinToString()}] fail=[${failed.joinToString()}]")
        }
    }

    /**
     * 兜底：把 Application 写进 jar 的 `Init` 单例字段。
     *
     * 目标不是静态字段，而是 **`Init` 单例上的实例字段**——实测加固包
     * （wexguard）的 `Init` 结构是：
     * ```
     * Init$Loader.oOoOoOoOoOoOoO0o : Init        // 静态单例
     * Init.oOoOoOoOoOoOoO0o       : Application   // 实例字段 ← 要写的是这个
     * Init.oOoOoOo0oOo0o0oO       : DexClassLoader
     * Init.oOo0oOo0Oo0oO0Oo       : ClassLoader
     * ```
     * `Init.context()` 读的就是那个 Application 字段。字段为空时，
     * `DexNative.<clinit>` 里的 `Init.context().getCacheDir()` 直接 NPE，
     * 现场报错正是 "Attempt to invoke virtual method 'java.io.File
     * android.content.Context.getCacheDir()' on a null object reference"。
     *
     * 实例字段不能 `field.set(null, value)`，必须先拿到单例对象再写。
     * 单例有两个来源，都试：`Init.get()` 静态方法、`Init$Loader` 的静态字段。
     *
     * 正常路径不需要走到这里——[maybeInvokeJarInit] 调 `Init.init(Application)`
     * 就会把它写好，并顺带初始化 DexClassLoader。这里只给「Init 入口不可用」
     * 的 jar 兜底；写字段不触发 jar 里的任何逻辑。
     *
     * @return 实际写入的 `类名.字段名`，写进日志便于排查加固包差异。
     */
    private fun ensureJarInitContext(jar: File, loader: ClassLoader): List<String> {
        val application = context.applicationContext ?: context
        val written = mutableListOf<String>()

        // 单例实例的来源：静态方法 get() / 静态字段。
        val singletons = mutableListOf<Any>()
        for (className in listOf(
            "com.github.catvod.spider.Init",
            "com.github.catvod.spider.Init\$Loader",
        )) {
            val clazz = runCatching { Class.forName(className, false, loader) }.getOrNull() ?: continue
            runCatching {
                clazz.declaredMethods
                    .firstOrNull {
                        java.lang.reflect.Modifier.isStatic(it.modifiers) &&
                            it.parameterCount == 0 &&
                            it.returnType == clazz
                    }
                    ?.apply { isAccessible = true }
                    ?.invoke(null)
            }.getOrNull()?.let { singletons.add(it) }
            runCatching {
                clazz.declaredFields
                    .firstOrNull {
                        java.lang.reflect.Modifier.isStatic(it.modifiers) && it.type == clazz
                    }
                    ?.apply { isAccessible = true }
                    ?.get(null)
            }.getOrNull()?.let { singletons.add(it) }
        }

        // 实例字段：在单例对象上写。
        for (singleton in singletons) {
            var current: Class<*>? = singleton.javaClass
            while (current != null && current != Any::class.java) {
                val owner = current
                for (field in owner.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    val type = field.type
                    // 只写「吃得下 Application」的字段：Context / Application。
                    // DexClassLoader / ClassLoader 这类字段不碰，交给 jar 自己的
                    // Init.init 去填（那需要 native 参与，写了反而坏事）。
                    val acceptsApplication = type == Context::class.java ||
                        type == android.app.Application::class.java
                    if (!acceptsApplication) continue
                    runCatching {
                        field.isAccessible = true
                        field.set(singleton, application)
                    }.onSuccess {
                        written += "${owner.simpleName}.${field.name}"
                    }.onFailure {
                        Log.w(TAG, "写入 Application 失败 ${owner.simpleName}.${field.name}", it)
                    }
                }
                current = owner.superclass
            }
        }

        if (written.isNotEmpty()) {
            Log.i(TAG, "jar Application 写入完成 ${jar.name}: ${written.joinToString()}")
        }
        return written
    }

    // ------------------------------------------------------------- 反射工具

    private fun resolveClassName(api: String): String = when {
        api.startsWith("csp_") -> "com.github.catvod.spider.${api.removePrefix("csp_")}"
        api.contains('.') -> api
        else -> "com.github.catvod.spider.$api"
    }

    /**
     * 类名解析带兜底，按顺序试：
     *   1. 契约标准名（`csp_X` → `com.github.catvod.spider.X`）
     *   2. Guard 后缀互换——聚合配置常把 Guard 站点的族 jar 弄丢，同 jar 里的
     *      无 Guard 版本往往就是同一实现（`DoubanGuard` → `Douban`）
     *   3. jar 内 spider 类名大小写不敏感匹配（配置类名大小写与 jar 不一致）
     * 都失败返回 null，由调用方决定重下重试还是报错。
     */
    private fun resolveClassOrNull(loader: ClassLoader, jar: File, api: String): Class<*>? {
        val candidates = LinkedHashSet<String>()
        candidates.add(resolveClassName(api))
        val simple = api.removePrefix("csp_").substringAfterLast('.')
        if (simple.endsWith("Guard")) {
            candidates.add("com.github.catvod.spider.${simple.removeSuffix("Guard")}")
        } else {
            candidates.add("com.github.catvod.spider.${simple}Guard")
        }
        val wanted = simple.removeSuffix("Guard").lowercase()
        for (name in spiderClassNames(jar)) {
            val lower = name.lowercase()
            if (lower == simple.lowercase() || lower == wanted) {
                candidates.add("com.github.catvod.spider.$name")
            }
        }
        for (candidate in candidates) {
            runCatching { Class.forName(candidate, true, loader) }.getOrNull()?.let { return it }
        }
        return null
    }

    /**
     * jar 内 `com.github.catvod.spider.*` 的简单类名。`.class` 条目与
     * classes*.dex 都认——伪装成 png/jpg 的 spider 包通常只有 dex。
     */
    private fun spiderClassNames(jar: File): List<String> {
        val out = LinkedHashSet<String>()
        runCatching {
            ZipFile(jar).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val name = entry.name
                    if (name.endsWith(".class")) {
                        val className = name.removeSuffix(".class").replace('/', '.')
                        if (className.startsWith("com.github.catvod.spider.") &&
                            !className.contains('$')
                        ) {
                            out.add(className.removePrefix("com.github.catvod.spider."))
                        }
                    } else if (name.matches(Regex("classes\\d*\\.dex"))) {
                        val bytes = zip.getInputStream(entry).use { it.readBytes() }
                        // dex 字符串池里的类描述符形如 Lcom/github/catvod/spider/Xxx;
                        for (match in DEX_CLASS_RE.findAll(String(bytes, Charsets.ISO_8859_1))) {
                            val simple = match.groupValues[1]
                            if (!simple.contains('$')) out.add(simple)
                        }
                    }
                }
            }
        }
        return out.toList()
    }

    /** jar 内所有 dex 的字符串（ASCII 可见串），用于加固模式探测等。 */
    private fun dexStringsOf(jar: File): Set<String> {
        val out = HashSet<String>()
        runCatching {
            ZipFile(jar).use { zip ->
                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    if (!entry.name.matches(Regex("classes\\d*\\.dex"))) continue
                    val bytes = zip.getInputStream(entry).use { it.readBytes() }
                    out.addAll(DEX_STRING_RE.findAll(String(bytes, Charsets.ISO_8859_1)).map { it.value })
                }
            }
        }
        return out
    }

    private fun dexContains(dexBytes: ByteArray, needle: String): Boolean =
        String(dexBytes, Charsets.ISO_8859_1).contains(needle)

    private fun baseSpiderClass(): Class<*>? =
        runCatching { Class.forName("com.github.catvod.crawler.Spider") }.getOrNull()

    private fun findMethod(clazz: Class<*>, name: String, vararg types: Class<*>): java.lang.reflect.Method? =
        runCatching { clazz.getMethod(name, *types) }.getOrNull()

    private fun findMethodOrNull(clazz: Class<*>, name: String, vararg types: Class<*>): java.lang.reflect.Method? =
        findMethod(clazz, name, *types)

    /**
     * 按签名调用；基类没声明该方法时给出「当前 spider 不支持」而不是
     * NoSuchMethodException 堆栈——后者对用户毫无意义。
     *
     * `types` / `args` 用 out 投影：Kotlin 的 Array 不协变，而调用点写的是
     * `arrayOf<Class<*>>(Boolean::class.javaPrimitiveType!!)` / `arrayOf<Any?>(filter)` 这类
     * 具体类型数组，不加投影会直接编译不过。
     */
    private fun invokeTyped(
        clazz: Class<*>,
        instance: Any,
        name: String,
        types: Array<out Class<*>>,
        args: Array<out Any?>,
    ): Any? {
        val method = findMethod(clazz, name, *types)
            ?: throw BridgeException(
                "method_missing",
                "该 spider 没有实现 $name(${types.joinToString(",") { it.simpleName }})",
                null,
            )
        return method.invoke(instance, *args)
    }

    private fun callQuietly(instance: Any, name: String) {
        runCatching {
            val method = instance.javaClass.getMethod(name)
            method.invoke(instance)
        }
    }

    private fun stringList(raw: List<*>?): ArrayList<String> {
        val out = ArrayList<String>()
        raw?.forEach { item -> out.add(item?.toString().orEmpty()) }
        return out
    }

    private fun stringMap(raw: Map<*, *>?): HashMap<String, String> {
        val out = HashMap<String, String>()
        raw?.forEach { (key, value) ->
            if (key != null) out[key.toString()] = value?.toString().orEmpty()
        }
        return out
    }

    private fun classAvailable(name: String): Boolean =
        runCatching { Class.forName(name, false, javaClass.classLoader) }.isSuccess

    private fun requireUrl(raw: String?): String {
        val value = raw?.trim().orEmpty()
        require(value.startsWith("http://") || value.startsWith("https://")) {
            "jarUrl 必须是 http(s) 地址，实际为「$value」"
        }
        return value
    }

    private fun sha1(value: String): String {
        val digest = MessageDigest.getInstance("SHA-1").digest(value.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    private fun success(mode: String, handle: SpiderHandle): Map<String, Any?> = mapOf(
        "ok" to true,
        "mode" to mode,
        "siteKey" to handle.siteKey,
        "api" to handle.api,
        "className" to handle.className,
        "jarPath" to handle.jarPath,
        "initModes" to handle.initModes,
    )

    // ------------------------------------------------------------- 错误归类

    /**
     * 带错误码的桥接异常。code 直接回给 Dart 侧做分支判断，
     * message 是给人看的中文说明。
     *
     * cause 不写成 `override val`：Throwable 已有同名属性，重复声明会
     * 生成两套 getCause，直接在父构造里传就够了。
     */
    private class BridgeException(
        val code: String,
        message: String,
        cause: Throwable? = null,
    ) : Exception(message, cause)

    private fun failurePayload(error: Throwable): Map<String, Any?> {
        val unwrapped = unwrap(error)
        val code = when {
            unwrapped is BridgeException -> unwrapped.code
            unwrapped is NoClassDefFoundError -> "host_class_missing"
            unwrapped is ClassNotFoundException -> "class_not_found"
            unwrapped is NoSuchMethodError -> "method_missing"
            unwrapped is SecurityException -> "jar_not_readonly"
            unwrapped is IllegalArgumentException -> "bad_argument"
            unwrapped is IOException -> "io_error"
            else -> "spider_error"
        }
        val hint = when (code) {
            "host_class_missing" -> {
                val missing = unwrapped.message?.substringAfterLast('/')?.substringBefore(' ')?.replace('/', '.')
                "宿主缺少依赖类 ${missing ?: "(未知)"}。说明 catvod-api.jar 没进包，" +
                    "或该 spider 用到了尚未引入的第三方库（quickjs / smbj / slf4j 等）。"
            }
            "jar_not_readonly" -> "jar 未能置为只读，Android 14+ 会拒绝 DexClassLoader 加载。"
            "jar_md5_mismatch" -> "jar 与配置声明的 md5 不一致。等源站镜像同步，或在资源库里更新该源的 jar 地址。"
            else -> null
        }
        return mapOf(
            "ok" to false,
            "code" to code,
            "message" to (unwrapped.message ?: unwrapped.javaClass.simpleName),
            "hint" to hint,
            "exception" to unwrapped.javaClass.name,
            "stack" to Log.getStackTraceString(error).take(4000),
        )
    }

    /** 反射调用会把业务异常塞进 InvocationTargetException，展示前要剥掉。 */
    private fun unwrap(error: Throwable): Throwable {
        var current: Throwable = error
        while (true) {
            val cause = current.cause
            if (current is InvocationTargetException && cause != null) {
                current = cause
                continue
            }
            if (current is ExceptionInInitializerError && cause != null) {
                current = cause
                continue
            }
            return current
        }
    }

    private fun rootMessage(error: Throwable): String =
        unwrap(error).message ?: unwrap(error).javaClass.simpleName

    /**
     * 站点实例化失败的说明。
     *
     * 只报「类 X 实例化失败：NoClassDefFoundError: com.github.catvod.spider.DexNative」
     * 是没用的：加固 jar 的 `DexNative.<clinit>` 失败后，ART 会把该类标记为
     * erroneous，之后任何引用都只抛这个类名，真实原因（native 库加载失败 /
     * so 缺失 / 权限问题）被完全掩盖。
     *
     * 所以这里把三件事拼在一起：
     * 1. 表面错误；
     * 2. **jar 的 Init 阶段留下的真实失败原因**（若有）—— 这才是根因；
     * 3. jar 内实际有哪些 `com.github.catvod.spider.*` 类，用来判断
     *    「jar 与站点不匹配」（类名对不上）还是「类在但初始化失败」。
     */
    private fun describeInstantiateFailure(clazz: Class<*>, jar: File, error: Throwable): String {
        val sb = StringBuilder()
        sb.append("类 ").append(clazz.name).append(" 实例化失败：").append(rootMessage(error))

        // 根因：Init 阶段的失败比这里的 NoClassDefFoundError 有价值得多。
        val init = initFailure
        if (init != null) {
            sb.append("\n根因（jar 的 Init 阶段失败）：")
                .append(init.javaClass.simpleName).append(": ").append(rootMessage(init))
        }

        // jar 内有没有这个类 / 它的同族类：区分「站点与 jar 不匹配」与
        // 「类在但初始化失败」。
        val spiderClasses = spiderClassNames(jar)
        if (spiderClasses.isEmpty()) {
            sb.append("\n该 jar 内没有任何 com.github.catvod.spider 类，")
                .append("站点与 jar 不匹配（可能是配置里的 spider 地址指向了别的包）。")
        } else {
            val simple = clazz.simpleName
            val hasSame = spiderClasses.any { it.equals(simple, ignoreCase = true) }
            if (!hasSame) {
                sb.append("\njar 内没有与 ").append(simple).append(" 同名的类，")
                    .append("站点与 jar 不匹配。jar 内共 ").append(spiderClasses.size)
                    .append(" 个 spider 类，例如：")
                    .append(spiderClasses.take(8).joinToString(", "))
            } else {
                sb.append("\njar 内存在 ").append(simple)
                    .append("，失败发生在类初始化阶段（多为 native 库加载失败）。")
            }
        }
        return sb.toString()
    }

    /**
     * QuickJS 能力探测（#63）。
     *
     * 三类失败要能分开：类没进 APK / .so 没打进当前 ABI / native 注册失败。
     * `check()` 会真跑一次 `6 * 7`，这是唯一能证明「JS 引擎真的活着」的手段，
     * 比只看类是否存在有意义得多。
     *
     * 首次调用会加载 1.5 MB 的 .so，耗时约几十毫秒；diagnostics 本来就在
     * 后台线程执行，可以接受。
     */
    private fun probeQuickJs(): Map<String, Any?> {
        val module = com.github.catvod.utils.RuntimeModule.QUICKJS
        val installed = runCatching { module.isInstalled() }.getOrDefault(false)
        var checked = false
        var error: String? = null
        if (installed) {
            try {
                val entry = module.entry(com.github.catvod.runtime.QuickJsRuntime::class.java)
                entry.check()
                checked = true
            } catch (t: Throwable) {
                error = rootMessage(t)
            }
        } else {
            error = "libquickjs-wrapper.so 未出现在当前 ABI 的 nativeLibraryDir"
        }
        return mapOf(
            "installed" to installed,
            "checked" to checked,
            "error" to error,
            "compatibilityId" to runCatching { module.compatibilityId }.getOrNull(),
        )
    }
}
