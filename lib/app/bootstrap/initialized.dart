import 'dart:io';
import 'dart:async';
import 'package:hive_ce/hive_ce.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_core/media_core.dart';
import 'package:pure_live/services/index.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:media_core_logging/media_core_logging.dart';
import 'package:pure_live/player/global_player_service.dart';
import 'package:pure_live/app/bootstrap/app_path_manager.dart';
import 'package:pure_live/app/bootstrap/boot_trace.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:pure_live/core/common/api_proxy_policy.dart';
import 'package:pure_live/core/platform/local_network_access.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

class AppInitializer {
  static final AppInitializer _instance = AppInitializer._internal();
  bool _isInitialized = false;
  ProviderContainer? _container;

  /// 首个致命错误。非空表示启动没能完成，`main()` 应改为渲染失败页。
  Object? fatalError;
  StackTrace? fatalStackTrace;

  factory AppInitializer() {
    return _instance;
  }

  AppInitializer._internal();

  /// 只有 container 建好、核心服务注入完成才算就绪。
  ProviderContainer? get container => _container;

  bool get isReady => _isInitialized && _container != null;

  /// 单步执行：失败只记录、不抛出，让启动继续往下走。
  ///
  /// 这是本次改动的核心——过去任何一步（尤其是没有被 try 包住的
  /// `LegacySettingsMigration.migrateIfNeeded`）抛异常都会让 `runApp`
  /// 永远执行不到，表现就是纯黑屏且无日志。
  Future<void> _step(String name, Future<void> Function() body) async {
    final sw = Stopwatch()..start();
    // 先记「开始」再执行：若是 native 崩溃（.so 加载失败）把进程直接杀掉，
    // Dart 来不及写 FAIL，最后一行 "begin X" 就是死掉的那一步。
    BootTrace.note('begin $name');
    try {
      await body();
      BootTrace.ok(name, sw.elapsedMilliseconds);
    } catch (error, stack) {
      BootTrace.fail(name, error, stack);
    }
  }

  /// 后台任务：同样记录失败，但绝不冒泡成未捕获异常。
  void _background(String name, Future<void> Function() body) {
    unawaited(() async {
      final sw = Stopwatch()..start();
      BootTrace.note('begin $name (background)');
      try {
        await body();
        BootTrace.ok('$name (background)', sw.elapsedMilliseconds);
      } catch (error, stack) {
        BootTrace.fail('$name (background)', error, stack);
      }
    }());
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    // 第一步就把追踪文件建起来：之后每一步无论成败都留下痕迹。
    await BootTrace.init();

    await _step('ensureInitialized', () async {
      WidgetsFlutterBinding.ensureInitialized();
    });

    await _step('screenOrientation', () async {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeRight, DeviceOrientation.landscapeLeft]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
    });

    // 设备指纹先记下来：ABI/API 是排查"装了不兼容包导致秒退"的第一手信息，
    // 一旦启动在后面某步失败，失败页上能直接看到该装哪个安装包。
    await _step('deviceProbe', () async {
      if (!Platform.isAndroid) {
        BootTrace.setDevice('${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
        return;
      }
      final info = await DeviceInfoPlugin().androidInfo;
      final abis = info.supportedAbis.isEmpty ? 'unknown' : info.supportedAbis.join(',');
      BootTrace.setDevice('${info.brand} ${info.model} · API ${info.version.sdkInt} · abis=$abis');
    });

    // 路径管理器必须先于 Hive / 日志：Hive 目录、LOGS 目录都从它取。
    await _step('appPathManager', () async {
      await AppPathManager().initialize();
    });

    await _step('documentsDir+hiveInit', () async {
      final appDir = await getApplicationDocumentsDirectory();
      Hive.init('${appDir.path}${Platform.pathSeparator}pure_live_Tv');
    });

    await _step('hivePrefInit', () async {
      await HivePrefUtil.init();
    });

    await _step('mediaKitInit', () async {
      MediaKit.ensureInitialized();
    });

    // Image cache setup is not needed for the first frame: run it in the
    // background so startup is not blocked (the getter falls back to the
    // default cache until it is ready).
    //
    // The provider runs per image request, so the interface-proxy switch applies
    // to cached images too without re-initializing the cache.
    _background('imageCache', () async {
      await CustomImageCacheManager.initialize(proxyDirectiveProvider: ApiProxyPolicy.currentDirective);
    });

    await _step('providerContainer', () async {
      _container = ProviderContainer();
    });

    if (_container == null) {
      // 没有 container 就没有任何 provider，后面的步骤全部无意义。
      fatalError ??= StateError('ProviderContainer 未能创建');
      return;
    }

    await _step('settingsService', () async {
      SettingsService.to.init(_container!);
    });

    await _step('smartDialog', () async {
      SmartDialog.config.toast = SmartConfigToast(
        displayTime: const Duration(milliseconds: 3000),
        intervalTime: const Duration(milliseconds: 100),
      );
    });

    _isInitialized = true;

    // 日志落盘提前到迁移之前：迁移正是历史上最可能抛异常的一步，把这行
    // 放在它后面等于"崩了就没有日志"。这里 container 已就绪，开关可读。
    await _step('logFile', () async {
      await Log.init();
      BootTrace.note('log file: ${Log.fileLoggingEnabled ? 'on' : 'off'}');
    });

    // Migrate legacy Hive keys into the v2 settings store.
    await _step('legacyMigration', () async {
      await LegacySettingsMigration.migrateIfNeeded();
    });

    // Cloud config must land AFTER the legacy migration (which would otherwise
    // re-add every supported site) and BEFORE runApp (the agreement redirect and
    // the side-menu list are decided on the first frame). Failures degrade to
    // the cached document / built-in seed and never block startup.
    await _step('remoteConfigBootstrap', () async {
      await RemoteConfigService.bootstrap();
    });

    // Probe the platform once, early: the player kernel takes the result when it
    // is created later, and the danmaku frame budget reads it before the first
    // player exists.
    _background('platformProbe', () async {
      await GlobalPlayerService.instance.loadPlatformProvider();
    });

    await _step('websocketProxy', () async {
      configureWebSocketProxyRouting(ApiProxyPolicy.directiveFor);
    });

    // 2026-11-17：不再注入 FFmpeg。它唯一的用途是 VOD/音乐传输里给 bilibili
    // 分离音视频做 DASH 合并，而本 APK 只做 IPTV / TVBox：没有任何代码路径走到
    // IngestStrategy.ffmpegRelay，注册表里的 starter 从未被调用。
    // 保留它等于白背 libffmpegkit.so（未压缩 20 MB / 进包 9.45 MB），因此整条
    // ingest-ffmpeg 链路一起移除（configureIngestFfmpegStarter 的实参为 null 时
    // media_core_ingest 会退化为 direct，不影响普通 HLS/FLV 播放）。

    // Version info plus the startup update check.
    //
    // The check does an HTTP fetch and a JSON parse on the main isolate; running
    // it while the first frames were being built competed with startup (logcat
    // showed 65-99 skipped frames and a frame-time warning). It is deferred past
    // the first frames instead, and only the cheap package-info read happens
    // now.
    _background('versionCheck', () async {
      await VersionUtil.initPackageInfo();
      if (!SettingsService.to.appState.enableAutoCheckUpdate) return;
      await Future<void>.delayed(const Duration(seconds: 3));
      await VersionUtil().checkUpdate();
    });

    // Taobao Live was retired; its account cookie is dropped once so it cannot
    // be re-exported by a later backup.
    await _step('dropTaobaoCookie', () async {
      HivePrefUtil.remove('taobaoCookie');
    });

    // Android 17 gates sockets to a local-network proxy behind
    // ACCESS_LOCAL_NETWORK, so an existing PC/router proxy asks for it on every
    // launch. Deferred past the first frames: the request needs an attached
    // activity and must not compete with startup. The permission only exists on
    // Android, so no timer is scheduled anywhere else.
    if (Platform.isAndroid) {
      _background('localNetworkAccess', () async {
        await Future<void>.delayed(const Duration(seconds: 2));
        final proxy = SettingsService.to.proxyState;
        await LocalNetworkAccess.ensureForProxies([
          (enabled: proxy.enableAppProxy, host: proxy.appProxyHost),
          (enabled: proxy.enableProxy, host: proxy.proxyHost),
        ]);
      });
    }

    // media_core is silent by default; diagnostics are turned on for debug
    // builds only, so a release build prints nothing unless it opts in.
    if (kDebugMode) {
      MediaCoreLog.level = LogLevel.debug;
    }

    BootTrace.note('initialize done: ok=${BootTrace.okSteps} failed=${BootTrace.failedSteps}');
  }

  bool get isInitialized => _isInitialized;
}
