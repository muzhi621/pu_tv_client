import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 遥控器兜底按键通道（Android 播放页专用），与原生 `TvKeyBridge` 配对。
///
/// 为什么需要它：播放页的按键本应由 [Focus] 链处理，但视频 surface 走
/// `mediacodec_embed` 兼容路径（原生 SurfaceView）或平台层抢走窗口焦点时，
/// 按键根本进不到 Flutter 引擎——Dart 侧再兜底也收不到，表现为「画面在播、
/// 遥控器按什么都没反应，菜单唤不出来」。原生层在 `dispatchKeyEvent` 里可以
/// 稳定拿到这些按键。
///
/// 约定：**只有播放页处于纯视频态时才打开**（由 `PlayerKeyScope` 控制）。
/// 打开期间原生会消费并转发方向键/确认键，Dart 复用既有播放页按键逻辑，
/// 因此不存在「原生与 Flutter 各处理一次」的双触发；侧栏、控制条、失败浮层
/// 打开时关闭通道，按键回到 Flutter 焦点导航。
typedef TvKeyDownHandler = void Function(int androidKeyCode);

class AndroidTvKeys {
  AndroidTvKeys._();

  static const MethodChannel _channel = MethodChannel('purelive/tv_keys');

  /// 只映射播放页需要的几个 Android `KeyEvent` 键码。
  static const int keyCodeDpadUp = 19;
  static const int keyCodeDpadDown = 20;
  static const int keyCodeDpadLeft = 21;
  static const int keyCodeDpadRight = 22;
  static const int keyCodeDpadCenter = 23;
  static const int keyCodeEnter = 66;
  static const int keyCodeNumpadEnter = 160;
  static const int keyCodeMenu = 82;

  static bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 监听令牌：同一通道只能有一个 handler，新页面注册时旧页面的
  /// [stopListening] 不能把新页面刚装好的 handler 清掉。
  static int _token = 0;

  /// 开关接管。非 Android 或引擎未就绪时静默失败——兜底能力缺失不能
  /// 影响播放本身。
  static Future<void> setEnabled(bool enabled) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } catch (_) {
      // 通道不可用（引擎已销毁等）：忽略。
    }
  }

  /// 注册按键回调，返回本次注册的令牌。
  static int listen(TvKeyDownHandler onKeyDown) {
    if (!isSupported) return 0;
    final int token = ++_token;
    _channel.setMethodCallHandler((MethodCall call) async {
      // 已被新页面接管：旧页面的回调不能再消费按键。
      if (token != _token) return null;
      if (call.method != 'keyDown') return null;
      final Object? code = call.arguments;
      if (code is int) onKeyDown(code);
      return null;
    });
    return token;
  }

  /// 注销回调并关闭接管。令牌不匹配时（已被新页面接管）什么都不做。
  static void stopListening(int token) {
    if (!isSupported || token == 0 || token != _token) return;
    _channel.setMethodCallHandler(null);
    unawaited(setEnabled(false));
  }
}
