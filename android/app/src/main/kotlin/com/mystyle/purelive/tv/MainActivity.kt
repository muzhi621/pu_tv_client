package com.mystyle.purelive.tv
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var nativeHttpChannel: NativeHttpChannel? = null
    private var vodSpiderBridge: VodSpiderBridge? = null

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
    }

    override fun onDestroy() {
        nativeHttpChannel?.dispose()
        nativeHttpChannel = null
        vodSpiderBridge?.dispose()
        vodSpiderBridge = null
        super.onDestroy()
    }
}
