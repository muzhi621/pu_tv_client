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

以上均为 Apache-2.0 或同等宽松许可证。
