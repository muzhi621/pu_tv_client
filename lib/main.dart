import 'package:pure_live/app/app.dart';
import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/bootstrap/initialized.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'package:pure_live/app/consts/app_theme_consts.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

void main() async {
  final initializer = AppInitializer();
  await initializer.initialize();

  runApp(
    EasyLocalization(
      supportedLocales: AppThemeConsts.languages.values.toList(growable: false),
      path: 'assets/translations',
      fallbackLocale: const Locale('zh'),
      // The language preference lives in Hive and is only readable once storage
      // is ready, so the saved language is applied up front to avoid a switch.
      startLocale: Locale(SettingsService.to.theme.locale.languageCode),
      useOnlyLangCode: true,
      child: UncontrolledProviderScope(container: initializer.container, child: App()),
    ),
  );

  // 心跳与生命周期监听挂在 App 首帧之后：此时 WidgetsBinding 与第一帧菜单均已
  // 就绪。bootstrap 仍在 initialize() 中、即 runApp 之前完成，既有顺序不受影响。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    RemoteConfigService.startHeartbeat();
  });
}
