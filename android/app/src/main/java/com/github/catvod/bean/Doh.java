/*
 * 来源：https://github.com/FongMi/TV （catvod 模块，分支 fongmi）
 * 原始许可证：GPL-3.0。本项目整体为 AGPL-3.0，GPLv3 §13 允许二者组合。
 * 用途：catvod-api.jar 只导出 spider 编译用的契约类，运行时实现类
 *      （OkHttp / OkDns / Auth / interceptor 等）由宿主 App 提供。
 *      此处补齐的正是这批类，否则 spider 调 Spider.safeDns() /
 *      Decoder 时会 NoClassDefFoundError。
 * 改动：仅做集成适配，未修改业务逻辑。
 */
package com.github.catvod.bean;

import android.content.Context;
import android.text.TextUtils;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.google.gson.Gson;
import com.google.gson.JsonElement;
import com.google.gson.annotations.SerializedName;
import com.google.gson.reflect.TypeToken;

import java.lang.reflect.Type;
import java.net.InetAddress;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class Doh {

    @SerializedName("name")
    private String name;
    @SerializedName("url")
    private String url;
    @SerializedName("ips")
    private List<String> ips;

    /**
     * 上游实现是从 catvod 模块自己的 `string-array` 资源里读预置 DoH 服务器列表
     * （`R.array.doh_url` / `R.array.doh_name`）。我们是集成方，namespace 不同，
     * 没有这套资源，因此返回空列表。
     *
     * 空列表是安全默认：`OkDns` 在没有 DoH 时回退到 `Dns.SYSTEM`，
     * `Spider.safeDns()` 主流程不受影响；只是不再走加密 DNS。
     * 需要自定义 DoH 时由调用方用 `OkDns.setDoh(Doh)` 传入。
     */
    public static List<Doh> get(Context context) {
        return new ArrayList<>();
    }

    public static Doh objectFrom(String str) {
        Doh item = new Gson().fromJson(str, Doh.class);
        return item == null ? new Doh() : item;
    }

    public static List<Doh> arrayFrom(JsonElement element) {
        try {
            Type listType = TypeToken.getParameterized(List.class, Doh.class).getType();
            List<Doh> items = new Gson().fromJson(element, listType);
            return items == null ? new ArrayList<>() : items;
        } catch (Exception e) {
            return new ArrayList<>();
        }
    }

    public Doh name(String name) {
        this.name = name;
        return this;
    }

    public Doh url(String url) {
        this.url = url;
        return this;
    }

    public String getName() {
        return TextUtils.isEmpty(name) ? "" : name;
    }

    public String getUrl() {
        return TextUtils.isEmpty(url) ? "" : url;
    }

    public List<String> getIps() {
        return ips == null ? Collections.emptyList() : ips;
    }

    public List<InetAddress> getHosts() {
        try {
            List<InetAddress> list = new ArrayList<>();
            for (String ip : getIps()) list.add(InetAddress.getByName(ip));
            return list.isEmpty() ? null : list;
        } catch (Exception ignored) {
            return null;
        }
    }

    @Override
    public boolean equals(@Nullable Object obj) {
        if (this == obj) return true;
        if (!(obj instanceof Doh it)) return false;
        return getUrl().equals(it.getUrl());
    }

    @Override
    public int hashCode() {
        return getUrl().hashCode();
    }

    @NonNull
    @Override
    public String toString() {
        return new Gson().toJson(this);
    }
}
