package com.mystyle.purelive.tv
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeHttpChannel: NativeHttpChannel? = null
    private var vodSpiderBridge: VodSpiderBridge? = null
    private var tvKeyBridge: TvKeyBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (nativeHttpChannel == null) {
            nativeHttpChannel = NativeHttpChannel(flutterEngine.dartExecutor.binaryMessenger)
        }
        // TVBox 爬虫宿主：DexClassLoader 里的 spider 会通过 getActivity() 弹
        // dialog、读 SharedPreferences，所以传 Activity 而不是 applicationContext。
        if (vodSpiderBridge == null) {
            vodSpiderBridge = VodSpiderBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        }
        // 遥控器兜底：视频 surface 抢焦点 / 焦点树断链时 Flutter 收不到按键，
        // 这里在按键进入引擎之前截一层（详见 TvKeyBridge 注释）。
        if (tvKeyBridge == null) {
            tvKeyBridge = TvKeyBridge(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    /**
     * 播放页纯视频态时由 Dart 打开兜底通道，此处的按键会被转发给 Dart 并跳过
     * `super`，避免同一次按键被处理两次；其余情况原样交给 Flutter。
     */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (tvKeyBridge?.handle(event) == true) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        nativeHttpChannel?.dispose()
        nativeHttpChannel = null
        vodSpiderBridge?.dispose()
        vodSpiderBridge = null
        tvKeyBridge?.dispose()
        tvKeyBridge = null
        super.onDestroy()
    }
}
