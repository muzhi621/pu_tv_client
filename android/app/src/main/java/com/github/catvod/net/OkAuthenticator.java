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

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.github.catvod.bean.Proxy;
import com.github.catvod.utils.Util;
import com.google.common.net.HttpHeaders;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.Objects;

import okhttp3.Authenticator;
import okhttp3.Credentials;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.Route;

public class OkAuthenticator implements Authenticator {

    private final OkProxySelector selector;

    public OkAuthenticator(OkProxySelector selector) {
        this.selector = selector;
    }

    @Nullable
    @Override
    public Request authenticate(@Nullable Route route, @NonNull Response response) {
        if (route == null || response.request().header(HttpHeaders.PROXY_AUTHORIZATION) != null) return null;
        if (!(route.proxy().address() instanceof InetSocketAddress proxyAddress)) return null;
        Request request = response.request();
        String userInfo = findUserInfo(request, proxyAddress.getHostName());
        if (userInfo == null) return null;
        return request.newBuilder().header(HttpHeaders.PROXY_AUTHORIZATION, basic(userInfo)).build();
    }

    private String basic(String userInfo) {
        int separator = userInfo.indexOf(':');
        String username = separator == -1 ? userInfo : userInfo.substring(0, separator);
        String password = separator == -1 ? "" : userInfo.substring(separator + 1);
        return Credentials.basic(username, password, StandardCharsets.UTF_8);
    }

    private String findUserInfo(Request request, String proxyHost) {
        OkProxySelector.Policy policy = request.tag(OkProxySelector.Policy.class);
        if (policy == null) return findUserInfo(request.url().host(), proxyHost);
        Proxy rule = policy.rule();
        return rule == null ? null : rule.getUserInfo(proxyHost, "http");
    }

    private String findUserInfo(String requestHost, String proxyHost) {
        return selector.getProxy().stream().filter(item -> matchesHost(item, requestHost)).map(item -> item.getUserInfo(proxyHost, "http")).filter(Objects::nonNull).findFirst().orElse(null);
    }

    private boolean matchesHost(Proxy item, String requestHost) {
        return item.getHosts().stream().anyMatch(host -> Util.containOrMatch(requestHost, host));
    }
}
