/*
 * 本文件不是 FongMi/TV 上游的逐字拷贝，而是针对本宿主的改写实现。
 *
 * 上游同名类（FongMi/TV catvod 模块，commit b27ba75，GPL-3.0）把 QuickJS 当作
 * 「独立插件 APK」分发：从 PackageManager 查 com.fongmi.runtime.quickjs，
 * 校验签名/ABI/payload，再用 DexClassLoader 加载 com.fongmi.quickjs.RuntimeEntry，
 * 并且显式拒绝宿主自带实现（"Runtime implementation is bundled in the host"）。
 *
 * 本项目的产品形态是单 APK 直装，不引入插件包，因此这里保留上游的枚举名与
 * 对外的二进制签名（catvod-api.jar 里的 com.github.catvod.utils.Js 只用到
 * QUICKJS 常量与 entry(Class) 两个成员），但把实现换成「内置」：
 *   - entry() 直接返回宿主内的 com.fongmi.quickjs.RuntimeEntry；
 *   - load()  加载宿主 nativeLibraryDir 里的 libquickjs-wrapper.so；
 *   - readAsset() 从宿主 assets/ 读取 JS 运行时脚本。
 *
 * 许可证：本文件与 com.fongmi.quickjs.* 一同受 GPL-3.0 约束，
 * 详见仓库根目录 THIRD_PARTY_NOTICES.md。
 */

package com.github.catvod.utils;

import android.content.Context;
import android.content.res.AssetManager;

import com.github.catvod.Runtime;
import com.github.catvod.runtime.RuntimePlugin;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.function.Consumer;

public enum RuntimeModule {

    PYTHON("python", "Python", "libchaquopy_java.so"),
    NODEJS("nodejs", "Node.js", "libnode.so"),
    QUICKJS("quickjs", "QuickJS", "libquickjs-wrapper.so"),
    THUNDER("thunder", "Thunder", "libxl_thunder_sdk.so"),
    MPV("mpv", "MPV", "libplayer.so"),
    BDJ("bdj", "BD-J", "");

    public final String id;
    public final String title;
    private final String library;

    private volatile boolean loaded;
    private volatile RuntimePlugin entry;

    RuntimeModule(String id, String title, String library) {
        this.id = id;
        this.title = title;
        this.library = library;
    }

    /** 与上游保持同值，用于 JS 字节码缓存的命名空间。 */
    public String getCompatibilityId() {
        return switch (this) {
            case PYTHON -> "catvod-python-plugin-v4";
            case NODEJS -> "catvod-nodejs-plugin-v3";
            case QUICKJS -> "fongmi-quickjs-ng-0.17-v13";
            case THUNDER -> "catvod-thunder-plugin-v1";
            case MPV -> "mpv-jni-ffmpeg-shared-v1";
            case BDJ -> "libbluray-1.4.1-openjdk8-zero-v1";
        };
    }

    public String getEntryClass() {
        return switch (this) {
            case PYTHON -> "com.fongmi.chaquo.RuntimeEntry";
            case NODEJS -> "com.fongmi.nodejs.RuntimeEntry";
            case QUICKJS -> "com.fongmi.quickjs.RuntimeEntry";
            case THUNDER -> "com.xunlei.downloadlib.RuntimeEntry";
            default -> "";
        };
    }

    /** 宿主只内置了 QuickJS 与 Python，其余模块以「未安装」上报，便于界面显示真实能力。 */
    public boolean isInstalled() {
        try {
            return switch (this) {
                case QUICKJS -> nativeLibrary().isFile();
                // Python 的 .so 由 Chaquopy 的 AndroidPlatform 自己加载，
                // 这里只确认运行时类真的在 classpath 上。
                case PYTHON -> {
                    Class.forName("com.chaquo.python.Python");
                    yield true;
                }
                default -> false;
            };
        } catch (ClassNotFoundException | RuntimeException e) {
            // Runtime 还没 set(context) 或类被裁掉时都不应让能力探测抛异常。
            return false;
        }
    }

    public boolean isExternal() {
        return false;
    }

    /** 能力前置检查：上游插件模型用它确认「已安装且可加载」，这里做同等语义的内置检查。 */
    public void require() {
        if (!isInstalled()) throw new IllegalStateException(title + " 未随宿主内置");
    }

    public synchronized <T extends RuntimePlugin> T entry(Class<T> type) {
        if (this == QUICKJS) {
            if (entry == null) {
                load(System::load);
                entry = new com.fongmi.quickjs.RuntimeEntry();
            }
            return type.cast(entry);
        }
        if (this == PYTHON) {
            if (entry == null) entry = new com.fongmi.chaquo.RuntimeEntry();
            return type.cast(entry);
        }
        throw new IllegalStateException(title + " 未随宿主内置");
    }

    public synchronized void load(Consumer<String> loader) {
        // Python 的 native 库（libpython3.x.so 等）由 Chaquopy 的 AndroidPlatform
        // 在 Python.start() 时自行加载，宿主不需要也不应该抢先 System.load。
        if (this == PYTHON) {
            require();
            return;
        }
        if (this != QUICKJS) throw new IllegalStateException(title + " 未随宿主内置");
        if (loaded) return;
        File file = nativeLibrary();
        if (!file.isFile()) throw new IllegalStateException("缺少 " + library + "，当前 ABI 未打包 QuickJS 运行时");
        loader.accept(file.getPath());
        loaded = true;
    }

    /**
     * 读取 JS 运行时脚本。
     *
     * 上游入参有两种写法：`Spider` 传 `js/lib/spider.js`，`Module` 传 `assets://js/lib/catvod.js`。
     * 两者都归一到 APK 的 `assets/` 之下。
     */
    public String readAsset(String path) {
        if (this != QUICKJS) throw new IllegalStateException(title + " 未随宿主内置");
        String asset = path.replace("assets://", "");
        while (asset.startsWith("assets/")) asset = asset.substring("assets/".length());
        if (asset.startsWith("/")) asset = asset.substring(1);
        AssetManager assets = context().getAssets();
        try (InputStream input = assets.open(asset)) {
            ByteArrayOutputStream output = new ByteArrayOutputStream(Math.max(1024, input.available()));
            byte[] buffer = new byte[8192];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new IllegalStateException("读取 QuickJS 运行时脚本失败：" + asset, e);
        }
    }

    private File nativeLibrary() {
        return new File(context().getApplicationInfo().nativeLibraryDir, library);
    }

    private static Context context() {
        Context context = Runtime.context();
        if (context == null) throw new IllegalStateException("Runtime 尚未初始化，请在加载 QuickJS 之前调用 Runtime.set(context)");
        return context;
    }
}
