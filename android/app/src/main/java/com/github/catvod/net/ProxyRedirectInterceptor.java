/*
 * 来源：https://github.com/FongMi/TV （catvod 模块，分支 fongmi）
 * 原始许可证：GPL-3.0。本项目整体为 AGPL-3.0，GPLv3 §13 允许二者组合。
 * 用途：catvod-api.jar 只导出 spider 编译用的契约类，运行时实现类
 *      （OkHttp / OkDns / Auth / interceptor 等）由宿主 App 提供。
 *      此处补齐的正是这批类，否则 spider 调 Spider.safeDns() /
 *      Decoder 时会 NoClassDefFoundError。
 * 改动：仅做集成适配，未修改业务逻辑。
 *
 * 与上游的差异（OkHttp 4.12 适配）：
 *   1. 上游用 `Chain.withProxySelector(policy)` 逐请求换代理，这是 OkHttp 5.x
 *      才有的 API。本宿主停在 4.12.0，代理统一由 client 的 proxySelector 决定，
 *      这里只保留「按 policy 打 Proxy-Authorization」的效果。
 *   2. `Chain.getFollowSslRedirects()` 同样只有 5.x 有，改为常量 true
 *      （client 已关了自动跟随，是否允许跨协议由本拦截器判断）。
 *   3. `ResponseBody.EMPTY` 是 5.x 常量，4.x 用 `create(null, byte[0])`。
 */
package com.github.catvod.net;

import androidx.annotation.NonNull;

import com.github.catvod.utils.Auth;

import java.io.IOException;
import java.net.ProtocolException;

import okhttp3.HttpUrl;
import okhttp3.Interceptor;
import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.ResponseBody;

final class ProxyRedirectInterceptor implements Interceptor {

    private static final int MAX_FOLLOW_UPS = 20;

    /**
     * OkHttp 4.x 的 Chain 不暴露 followSslRedirects 开关，宿主统一按 true 处理：
     * 是否真的跟随由 {@link #redirectUrl} 里的同协议判断决定。
     */
    private static final boolean FOLLOW_SSL_REDIRECTS = true;

    private final OkProxySelector selector;

    ProxyRedirectInterceptor(OkProxySelector selector) {
        this.selector = selector;
    }

    @NonNull
    @Override
    public Response intercept(@NonNull Chain chain) throws IOException {
        Request request = chain.request();
        OkProxySelector.Policy previousPolicy = null;
        Response previousResponse = null;
        int followUpCount = 0;
        while (true) {
            // 4.x 无法逐请求替换代理：代理由 client 的 proxySelector 全局决定，
            // 这里只按 policy 补 Proxy-Authorization。
            OkProxySelector.Policy policy = selector == null ? null : selector.policy(request.url(), previousPolicy);
            request = withPolicy(request, policy, previousPolicy);
            Response response = chain.proceed(request);
            followUpCount += countFollowUps(response);
            response = withPriorResponse(response, previousResponse);
            checkFollowUps(response, followUpCount);
            NetOptions options = request.tag(NetOptions.class);
            if (options != null && !options.isRedirect()) return response;
            Request followUp = redirect(response, FOLLOW_SSL_REDIRECTS);
            if (followUp == null) return response;
            RequestBody body = followUp.body();
            if (body != null && body.isOneShot()) return response;
            response.close();
            if (++followUpCount > MAX_FOLLOW_UPS) throw new ProtocolException("Too many follow-up requests: " + followUpCount);
            previousResponse = response.newBuilder().body(ResponseBody.create((MediaType) null, new byte[0])).build();
            previousPolicy = policy;
            request = followUp;
        }
    }

    private Request withPolicy(Request request, OkProxySelector.Policy policy, OkProxySelector.Policy previous) {
        if (policy == null) return request;
        Request.Builder builder = request.newBuilder();
        if (previous != null && !policy.sharesProxyCredentials(previous)) builder.removeHeader("Proxy-Authorization");
        return builder.tag(OkProxySelector.Policy.class, policy).build();
    }

    private int countFollowUps(Response response) {
        int count = 0;
        for (Response prior = response.priorResponse(); prior != null; prior = prior.priorResponse()) count++;
        return count;
    }

    private void checkFollowUps(Response response, int count) throws ProtocolException {
        if (count <= MAX_FOLLOW_UPS) return;
        response.close();
        throw new ProtocolException("Too many follow-up requests: " + count);
    }

    private Response withPriorResponse(Response response, Response previous) {
        if (previous == null) return response;
        Response prior = response.priorResponse();
        return response.newBuilder().priorResponse(prior == null ? previous : withPriorResponse(prior, previous)).build();
    }

    private Request redirect(Response response, boolean followSslRedirects) {
        HttpUrl target = redirectUrl(response, followSslRedirects);
        if (target == null) return null;
        Request.Builder builder = response.request().newBuilder();
        redirectMethod(builder, response.request(), response.code());
        if (!sameOrigin(response.request().url(), target)) builder.removeHeader("Authorization");
        Request redirected = builder.url(target).build();
        Auth.Context auth = redirected.tag(Auth.Context.class);
        return auth == null ? redirected : OkHttp.applyAuth(redirected, auth);
    }

    private HttpUrl redirectUrl(Response response, boolean followSslRedirects) {
        int code = response.code();
        if (code != 300 && code != 301 && code != 302 && code != 303 && code != 307 && code != 308) return null;
        String location = response.header("Location");
        if (location == null) return null;
        HttpUrl source = response.request().url();
        HttpUrl target = source.resolve(location);
        if (target == null || !source.scheme().equals(target.scheme()) && !followSslRedirects) return null;
        return target;
    }

    private void redirectMethod(Request.Builder builder, Request request, int code) {
        String method = request.method();
        if ("GET".equals(method) || "HEAD".equals(method)) return;
        if (redirectsToGet(method, code)) builder.method("GET", null).removeHeader("Transfer-Encoding").removeHeader("Content-Length").removeHeader("Content-Type");
        else builder.method(method, request.body());
    }

    private boolean sameOrigin(HttpUrl source, HttpUrl target) {
        return source.scheme().equals(target.scheme()) && source.host().equals(target.host()) && source.port() == target.port();
    }

    private boolean redirectsToGet(String method, int code) {
        if (code == 303) return !"PROPFIND".equals(method);
        if (code == 307 || code == 308) return false;
        return !"PROPFIND".equals(method) && !"QUERY".equals(method);
    }
}
