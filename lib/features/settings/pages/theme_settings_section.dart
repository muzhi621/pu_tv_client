import 'package:pure_live/exports/package_export.dart';
import 'package:pure_live/app/consts/app_theme_consts.dart';
import 'package:pure_live/services/theme_settings/theme_settings_controller.dart';

/// 语言设置页（路由仍是 `kSettingsTheme`，标题已改为「区域与语言」）。
///
/// 2026-11-17 设置精简：这一页原本是「主题定制」，含界面主题、加载动画、
/// 背景、网格间距、页面设置、字体、全局字号共 7 组。按用户要求全部下掉：
///
/// - 导航栏结构 / 二级显隐 → 云端 `navigation.groups` / `railMenuIds`
/// - 首页壁纸             → 云端 `navigation.wallpaper`（客户端只负责落地）
/// - 加载动画             → 固定用默认值（`AppConsts.allStyles` 首个）
/// - 配色 / 字体 / 字号 / 间距 / 页面设置 → 统一用默认值
///
/// 只保留语言：它是纯离线能力，云端配置管不到 UI 语言，用户换机后仍要能改。
///
/// 路由与生成产物保持不动（`app_router.g.dart` 是已提交的生成文件，本机无法
/// 重跑 build_runner）。被下掉的子页因此变成不可达的死代码，Dart AOT 会摇掉
/// 未被引用的部分，不影响包体。
class ThemeSettingsSectionPage extends ConsumerWidget {
  const ThemeSettingsSectionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeSettingsControllerProvider);
    final theme = ref.read(themeSettingsControllerProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvSettingsGroupTitle(title: i18n('localization_settings')),
          TvSettingsCard(
            children: [
              TvSettingsOptionTile(
                title: i18n('change_language'),
                subtitle: i18n('change_language_subtitle'),
                icon: Remix.global_line,
                options: AppThemeConsts.languages.keys.toList(growable: false),
                index: _languageIndex(themeState.languageName),
                onChanged: (i) async {
                  final languageName = AppThemeConsts.languages.keys.elementAt(i);
                  await theme.changeLanguageWithRetry(context, languageName: languageName);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Index of the persisted language inside [AppThemeConsts.languages].
  static int _languageIndex(String languageName) {
    final index = AppThemeConsts.languages.keys.toList(growable: false).indexOf(languageName);
    return index < 0 ? 1 : index;
  }
}
