package com.fongmi.chaquo;

import com.chaquo.python.PyObject;
import com.chaquo.python.Python;
import com.chaquo.python.android.AndroidPlatform;
import com.github.catvod.Runtime;
import com.github.catvod.net.Net;
import com.github.catvod.utils.Path;
import com.github.catvod.utils.RuntimeModule;

import java.util.function.Supplier;

public class Loader {

    private final PyObject app;

    public Loader() {
        RuntimeModule.PYTHON.require();
        synchronized (Python.class) {
            // 上游这里用自写的 com.fongmi.chaquo.Platform（它重写 asset 查找，期望 Python
            // 运行时以「插件 APK」形式挂在 lib/<abi>/chaquopy/ 下）。本项目把运行时直接
            // 打进宿主 APK，结构就是 chaquopy 的标准布局，因此改用官方 AndroidPlatform：
            // 它自己从 APK 的 assets/chaquopy 与 lib/<abi> 加载，行为等价且更稳。
            if (!Python.isStarted()) Python.start(new AndroidPlatform(Runtime.context()));
            app = Python.getInstance().getModule("app");
        }
    }

    public static void check() {
        new Loader();
        Python python = Python.getInstance();
        // 上游这里顺便 import ujson / Crypto / cryptography 来验证原生 wheel 是否齐全。
        // 我们首批只带 CPython + 纯 Python 包（不引入 numpy/lxml/cryptography 这三类
        // 原生扩展），所以这里只验证解释器本身能跑；站点若 import 缺失包会自己报
        // ModuleNotFoundError，错误会经 Spider 抛回 Dart 侧，不会被这里掩盖。
        try (PyObject globals = python.getBuiltins().callAttr("dict");
             PyObject result = python.getBuiltins().callAttr("eval", "6 * 7", globals)) {
            if (result.toInt() != 42) throw new IllegalStateException("Python evaluation returned an unexpected result");
        }
    }

    public Spider spider(String api) {
        return spider(api, null);
    }

    public Spider spider(String api, Net.Cookies cookies) {
        return spider(api, cookies, null);
    }

    public Spider spider(String api, Net.Cookies cookies, Supplier<String> userAgent) {
        return spider(api, "", cookies, userAgent);
    }

    public Spider spider(String api, String siteKey, Net.Cookies cookies, Supplier<String> userAgent) {
        Net net = siteKey.isEmpty() ? new Net(cookies) : new Net(cookies, siteKey);
        PyObject obj = null;
        try {
            obj = app.callAttr("spider", Path.py().getAbsolutePath(), api, siteKey, net);
            Spider spider = new Spider(app, obj, api, cookies, userAgent, net);
            spider.siteKey = siteKey;
            return spider;
        } catch (RuntimeException | Error e) {
            releaseSpider(net, obj, e);
            throw e;
        }
    }

    private void releaseSpider(Net net, PyObject obj, Throwable failure) {
        try {
            net.close();
        } catch (RuntimeException | Error error) {
            if (error != failure) failure.addSuppressed(error);
        }
        try {
            if (obj != null) app.callAttr("release", obj);
        } catch (RuntimeException | Error error) {
            if (error != failure) failure.addSuppressed(error);
        }
    }
}
