# 终端库 · 云端配置下发改造说明（P0）

本文件描述 `pure_live_tv_client` 相对于上游 `6a118663` 的全部改动。
需求基线：`G:/workbuddy/puretv/纯粹直播TV_云端配置下发_需求文档_v1.0.md`。

> **提交约定**：本库只做了 `git init`，无 commit、无 remote、无 push。
> 等待用户审核同意后才会提交到 GitHub。

## 一、改造文件清单

### 新增（6 个 Dart 文件）

| 文件 | 作用 |
|---|---|
| `lib/services/remote_config/remote_config_model.dart` | 配置文档解析、类型安全读取、`rcLocalized` 多语言回退。手写 JSON，不依赖 build_runner |
| `lib/services/remote_config/remote_config_store.dart` | Hive 键集中定义、文档缓存、revision/时间戳、本地快照备份、协议/公告/更新检查状态 |
| `lib/services/remote_config/remote_config_service.dart` | 冷启动 bootstrap、拉取（`since` / 304 / 1.5s 超时）、按节 apply、降级、静态策略读取 |
| `lib/services/remote_config/remote_config.dart` | barrel export，业务侧只需 import 这一个文件 |
| `lib/features/home/remote_notice_dialog.dart` | 云端公告弹窗（默认可关闭，绝不阻断主界面） |
| （云端库 `config/site_catalog.json`） | 35 个站点 id 与中文名，由上游 `assets/translations/zh.json` 提取 |

### 修改（9 个既有文件）

| 文件 | 改动 |
|---|---|
| `lib/app/bootstrap/initialized.dart` | 在 `:63` 迁移之后插入 `await RemoteConfigService.bootstrap()`；新增 import |
| `lib/services/favorites/favorite_room_controller.dart` | 新增 `applyRemoteSiteWhitelist()` / `restoreLocalSiteCatalog()` |
| `lib/services/app_settings/app_settings_controller.dart` | 新增 `applyRemoteNavigation()` / `applyRemoteStartupAndUpdate()` / `restoreLocalSettings()` |
| `lib/features/home/home_provider.dart` | `sideMenuList` 在云端托管时使用显式白名单，绕过 `normalizeMenuIds` 补回 |
| `lib/app/router/app/app_router.dart` | redirect 引入 `agreementRequired`，按 `requiredVersion` 重新征求同意 |
| `lib/features/agreement/agreement_page.dart` | 云端标题/补充正文、同意时写 `agreementAcceptedVersion` |
| `lib/features/home/home_page.dart` | 首帧后触发 `RemoteNoticeDialog.maybeShow` |
| `lib/features/home/home_update_dialog.dart` | `update.prompt=silent` 时不弹窗 |
| `lib/core/utils/version_util.dart` | `_versionUrls` 优先用云端镜像；`_runCheckUpdate` 接入 autoCheck 与检查间隔 |

## 二、注入时序（决定成败）

```
main()
  └ AppInitializer.initialize()
      ├ Hive.init / HivePrefUtil.init / ProviderContainer / SettingsService.init
      ├ LegacySettingsMigration.migrateIfNeeded()          :63
      ├ ★ await RemoteConfigService.bootstrap()            ← 新增，唯一注入窗口
      │    ├ 读本地缓存文档 → 立即按节 apply
      │    ├ GET /api/config?since=<rev>（1.5s 超时）
      │    ├ 200 → 校验 → apply（state + Hive）→ 落盘缓存
      │    └ 304 / 超时 / 解析失败 → 静默沿用缓存或 seed
      └ 其余 unawaited（Log / 播放器 / 3s 更新检查…）
runApp(...)                                                main.dart:11
```

- 必须在迁移**之后**：否则 `_migrateSiteCatalog()` 会全量补回 `Sites.supportSites`。
- 必须在 `runApp()` **之前**：协议 redirect 与侧栏列表在首帧就决定，照搬现有「启动 3 秒后检查更新」的时机会漏掉首帧。
- `applyRemoteSiteWhitelist()` 同时把 `siteCatalogMigration` 推到 `_siteCatalogVersion`（当前 24），防止下次 `build()` 补回。
- 所有 apply 都走 controller 的 `update()` / `_update()`，**同时写内存 state 与 Hive**，避免 `_persist()` 用旧 state 回写覆盖云端配置。

## 三、默认零影响设计

- 未配置云端地址时（`remoteConfigEndpoint` Hive 键与编译期 `PURE_LIVE_CONFIG_URL` 都为空），服务不发起任何请求，也不改动任何本地设置。
- 每节只有 `managed:true` 才生效；`managed:false` 时完全忽略该节。
- 首次被接管时保存一份本地设置快照（`remoteConfigLocalSnapshot`）；当**所有节**都回到 `managed:false` 时自动恢复接管前的本地值，避免用户被云端配置锁死。
- 空站点/空导航白名单一律忽略（不写 Hive）；未知 id、退役 id 由 controller 过滤。
- 云端不可用时降级顺序：本地缓存文档 → 内置 seed（全 `managed:false`）→ 上游原有行为。

## 四、接入方式

地址与令牌支持两种来源，Hive 值优先：

```bash
# 方式一：编译期注入（推荐，适合批量打包）
flutter build apk --release --flavor impeller --split-per-abi \
  --dart-define=PURE_LIVE_CONFIG_URL=https://<fc-domain> \
  --dart-define=PURE_LIVE_CONFIG_TOKEN=<read-token>
```

```dart
// 方式二：运行时写入（适合已有设备 / 通过 Web 遥控端下发）
HivePrefUtil.setString(RemoteConfigKeys.endpoint, 'https://<fc-domain>');
HivePrefUtil.setString(RemoteConfigKeys.token, '<read-token>');
```

TV 端只需要**只读 Token**；写 Token 只给云端编辑器，不要打进 APK。

## 五、四类配置的生效链路

| 需求 | 链路 |
|---|---|
| 关闭斗鱼 | `sites.enabledSiteIds` → `FavoriteRoomController.applyRemoteSiteWhitelist` → `hotAreasList` → `Sites.availableSites()` → 平台页签。收藏/历史走 `containsAll`，不受影响 |
| 导航栏 | `navigation.railMenuIds` → `AppSettingsController.applyRemoteNavigation` → `savedMenuIds` → `sideMenuListProvider`（托管时跳过归一化）→ 左侧 rail |
| 开机弹窗 | `startup.agreement.requiredVersion` → `RemoteConfigService.agreementRequired` → `app_router.dart` redirect → 协议页；`startup.notice` → `RemoteNoticeDialog` |
| 更新 | `update.autoCheck` 写入 `AppSettingsModel.enableAutoCheckUpdate`；间隔与 `prompt` 由 `VersionUtil` / `HomeUpdateDialog` 读取；`mirrorUrls` 覆盖 `_versionUrls` |

## 六、P0 已实现 / 待补（诚实边界）

**已实现（P0）**：云端配置服务与编辑器、冷启动注入与 304 降级、站点白名单、导航白名单与顺序、协议 `requiredVersion`、公告（once_per_revision / always / never、默认可关闭）、更新自动检查 / 间隔 / silent / 镜像列表、本地快照恢复、空列表与未知 id 兜底。

**尚未实现，保留在 P1**：

1. `update.prompt=force` 的不可关闭弹窗（当前 force 与 dialog 行为相同）。
2. `update.minSupportedVersion`、`allowPrerelease`、`changelogI18n`、`allowUserOverride` 的业务接线（getter 已提供，设置页开关尚未置灰）。
3. `navigation.homeKeepAlive` 与 `navigation.settings`（设置菜单目录云端化）——`AppSettingsModel` 无 `homeKeepAlive` 字段，需接 `refresh_config`。
4. HMAC 响应签名、APK SHA-256 校验（云端库同样留到 P1）。
5. `auto_sync_scheduler` 的打开时二次同步接线、热门源 URL 配置化。
6. `IndexedStack` 的 `stackIndex` / `sideMenuIndex` 在运行中白名单收缩后的显式校正（冷启动路径无此问题）。
7. 公告与更新弹窗同帧叠加时的互斥（P0 两者可能同时出现）。
8. 设置页在 `managed:true` 时把本地开关置灰。

## 七、验证状态与已知限制

- **本机无法编译验证**：`dart` / `flutter` 命令不可用，且 `pubspec.yaml` 有 10 处
  `path: F:/media_core/packages/...` 绝对路径依赖，本机无 F: 盘，`flutter pub get` 必然失败。
  落地前需先取得 media_core 仓库并改为相对路径，再执行 `flutter analyze` 与 41 个既有测试。
- 已做静态核对：与上游基线逐文件 diff（9 改 / 6 增）、14 个 Dart 文件括号平衡、
  所有 `package:pure_live/*` import 路径可解析、5 个新增 controller 方法定义与调用一致，
  结果全部通过。
- 云端库对应测试：`python -m unittest discover -s tests -v` → **23 个测试全部通过**
  （200/304/409/401/gzip/回滚/未知 id 过滤/空列表兜底/静态编辑器）。
- 构建命令（依赖修好后）：
  `flutter pub get && flutter build apk --release --flavor impeller --split-per-abi --target-platform android-arm,android-arm64,android-x64`

## 八、建议的联调顺序

1. 云端库本地起服务（`sh scripts/run_local.sh`），编辑器把 `sites.managed` 打开并取消「斗鱼」。
2. 终端用 `--dart-define` 打包，冷启动验证无斗鱼页签且首帧不闪现（AC-01/02）。
3. 依次验证导航白名单、协议 `requiredVersion` 重签、公告 once_per_revision、silent 更新。
4. 断网冷启动与首次无网冷启动（AC-12/13），确认不崩、不弹错误。
5. 把四节全部改回 `managed:false`，确认本地用户设置被快照恢复。
