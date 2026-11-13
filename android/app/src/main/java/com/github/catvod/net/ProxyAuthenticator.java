/*
 * 来源：https://github.com/FongMi/TV （catvod 模块，分支 fongmi）
 * 原始许可证：GPL-3.0。本项目整体为 AGPL-3.0，GPLv3 §13 允许二者组合。
 * 用途：catvod-api.jar 只导出 spider 编译用的契约类，运行时实现类
 *      （OkHttp / OkDns / Auth / interceptor 等）由宿主 App 提供。
 *      此处补齐的正是这批类，否则 spider 调 Spider.safeDns() /
 *      Decoder 时会 NoClassDefFoundError。
 * 改动：仅做集成适配，未修改业务逻辑。
 */
package com.github.catvod.net;

import java.net.Authenticator;
import java.net.PasswordAuthentication;
import java.util.Objects;

public class ProxyAuthenticator extends Authenticator {

    private final OkProxySelector selector;

    public ProxyAuthenticator(OkProxySelector selector) {
        this.selector = selector;
    }

    @Override
    protected PasswordAuthentication getPasswordAuthentication() {
        String userInfo = findUserInfo(getRequestingHost());
        if (userInfo == null || !userInfo.contains(":")) return null;
        int index = userInfo.indexOf(':');
        return new PasswordAuthentication(userInfo.substring(0, index), userInfo.substring(index + 1).toCharArray());
    }

    private String findUserInfo(String proxyHost) {
        return selector.getProxy().stream().map(item -> item.getUserInfo(proxyHost)).filter(Objects::nonNull).findFirst().orElse(null);
    }
}
