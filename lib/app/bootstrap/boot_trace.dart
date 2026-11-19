import 'dart:io';

import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 启动链路追踪，一步一行，**同步写盘**。
///
/// 为什么需要它：电视/手机上的 release 包没有控制台，普通日志开关默认关闭。
/// 一旦启动在 `runApp` 之前失败，屏幕上只剩纯黑，设备上不留下任何证据——
/// 之前的排查正是在这里卡死的（"LOGS 目录没有日志"）。
///
/// 因此这里刻意不依赖 [AppPathManager]（它自己也要初始化，可能就是失败点），
/// 而是自己算一个外部 cache 路径；也不依赖设置开关，永远写。每次启动清空
/// 重写，文件只描述**本次**启动，不会越滚越大。
class BootTrace {
  BootTrace._();

  static File? _file;
  static final Stopwatch _clock = Stopwatch()..start();

  /// 追踪文件绝对路径，失败页上直接展示给用户，避免"日志在哪"的来回。
  static String? get path => _file?.path;

  /// 成功/失败步数，用于失败页给出一个粗粒度进度。
  static int okSteps = 0;
  static int failedSteps = 0;

  /// 设备摘要（品牌/型号/API/支持的 ABI），失败页直接展示。
  ///
  /// 装错 ABI（64 位机装 armeabi-v7a 包）时 Dart 侧来不及跑任何代码，
  /// 但只要还有一帧能画出来，这行就能替用户回答"我该装哪个包"。
  static String? deviceSummary;

  /// 记一条设备信息，同时落盘。
  static void setDevice(String summary) {
    deviceSummary = summary;
    _write('device: $summary');
  }

  static Future<void> init() async {
    try {
      // path_provider 走平台通道，必须先初始化 binding，否则这里直接抛
      // "Binding has not yet been initialized"，追踪文件永远建不出来。
      WidgetsFlutterBinding.ensureInitialized();

      // 依次尝试：外部 cache（用户在文件管理器里最容易找到）→ 内部临时目录
      // → 应用支持目录。任何一个能写成就够用，全失败才放弃。
      final bases = <Directory>[];
      try {
        final external = await getExternalCacheDirectories();
        if (external != null) bases.addAll(external);
      } catch (_) {}
      for (final Future<Directory> Function() getter in <Future<Directory> Function()>[
        getTemporaryDirectory,
        getApplicationSupportDirectory,
      ]) {
        try {
          bases.add(await getter());
        } catch (_) {}
      }

      for (final base in bases) {
        try {
          final dir = Directory(p.join(base.path, 'LOGS'));
          if (!await dir.exists()) await dir.create(recursive: true);
          final file = File(p.join(dir.path, 'boot_trace.log'));
          // 截断：本文件只保留当前这次启动。
          await file.writeAsString('', flush: true);
          _file = file;
          _write('=== boot ${DateTime.now().toIso8601String()} ===');
          _write('platform: ${Platform.operatingSystem} pid=$pid');
          _write('trace: ${file.path}');
          return;
        } catch (_) {
          // 该目录不可写，试下一个。
        }
      }
      _file = null;
    } catch (_) {
      // 追踪本身绝不能成为启动失败的原因。
      _file = null;
    }
  }

  static void ok(String step, [int? elapsedMs]) {
    okSteps++;
    _write('+${_clock.elapsedMilliseconds}ms  OK    $step${elapsedMs == null ? '' : ' (${elapsedMs}ms)'}');
  }

  static void fail(String step, Object error, [StackTrace? stack]) {
    failedSteps++;
    _write('+${_clock.elapsedMilliseconds}ms  FAIL  $step: $error');
    if (stack != null) {
      for (final line in stack.toString().split('\n').take(12)) {
        _write('        $line');
      }
    }
  }

  static void note(String message) => _write('+${_clock.elapsedMilliseconds}ms  ..    $message');

  static void _write(String line) {
    final file = _file;
    if (file == null) return;
    try {
      // flush 必须开：进程若随后被杀，缓冲里的最后几行正是最关键的。
      file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // 忽略：追踪写不进去不能拖垮启动。
    }
  }
}
