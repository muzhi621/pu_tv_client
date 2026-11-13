/*
 * 兼容类，不是 OkHttp 官方库的组成部分。
 *
 * 背景：FongMi/TV 的 catvod 模块用 okhttp 5.x，5.x 新增了一个纯版本信息类
 *       `okhttp3.OkHttp`（Kotlin `object OkHttp { @JvmField val VERSION }`）。
 *       catvod-api.jar 里的 `utils/Util` 静态字段 `OKHTTP = "okhttp/" + OkHttp.VERSION`
 *       会直接引用它：只要宿主里任何一个类首次主动使用 `Util`，`<clinit>` 就会
 *       去解析 `okhttp3.OkHttp`，缺了这个类就是 NoClassDefFoundError。
 *
 * 为什么不直接升级到 okhttp 5.x：本项目其余链路（Dio / 播放器插件 / 现有的
 * OkHttpClient 用法）都在 4.12 上验证过，为拿一个字符串常量去动 HTTP 栈不划算。
 * 这里只提供字段，签名与 5.x 一致，`Util` 即可正常初始化。
 *
 * 注意：若将来真的升级到 okhttp 5.x，必须删掉本文件，否则会出现重复类。
 */
package okhttp3;

public final class OkHttp {

    /**
     * User-Agent 里出现的版本号。取值是本宿主实际依赖的 okhttp 版本（4.12.0），
     * 而不是上游 5.5.0 —— 这个常量唯一的用途是拼 UA（`Util.OKHTTP`），
     * 报真实版本更有利于排查站点侧的问题。
     */
    public static final String VERSION = "4.12.0";

    private OkHttp() {
    }
}
