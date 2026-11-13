/*
 * 兼容类，不是 FongMi 上游源码里的文件，但字段与方法跟上游逐一对应。
 *
 * 背景：`android/app/libs/catvod-api.jar` 是上游用白名单导出的「spider 编译契约」，
 *      只导出了 `com.github.catvod.utils.Decoder`，**没有导出它的嵌套类
 *      `Decoder$Content`**。这带来两个后果：
 *
 *        1. 编译期：D8（debug 分支）在 dex 整包 jar 时要求 nest mate 在同一条
 *           classpath 上，缺了直接报
 *           “Compilation of classes com.github.catvod.utils.Decoder requires its
 *           nest mates com.github.catvod.utils.Decoder$Content (unavailable)”，
 *           于是 debug 构建整体失败。
 *        2. 运行期：`Decoder.load()/getJson()` 的返回类型就是这个类，任何
 *           spider 调到都会 NoClassDefFoundError。
 *
 * 上游定义（catvod/src/main/java/com/github/catvod/utils/Decoder.java，commit b27ba75）：
 *
 *        public record Content(String text, String url,
 *                              String authorization, boolean successful) { }
 *
 * 这里不用 `record`：Android 的 record 支持依赖 D8 的 record 反糖，多一层
 * 版本耦合；上游代码只用到 `<init>(String,String,String,boolean)` 与 `text()`，
 * 普通 final 类足以承接，四个访问器一并补上，行为等价。
 *
 * 注意：如果将来把 catvod-api.jar 换成完整导出（含 Content），必须删掉本文件，
 * 否则会出现重复类。
 */
package com.github.catvod.utils;

public final class Decoder$Content {

    private final String text;
    private final String url;
    private final String authorization;
    private final boolean successful;

    public Decoder$Content(String text, String url, String authorization, boolean successful) {
        this.text = text;
        this.url = url;
        this.authorization = authorization;
        this.successful = successful;
    }

    public String text() {
        return text;
    }

    public String url() {
        return url;
    }

    public String authorization() {
        return authorization;
    }

    public boolean successful() {
        return successful;
    }

    @Override
    public String toString() {
        return "Content[text=" + text + ", url=" + url
                + ", authorization=" + authorization + ", successful=" + successful + "]";
    }
}
