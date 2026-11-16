package com.mystyle.sutv.tv

import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 遥控器兜底按键通道（Android 播放页专用）。
 *
 * 解决的现象：画面在播，遥控器按什么都没反应，控制条（菜单）唤不出来。
 * 这类故障 Dart 层的兜底救不了，因为它们都发生在按键进入引擎之前：
 *  1. 视频 surface 走了 `mediacodec_embed` 兼容路径（原生 SurfaceView），
 *     或平台层抢走窗口焦点，Flutter 根本收不到按键；
 *  2. 焦点树被浮层/区域改写过，按键被派发到空节点。
 * `FlutterActivity.dispatchKeyEvent` 在按键进入引擎之前执行，因此这里能
 * 稳定拿到全部按键。
 *
 * 语义：本通道只负责「接管」，不负责「语义」。
 *  - `enabled` 由 Dart 控制，且只在播放页处于纯视频态时打开。此状态下本
 *    通道消费（consume）方向键/确认键并转发给 Dart，由 Dart 复用既有的
 *    播放页按键逻辑，因此不会出现「原生与 Flutter 各处理一次」的双触发。
 *  - 侧栏 / 控制条 / 失败浮层打开时 Dart 会关掉 `enabled`，按键交回 Flutter
 *    焦点导航，播放列表滚动等框架默认行为不受影响。
 *  - 返回键、音量键、媒体键一律不接管。
 */
internal class TvKeyBridge(binaryMessenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    companion object {
        private const val CHANNEL = "purelive/tv_keys"

        /** 只接管 D-pad 与确认键；其余按键（返回/音量/媒体/数字）留给平台。 */
        private val FORWARDED = setOf(
            KeyEvent.KEYCODE_DPAD_UP,
            KeyEvent.KEYCODE_DPAD_DOWN,
            KeyEvent.KEYCODE_DPAD_LEFT,
            KeyEvent.KEYCODE_DPAD_RIGHT,
            KeyEvent.KEYCODE_DPAD_CENTER,
            KeyEvent.KEYCODE_ENTER,
            KeyEvent.KEYCODE_NUMPAD_ENTER,
            KeyEvent.KEYCODE_MENU,
        )
    }

    @Volatile
    private var enabled = false

    private val channel = MethodChannel(binaryMessenger, CHANNEL)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setEnabled" -> {
                enabled = call.arguments as? Boolean ?: false
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * 处理一次按键事件。
     *
     * @return true 表示事件已被本通道接管，调用方必须跳过 `super`，
     *         否则返回键等按键会被错误地吞掉。
     */
    fun handle(event: KeyEvent): Boolean {
        if (!enabled) return false
        if (event.keyCode !in FORWARDED) return false
        if (event.action != KeyEvent.ACTION_DOWN && event.action != KeyEvent.ACTION_UP) return false

        // 只转发首次按下：长按重复由 Dart 侧按需处理，避免一次长按刷爆通道。
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            try {
                channel.invokeMethod("keyDown", event.keyCode)
            } catch (_: Throwable) {
                // 引擎已销毁：交回平台，不能把按键吞掉。
                return false
            }
        }
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
