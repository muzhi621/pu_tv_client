import 'dart:ui' show PlatformDispatcher;

import 'package:pure_live/app/app.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/bootstrap/boot_trace.dart';
import 'package:pure_live/app/bootstrap/initialized.dart';
import 'package:pure_live/app/bootstrap/startup_failure_app.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'package:pure_live/app/consts/app_theme_consts.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

void main() async {
  final initializer = AppInitializer();

  // 启动期任何未捕获异常都要留痕，否则设备上只剩纯黑屏、什么都不知道。
  FlutterError.onError = (details) {
    BootTrace.fail('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };

  // 未捕获的异步异常（Future 里抛错）默认静默丢掉，同样要留痕。
  PlatformDispatcher.instance.onError = (error, stack) {
    BootTrace.fail('uncaughtAsync', error, stack);
    return true; // 已记录，不再交给系统
  };

  // release 包遇到 build 抛错默认画灰屏；换成可读文本，便于用户截图反馈。
  ErrorWidget.builder = (details) {
    BootTrace.fail('widgetBuild', details.exception, details.stack);
    return BuildErrorView(message: details.exception.toString());
  };

  try {
    await initializer.initialize();
  } catch (error, stack) {
    initializer.fatalError ??= error;
    initializer.fatalStackTrace ??= stack;
    BootTrace.fail('initialize (uncaught)', error, stack);
  }

  // 初始化没完成就**不要**去碰 provider（container 为空会抛
  // LateInitializationError，又是一次纯黑屏）。改为渲染一张能看见的失败页：
  // 上面直接写出失败步骤和日志路径，用户截图即可定位。
  if (!initializer.isReady) {
    runApp(
      StartupFailureApp(
        error: initializer.fatalError,
        tracePath: BootTrace.path,
        deviceInfo: BootTrace.deviceSummary,
        okSteps: BootTrace.okSteps,
        failedSteps: BootTrace.failedSteps,
      ),
    );
    return;
  }

  runApp(
    EasyLocalization(
      supportedLocales: AppThemeConsts.languages.values.toList(growable: false),
      path: 'assets/translations',
      fallbackLocale: const Locale('zh'),
      // The language preference lives in Hive and is only readable once storage
      // is ready, so the saved language is applied up front to avoid a switch.
      startLocale: Locale(SettingsService.to.theme.locale.languageCode),
      useOnlyLangCode: true,
      child: UncontrolledProviderScope(container: initializer.container!, child: App()),
    ),
  );

  // 心跳与生命周期监听挂在 App 首帧之后：此时 WidgetsBinding 与第一帧菜单均已
  // 就绪。bootstrap 仍在 initialize() 中、即 runApp 之前完成，既有顺序不受影响。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    RemoteConfigService.startHeartbeat();
  });
}
