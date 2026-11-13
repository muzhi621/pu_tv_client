/*
 * 来源：https://github.com/FongMi/TV （catvod 模块，分支 fongmi）
 * 原始许可证：GPL-3.0。本项目整体为 AGPL-3.0，GPLv3 §13 允许二者组合。
 * 用途：catvod-api.jar 只导出 spider 编译用的契约类，运行时实现类
 *      （OkHttp / OkDns / Auth / interceptor 等）由宿主 App 提供。
 *      此处补齐的正是这批类，否则 spider 调 Spider.safeDns() /
 *      Decoder 时会 NoClassDefFoundError。
 * 改动：仅做集成适配，未修改业务逻辑。
 */
package com.github.catvod.net.interceptor;

import androidx.annotation.NonNull;

import com.github.catvod.utils.Auth;
import com.google.common.net.HttpHeaders;

import java.io.IOException;
import java.util.concurrent.ConcurrentHashMap;

import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.Request;
import okhttp3.Response;

public class RequestInterceptor implements Interceptor {

    private final ConcurrentHashMap<String, String> authMap;

    public RequestInterceptor() {
        authMap = new ConcurrentHashMap<>();
    }

    public void clear() {
        authMap.clear();
    }

    @NonNull
    @Override
    public Response intercept(@NonNull Chain chain) throws IOException {
        Request request = chain.request();
        if (request.tag(Auth.Context.class) != null || request.header(HttpHeaders.AUTHORIZATION) != null || request.url().uri().getUserInfo() != null) return chain.proceed(request);
        Request.Builder builder = request.newBuilder();
        HttpUrl url = request.url();
        checkAuth(url, builder);
        return chain.proceed(builder.build());
    }

    private void checkAuth(HttpUrl url, Request.Builder builder) {
        String host = url.host();
        String auth = url.queryParameter("auth");
        if (auth != null) authMap.put(host, auth);
        else if (authMap.containsKey(host)) builder.url(url.newBuilder().addQueryParameter("auth", authMap.get(host)).build());
    }
}
