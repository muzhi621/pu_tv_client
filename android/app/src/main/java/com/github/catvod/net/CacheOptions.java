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

import com.github.catvod.utils.Json;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

final class CacheOptions {

    final long ttl;
    final boolean stale;
    final boolean persist;

    CacheOptions(long ttl, boolean stale, boolean persist) {
        this.ttl = ttl;
        this.stale = stale;
        this.persist = persist;
    }

    static CacheOptions from(String json) {
        JsonObject options = Json.strict(json).getAsJsonObject();
        for (String key : options.keySet()) if (!key.equals("ttl") && !key.equals("stale") && !key.equals("persist")) throw new IllegalArgumentException("Invalid cache option: " + key);
        JsonElement ttl = options.get("ttl");
        if (ttl == null || !ttl.isJsonPrimitive() || !ttl.getAsJsonPrimitive().isNumber()) throw new IllegalArgumentException("Cache ttl requires integer milliseconds");
        long value = ttl.getAsBigDecimal().longValueExact();
        if (value < 0) throw new IllegalArgumentException("Cache ttl must not be negative");
        return new CacheOptions(value, flag(options, "stale", true), flag(options, "persist", false));
    }

    private static boolean flag(JsonObject options, String key, boolean fallback) {
        if (!options.has(key)) return fallback;
        JsonElement value = options.get(key);
        if (!value.isJsonPrimitive() || !value.getAsJsonPrimitive().isBoolean()) throw new IllegalArgumentException("Cache " + key + " requires a boolean");
        return value.getAsBoolean();
    }
}
