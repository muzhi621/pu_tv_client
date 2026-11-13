package com.mystyle.purelive.tv

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

        val classNames = ArrayList<String>()
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
                        if (className.startsWith("com.github.catvod.spider.") &&
                            !className.contains('$')
                        ) {
                            classNames.add(className.removePrefix("com.github.catvod.spider."))
                        }
                    }
                    name.matches(Regex("classes\\d*\\.dex")) -> dexCount++
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
        val force = call.argument<Boolean>("force") == true

        if (!force) {
            spiders[siteKey]?.let { existing ->
                return success("reused", existing)
            }
        } else {
            spiders.remove(siteKey)?.let { runCatching { callQuietly(it.instance, "destroy") } }
        }

        val jar = ensureJar(jarUrl, false)
        val loader = classLoaderFor(jar)
        val className = resolveClassName(api)

        val clazz = try {
            Class.forName(className, true, loader)
        } catch (error: Throwable) {
            throw BridgeException(
                "class_not_found",
                "在 jar 里找不到类 $className（$api）。请确认该 jar 与本站点匹配；" +
                    "可用 inspectJar 查看 jar 内实际类名。",
                error,
            )
        }

        val instance = try {
            clazz.getDeclaredConstructor().apply { isAccessible = true }.newInstance()
        } catch (error: Throwable) {
            throw BridgeException(
                "instantiate_failed",
                "类 $className 实例化失败：${rootMessage(error)}",
                error,
            )
        }

        val initModes = initSpider(instance, clazz, ext)

        val handle = SpiderHandle(siteKey, api, className, jar.absolutePath, instance, initModes)
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
     */
    private fun ensureJar(url: String, force: Boolean): File {
        val target = File(jarDir(), "${sha1(url)}.jar")
        if (!force && target.isFile && target.length() > 0L) {
            ensureReadOnly(target)
            return target
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

        ensureReadOnly(tmp)
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
            val outDir = File(dexDir(), sha1(jar.absolutePath).take(16)).apply { mkdirs() }
            // parent 传 app 的 ClassLoader，spider.jar 里对 Spider / net / utils
            // 的引用才能解析到本 APK 的 classes.dex。
            DexClassLoader(jar.absolutePath, outDir.absolutePath, null, javaClass.classLoader)
        }

    // ------------------------------------------------------------- 反射工具

    private fun resolveClassName(api: String): String = when {
        api.startsWith("csp_") -> "com.github.catvod.spider.${api.removePrefix("csp_")}"
        api.contains('.') -> api
        else -> "com.github.catvod.spider.$api"
    }

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
