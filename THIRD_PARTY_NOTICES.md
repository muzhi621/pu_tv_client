# 第三方代码与许可证声明

本项目整体采用 **GNU AGPL-3.0**（见 `LICENSE`）。以下第三方代码按各自许可证纳入，
并按对应许可证要求保留来源与署名。

---

## 1. FongMi/TV —— TVBox 爬虫宿主

- **仓库**：https://github.com/FongMi/TV
- **模块**：`catvod`（分支 `fongmi`）
- **纳入时 commit**：`b27ba7593f1e4eb3c41ccf3cddc2affb3542f115`（2026-11-09）
- **许可证**：GPL-3.0
- **兼容性说明**：GPLv3 §13 明确允许 GPL-3.0 与 AGPL-3.0 组合成同一作品。
  本项目整体按 AGPL-3.0 分发，符合该条款。

### 1.1 `android/app/libs/catvod-api.jar`

上游根 `build.gradle` 的 `apiJar` task 导出的 **spider 编译期契约**（51 个类）。
这个 jar 只包含外部 spider 编译时需要用到的类型，**不含运行时实现**。

### 1.2 `android/app/src/main/java/com/github/catvod/` 下的 14 个源文件

`catvod-api.jar` 的类在运行时会静态引用一批「由宿主提供」的实现类，而 `apiJar`
的白名单不导出它们。我们把上游对应源码纳入本工程，作为宿主实现：

| 文件 | 作用 |
|---|---|
| `net/OkHttp.java` | 全局 HTTP 客户端与 Call 工厂 |
| `net/OkDns.java` | DoH / hosts 映射解析 |
| `net/CacheOptions.java` | 响应缓存参数 |
| `net/OkAuthenticator.java` | HTTP 认证 |
| `net/OkProxySelector.java` | 代理选择 |
| `net/ProxyAuthenticator.java` | 代理认证 |
| `net/ProxyRedirectInterceptor.java` | 代理跳转拦截 |
| `net/interceptor/RequestInterceptor.java` | 请求预处理 |
| `net/interceptor/ResponseInterceptor.java` | 响应解压 / 预处理 |
| `net/interceptor/AuthInterceptor.java` | 鉴权拦截 |
| `utils/Auth.java` | 站点鉴权上下文 |
| `bean/Doh.java` | DoH 配置项 |
| `bean/Header.java` | 请求头模型 |
| `bean/Proxy.java` | 代理配置项 |

每个文件头部都写有来源与许可证说明。**未修改业务逻辑**，仅做集成适配。

### 1.3 `android/app/src/main/java/com/github/catvod/utils/Decoder$Content.java`

**不是**上游源码文件，是我们按上游 API 补的兼容类。

`catvod-api.jar` 是上游用白名单导出的编译契约，只导出了
`com.github.catvod.utils.Decoder`，漏掉了它的嵌套类 `Decoder$Content`：

- debug 构建时 D8 报「requires its nest mates … (unavailable)」，整包 dex 失败；
- 运行期任何 spider 调到 `Decoder.load()` / `Decoder.getJson()` 都会
  `NoClassDefFoundError`。

上游定义见 `catvod/.../utils/Decoder.java`（commit `b27ba75`）里的
`public record Content(String text, String url, String authorization, boolean successful)`。
我们用普通 final 类实现同样的四参构造与访问器，避免依赖 D8 的 record 反糖。

> 另：早期曾补过一个 `okhttp3.OkHttp` 兼容类，事后核对 okhttp **4.12.0 本身就带**
> 这个类和 `VERSION` 字段，属于多余并导致 R8 重复类报错，已删除。

---

## 1A. FongMi/TV —— QuickJS 运行时（#63）

同一仓库 `b27ba75` 的 `quickjs` 模块与 `catvod` 模块的部分源码。

- **许可证**：GPL-3.0（与上文同源，兼容性依据同为 GPLv3 §13）
- **纳入原因**：TVBox 生态里 `new Js()` 与独立 `.js` 站点的执行都依赖 QuickJS。

### 1A.1 `android/app/libs/quickjs-wrapper.jar`

上游 `quickjs/libs/wrapper-java.jar`，Java 侧的 QuickJS 绑定
（`com.fongmi.quickjs.QuickJS` / `QuickJSContext` / `ModuleBytecodeCache` 等）。

该 jar 里**还附带**了 `com.dylibso.chicory`（纯 Java WASM 解释器，180 个类）。
只有 `com.fongmi.quickjs.Wasm*` 引用它，而 `Wasm*` 在 native 路径下没有静态
调用方，release 构建由 R8 整体裁掉，不进 APK。`proguard-rules.pro` 里刻意
**没有** `-keep com.dylibso.chicory.**`。

### 1A.2 `android/app/src/main/jniLibs/{arm64-v8a,armeabi-v7a}/libquickjs-wrapper.so`

来自上游 `quickjs/libs/runtime-release.aar` 的 `jni/` 目录（该 aar 的
`classes.jar` 是空的，只提供 .so）。体积 1.53 MB / 1.09 MB，压缩后约
0.67 MB / 0.61 MB。

### 1A.3 `android/app/src/main/assets/js/`

上游 `quickjs/src/main/assets/js/`：

| 路径 | 作用 |
|---|---|
| `lib/spider.js` | JS spider 基类骨架 |
| `lib/catvod.js` | JS 侧 catvod 兼容层 |
| `lib/net.js` | JS 侧网络请求实现 |
| `lib/dialog.js` | JS 侧对话框 |
| `vendor/cheerio.min.js` | HTML 选择器（对应 Java 侧 jsoup） |
| `vendor/crypto-js.js` | JS 侧加解密 |
| `vendor/gbk.js` | GBK 编解码表 |

第三方 JS 库各自保留原有许可证头。

### 1A.4 `android/app/src/main/java/com/fongmi/quickjs/`（17 个源文件）

`QuickJSLoader` / `RuntimeEntry` / `crawler/{Loader,Spider}` /
`method/{Cache,Dialogs,Global,Invocation,Network,ProxyBody,Sockets,Streams}` /
`utils/{Connect,HtmlQuery,Module,Scripts}` / `host/Host`。

其中 `host/Host.java` 来自上游 `catvod` 模块（不在 `apiJar` 白名单内）。
**未修改业务逻辑**，只做集成适配。

### 1A.5 自写的 `com.github.catvod.utils.RuntimeModule`

**不是上游逐字拷贝**。上游把 QuickJS 当作独立插件 APK（`com.fongmi.runtime.quickjs`），
校验签名/ABI/payload 后用 `DexClassLoader` 加载，且显式拒绝宿主自带实现：
`throw new IOException("Runtime implementation is bundled in the host")`。

本项目是单 APK 直装，不引入插件包。因此保留上游的枚举名与二进制签名
（`catvod-api.jar` 里的 `Js` 只用到 `QUICKJS` 常量与 `entry(Class)` 两个成员），
把实现换成「内置」：`entry()` 直接返回宿主内的 `RuntimeEntry`，`load()` 加载
`nativeLibraryDir` 下的 .so，`readAsset()` 从宿主 `assets/` 读取。
文件头有完整说明。

### 1A.6 补齐的 catvod 类

`utils/PackageAbi.java`、`utils/Trans.java`、`runtime/RuntimePlugin.java`、
`runtime/QuickJsRuntime.java` —— 均来自上游 `b27ba75`，未被 `apiJar` 导出，
由 QuickJS 模块静态引用。

## 2. 未采用的评估对象

以下项目做过融合评估，**未纳入任何代码**，在此记录以免重复调研：

- `j4Uq/TVBoxOSC`（AGPL-3.0）—— CI 分发壳，主仓库仅 8 个文件，源码在 Release 附包
- `yuluoos/TVBox-tvs`（MIT）—— Flutter 源码从未公开，运行时为 Node.js + QuickJS
- `sky22333/sky-tv`（GPL-3.0）—— 源码完整但缺少云端下发中枢，与架构不匹配

## 3. 运行期依赖（Gradle 坐标）

| 依赖 | 用途 |
|---|---|
| `com.squareup.okhttp3:okhttp:4.12.0` | catvod 契约签名直接暴露 okhttp 类型 |
| `com.squareup.okhttp3:okhttp-dnsoverhttps:4.12.0` | `OkDns` 的 DoH 解析 |
| `com.squareup.okhttp3:logging-interceptor:4.12.0` | `OkHttp` 的日志拦截器 |
| `com.google.code.gson:gson:2.11.0` | JSON 解析（`Json` 用到 `Strictness`） |
| `com.google.guava:guava:33.8.0-android` | `Task` / `Decoder` 的 Futures |
| `androidx.collection:collection:1.4.5` | `OkHttp` 的 `ArrayMap` |
| `androidx.preference:preference:1.2.1` | `Prefers` 的 `PreferenceManager` |
| `androidx.core:core:1.13.1` | `Download` 的 `HandlerCompat` |
| `com.orhanobut:logger:2.2.0` | `SpiderDebug` / `Path` 的日志出口 |
| `org.jsoup:jsoup:1.23.2` | QuickJS 侧 `HtmlQuery` 的 DOM 选择器 |

以上均为 Apache-2.0 或同等宽松许可证。
