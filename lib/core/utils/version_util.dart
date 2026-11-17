import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:pure_live/core/platform/race_http.dart';
import 'package:pure_live/services/settings/settings.dart';
import 'package:pure_live/core/utils/githup_mirror.dart';
import 'package:pure_live/core/utils/platform_utils.dart';
import 'package:pure_live/services/remote_config/remote_config.dart';

/// Download URLs assembled from the release identity itself, following the
/// names the Android release workflow uploads:
/// `{projectUrl}/releases/download/v{version}/SUTV-{abi}-{renderer}.apk`.
///
/// The last resort of the update flow: the release's real asset list and the
/// releases.json file list are tried first, and this fills in when a release
/// was published with the standard names but no matching entry was read — the
/// state an up-to-date device is in, where nothing an update check returned
/// carries a file list.
class ReleaseAssetUrls {
  const ReleaseAssetUrls({required this.projectUrl, required this.version});

  final String projectUrl;
  final String version;

  String get normalizedVersion {
    final value = version.trim();
    return value.startsWith('v') || value.startsWith('V') ? value.substring(1) : value;
  }

  bool get isValid {
    final uri = Uri.tryParse(projectUrl.trim());
    final safeVersion =
        RegExp(r'^[0-9A-Za-z][0-9A-Za-z._-]*$').hasMatch(normalizedVersion) && !normalizedVersion.contains('..');
    return uri != null &&
        uri.scheme == 'https' &&
        uri.hasAuthority &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.userInfo.isEmpty &&
        safeVersion;
  }

  String get releaseBase {
    if (!isValid) return '';
    final normalizedProject = projectUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    return '$normalizedProject/releases/download/v$normalizedVersion';
  }

  /// The package for one ABI, e.g. `SUTV-arm64-v8a-impeller.apk`. Releases
  /// from version 3.0.33 carried the old `PureLive-TV-` prefix; those are
  /// resolved from the GitHub asset list / releases.json (which are tried
  /// before this fallback), so the assembled name only ever targets new
  /// SUTV-prefixed releases.
  String apkForAbi(String abi, {String renderer = ''}) {
    if (!isValid) return '';
    final String name = abi.trim().toLowerCase();
    if (name.isEmpty) return '';
    final String tag = renderer.trim().toLowerCase();
    return '$releaseBase/SUTV-$name${tag.isEmpty ? '' : '-$tag'}.apk';
  }
}

/// Version info and update checks.
///
/// State is exposed as plain fields and callbacks, and releases are read from
/// this app repository.
class VersionUtil {
  static PackageInfo? _packageInfo;

  /// Release repository for the TV build.
  ///
  /// 本仓库是从 liuchuancong/pure_live_TV fork 出来的独立发行分支，更新检查、
  /// Release API 与 raw 文件镜像必须指向自己的仓库，否则应用内更新会一直
  /// 读取上游的 version.json，看不到本仓库发布的 APK。
  static const String updateOwner = 'muzhi621';
  static const String updateRepository = 'pu_tv_client';
  static final String projectUrl = 'https://github.com/$updateOwner/$updateRepository';
  static final String issuesUrl = '$projectUrl/issues';
  static const String githubUrl = 'https://github.com/liuchuancong';

  static const String email = '17792321552@163.com';
  static const String emailUrl = 'mailto:17792321552@163.com?subject=PureLiveTV Feedback';

  static final String releaseUrl = 'https://api.github.com/repos/$updateOwner/$updateRepository/releases?per_page=30';

  static final GitHubMirror mirror = GitHubMirror(owner: updateOwner, repo: updateRepository, branch: 'main');

  /// 终端取「云端清单」的候选地址，由云端下发的更新源决定。
  ///
  /// - `cloud`（默认）：`manifestUrl` 或本域名 `/api/update`，由云端出网代取 GitHub；
  /// - `upload`：编辑器上传到云端的清单，读 `/api/update/manifest`；
  /// - `custom`：只认 `manifestUrl`（没填时退回云端端点，别让检查更新直接失败）；
  /// - `github` / `mirror`：不走云端清单，直接问 GitHub（见 [_versionUrls]）。
  ///
  /// 空列表 = 这次不该走云端清单，调用方退回内置 GitHub 镜像。
  static List<String> get cloudManifestUrls {
    final source = RemoteConfigService.updateSource;
    if (source == 'github' || source == 'mirror') return const <String>[];

    final custom = sanitizeRemoteUrl(RemoteConfigService.updateManifestUrl);
    if (custom.isNotEmpty) return <String>[custom];

    // 云端只是「一个清单端点」时：用户另填了完整的 version.json URL 列表，
    // 说明他明确指定了来源，保持老行为（不抢这份活）。
    if (source == 'cloud' && RemoteConfigService.updateMirrorUrls.isNotEmpty) {
      return const <String>[];
    }

    final base = _endpointBase;
    if (base.isEmpty) return const <String>[];
    if (source == 'upload') return <String>['$base/api/update/manifest'];
    return <String>['$base/api/update'];
  }

  static String get _endpointBase =>
      RemoteConfigStore.endpoint.trim().replaceAll(RegExp(r'/+$'), '');

  /// 云端下发的外部地址只接受 http(s)、无空白、有长度上限。
  ///
  /// 配置本身需要写令牌才能改，但清单地址直接决定终端向谁要版本与下载前缀，
  /// 收窄 scheme 的成本很低，没必要留 `file:` / `javascript:` 这种可能性。
  static String sanitizeRemoteUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 500) return '';
    if (!value.startsWith('https://') && !value.startsWith('http://')) return '';
    if (RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(value)) return '';
    return value;
  }

  /// 是否只走 GitHub 原始地址（云端 `source=github`，或用户显式选择直连）。
  ///
  /// 云端 `source=github` 时听云端的；否则看设置页开关（云端禁止本地覆盖时忽略用户）。
  ///
  /// 更新页取资产、下载历史也要认这个值：只让「检查更新」直连、下载仍走反代，
  /// 会出现版本号拿到了、包却下不动的情况。
  static bool get prefersDirectGitHub => _directGitHub;

  static bool get _directGitHub {
    if (RemoteConfigService.updateSource == 'github') return true;
    if (!RemoteConfigService.updateAllowUserOverride) return false;
    return SettingsService.to.appState.useGitHubOriginForUpdates;
  }

  /// 云端清单带回的最新 release 资产（GitHub API 字段原样）。
  ///
  /// 非空时更新页不再访问 api.github.com——那里既有墙也有未鉴权限额。
  /// 只在云端清单命中时填充；直连 GitHub 的 version.json 没有这些字段。
  static List<Map<String, dynamic>> cloudAssets = const <Map<String, dynamic>>[];

  /// 云端清单带回的历史版本（与 `assets/releases.json` 同形）。
  static List<Map<String, dynamic>> cloudReleases = const <Map<String, dynamic>>[];

  /// 云端指定的下载镜像前缀；空表示沿用 APK 内置列表。
  ///
  /// 反代经常挂，放在云端就能一次改全部终端，不用发版。
  static List<String> cloudDownloadPrefixes = const <String>[];

  /// 最近一次命中的清单来源（`github` / `proxy` / `static`，空=非云端清单）。
  static String cloudSource = '';

  /// 云端按 ABI 下发的安装包直链；空串 = 没配，用清单里的 release 资产。
  ///
  /// 用于「APK 放自己的 CDN/网盘」：更新源怎么配都不影响它，终端直接下这个地址。
  static String downloadUrlForAbi(String abi) {
    final key = abi.trim().toLowerCase();
    return RemoteConfigService.updateDownloadUrls[key] ?? '';
  }

  /// 这个地址是不是云端下发的 ABI 直链。
  ///
  /// 直链是用户指定的完整地址，不能套 GitHub 反代前缀——拼出来必然是坏地址。
  static bool isCustomDownloadUrl(String url) {
    final value = url.trim();
    if (value.isEmpty) return false;
    return RemoteConfigService.updateDownloadUrls.containsValue(value);
  }

  /// 套餐是否下发了目标版本（云端「在线更新」板块选定的版本）。
  ///
  /// 为 true 时终端不再查云端清单：升到哪一版、从哪下载都已经写在配置里。
  /// 这样「按套餐分配不同固件」才成立——问云端清单只会把结论推翻成"最新版"。
  static bool get hasPinnedUpdate => RemoteConfigService.updateVersion.isNotEmpty;

  static List<String> get _versionUrls {
    // mirror 模式：把云端下发的反代前缀放在最前面，后面照旧跟上内置镜像，
    // 前缀那家挂了也不会卡死（RaceHttp 会接着试）。
    final prefix = RemoteConfigService.updateMirrorPrefix;
    if (RemoteConfigService.updateSource == 'mirror' && prefix.isNotEmpty && !_directGitHub) {
      return <String>[
        '$prefix${mirror.rawUrl('assets/version.json')}',
        ...mirror.mirrors('assets/version.json'),
      ];
    }

    // 云端下发的是完整的 version.json URL 列表，优先于内置 GitHub 镜像。
    final remote = RemoteConfigService.updateMirrorUrls;
    if (remote.isNotEmpty && !_directGitHub) return remote;
    return _directGitHub
        ? <String>[mirror.rawUrl('assets/version.json')]
        : mirror.mirrors('assets/version.json');
  }

  /// Whether a newer version exists. The Riverpod layer can watch this field or
  /// subscribe to onHasNewVersionChanged.
  static bool isHasNewVersion = false;
  static void Function(bool)? onHasNewVersionChanged;

  static String latestVersion = '';
  static int? latestBuildNumber;
  static int latestVersionNum = 0;
  static String latestUpdateLog = '';
  static bool prerelease = false;
  static String downloadUrl = '';
  static Set<String> latestAndroidAbis = const {'arm64-v8a'};
  static bool latestWindowsMsixAvailable = false;

  static Map<String, dynamic>? _cachedVersionJson;

  static Future<void> initPackageInfo() async {
    _packageInfo = await PackageInfo.fromPlatform();
  }

  static String get version {
    if (_packageInfo == null) return '0.0.0';
    return _packageInfo!.version;
  }

  static int get buildNumber {
    if (_packageInfo == null) return 0;
    return int.tryParse(_packageInfo!.buildNumber) ?? 0;
  }

  static void _setHasNewVersion(bool value) {
    if (isHasNewVersion == value) return;
    isHasNewVersion = value;
    onHasNewVersionChanged?.call(value);
  }

  /// The check the app already started.
  ///
  /// A second caller joins it instead of starting another fetch, and the home
  /// dialog awaits it instead of reading a verdict that has not been reached.
  static Future<bool>? _checkInFlight;

  /// Runs the update check, joining one that is already running.
  Future<bool> checkUpdate() => _checkInFlight ??= _runCheckUpdate().whenComplete(() => _checkInFlight = null);

  /// Waits for a running check and reports its verdict.
  ///
  /// Used by the home dialog: the startup check is deliberately deferred past
  /// the first frames, so reading [isHasNewVersion] right after startup always
  /// says "no update". [timeout] only covers a check that never answers (a dead
  /// network); the dialog then stays away, as it does for "no update".
  static Future<bool> verdict({Duration timeout = const Duration(seconds: 15)}) async {
    final running = _checkInFlight;

    if (running != null) {
      await running.timeout(timeout, onTimeout: () => false);
    }

    return hasNewVersion();
  }

  /// `3.0.43` → `130043`：100000 的产品位 + major*10000 + minor*100 + patch。
  ///
  /// 与云端 flattenVersion 一致。注意 [_flattenedVersion] 是另一套（不带产品位）
  /// 的老规则，只用来给缺 `version_num` 的清单兜底 build 号，别混用。
  static int flattenVersionNum(String version) {
    final parts = version.split(RegExp(r'[-+]')).first
        .replaceFirst(RegExp('^[vV]'), '').trim().split('.');
    final major = int.tryParse(parts.isNotEmpty ? parts[0] : '');
    if (major == null) return 0;
    final minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final patch = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    return 100000 + major * 10000 + minor * 100 + patch;
  }

  /// 套餐指定了目标版本时直接用配置判定，不联网。
  ///
  /// 下载地址仍由 [downloadUrlForAbi] 给（云端 downloads 已经展开成完整直链），
  /// 所以这里只负责「有没有新版」这一个结论。
  ///
  /// 返回 false 表示配置里没有目标版本，调用方继续走原来的清单流程。
  static bool _applyPinnedVersion() {
    final version = RemoteConfigService.updateVersion;
    if (version.isEmpty) return false;
    try {
      final pinnedNum = RemoteConfigService.updateVersionNum;
      _applyVersionData(<String, dynamic>{
        'version': version,
        // 云端没带 versionNum 时按同一套规则推导，别让 3.0.43 被判成比 3.0.42 旧。
        'version_num': pinnedNum > 0 ? pinnedNum : flattenVersionNum(version),
        'version_desc': RemoteConfigService.updateVersionDesc,
        // 两个架构都声明为「已发布」：具体下哪个由设备 ABI + downloads 决定。
        'android_abis': const <String>['arm64-v8a', 'armeabi-v7a'],
      });
      _setHasNewVersion(hasNewVersion());
      debugPrint('🏁 Update pinned by cloud config: $version');
      return true;
    } catch (error) {
      // 版本号格式不合法（例如云端手填写成 latest）：退回清单流程，别让检查更新直接失败。
      debugPrint('⚠️ Pinned update version unusable: $error');
      return false;
    }
  }

  Future<bool> _runCheckUpdate() async {
    // 套餐指定的版本优先，且不受「检查间隔」限制：云端改完套餐就说明该升了，
    // 被「今天已经查过」挡住会让新分配的固件等上一整天。
    if (_applyPinnedVersion()) {
      await RemoteConfigService.markUpdateChecked();
      return true;
    }

    if (!RemoteConfigService.updateAutoCheck || !RemoteConfigService.shouldCheckUpdateNow()) {
      _resetAfterFailedCheck();
      return false;
    }
    await RemoteConfigService.markUpdateChecked();

    if (_cachedVersionJson != null) {
      try {
        _applyVersionData(_cachedVersionJson!);
        _setHasNewVersion(hasNewVersion());
        return true;
      } catch (_) {
        _cachedVersionJson = null;
        _resetAfterFailedCheck();
        return false;
      }
    }

    // 云端清单优先且单独走一次：它带回了版本号、release 资产、历史与下载镜像，
    // 一次请求就够，不必再让终端去连 api.github.com。
    // 例外都在 cloudManifestUrls 里判掉了：直连 GitHub、mirror 模式、自己指定了
    // version.json 列表——这几种情况不抢它们的活。
    final cloud = _directGitHub || cloudManifestUrls.isEmpty
        ? null
        : await _fetchCloudManifest();
    if (cloud != null) {
      try {
        _applyVersionData(cloud);
        _cachedVersionJson = cloud;
        _setHasNewVersion(hasNewVersion());
        debugPrint('🏁 Update manifest from cloud (${cloudSource.isEmpty ? 'cloud' : cloudSource})');
        return true;
      } catch (e) {
        debugPrint('⚠️ Cloud manifest unusable, falling back to GitHub: $e');
      }
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final urls = _versionUrls.map((e) => '$e?ts=$timestamp').toList();

      final data = await RaceHttp.fetchJson(
        urls,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 10));

      if (data == null) {
        _resetAfterFailedCheck();
        return false;
      }

      _applyVersionData(data);
      _cachedVersionJson = data;
      _setHasNewVersion(hasNewVersion());
      debugPrint('🏁 Update mirror resolved');
      return true;
    } catch (e) {
      debugPrint('⚠️ Update check failed: $e');
      _resetAfterFailedCheck();
      return false;
    }
  }

  /// 拉云端更新清单；没配端点、超时或解析失败时返回 null 交给 GitHub 兜底。
  ///
  /// 不加 `?ts=` 时间戳：这个端点由 CDN 缓存，加上时间戳等于每次都穿透到函数，
  /// 白白浪费一次 GitHub 访问。清单只在发版时变，缓存几分钟没有副作用。
  static Future<Map<String, dynamic>?> _fetchCloudManifest() async {
    final urls = cloudManifestUrls;
    if (urls.isEmpty) return null;
    try {
      final data = await RaceHttp.fetchJson(
        urls,
        headers: {'Accept': 'application/json'},
      ).timeout(const Duration(seconds: 8));
      if (data == null) return null;
      // 云端没给出可用版本号 = 这份清单没用，别让后面的解析把「检查更新」判成成功。
      final version = data['version']?.toString().trim() ?? '';
      if (version.isEmpty) return null;
      return data;
    } catch (error) {
      debugPrint('⚠️ Cloud manifest unavailable, falling back to GitHub: $error');
      return null;
    }
  }

  /// 记录云端清单附带的三份附加信息（资产 / 历史 / 下载镜像）。
  ///
  /// 每次都按 data 整体赋值（缺字段即清空）：来源可能是云端、也可能退化成
  /// GitHub 直连的 version.json，后者没有这些字段，留着上一轮的值会把旧资产
  /// 当成新版本的。
  static void _applyCloudExtras(Map<String, dynamic> data) {
    cloudSource = data['source']?.toString().trim() ?? '';
    cloudAssets = _mapEntries(data['assets']);
    cloudReleases = _mapEntries(data['releases']);
    final prefixes = data['downloadPrefixes'];
    cloudDownloadPrefixes = prefixes is List
        ? prefixes
            .map((item) => item.toString().trim())
            .where((item) => item.startsWith('https://'))
            .toList(growable: false)
        : const <String>[];
  }

  static List<Map<String, dynamic>> _mapEntries(Object? raw) {
    if (raw is! List) return const <Map<String, dynamic>>[];
    final result = <Map<String, dynamic>>[];
    for (final entry in raw) {
      if (entry is Map) result.add(Map<String, dynamic>.from(entry));
    }
    return result;
  }

  static void _applyVersionData(Map<String, dynamic> data) {
    _applyCloudExtras(data);
    final selected = selectPlatformVersionData(data, platform: _currentPlatformKey);
    final parsedVersion = selected['version']?.toString().trim() ?? '';
    if (parsedVersion.isEmpty) {
      throw const FormatException('Incomplete release identity');
    }
    // `build_number` is optional in the release manifest: the file published on
    // master carries `version_num` (and sometimes only the version string), and
    // insisting on the field made every check fail with "Incomplete release
    // identity" — so an up-to-date device reported a failed update check.
    final parsedBuildNumber =
        _versionInt(selected['build_number']) ??
        _versionInt(selected['version_num']) ??
        _versionInt(_flattenedVersion(parsedVersion)) ??
        0;
    latestVersion = parsedVersion;
    latestVersionNum = _versionInt(selected['version_num']) ?? 0;
    latestBuildNumber = parsedBuildNumber;
    latestUpdateLog = selected['version_desc']?.toString() ?? '';
    prerelease = selected['prerelease'] == true;
    downloadUrl = selected['download_url']?.toString() ?? '';
    latestAndroidAbis = selectAndroidAbis(selected);
    latestWindowsMsixAvailable = selected['windows_msix_available'] == true;
  }

  /// `2.0.20` → `12020`, the flattened scheme the manifest uses for
  /// `version_num`, so a manifest without a build number still yields one.
  static String? _flattenedVersion(String version) {
    final clean = version.split(RegExp(r'[-+]'))[0].replaceFirst(RegExp('^[vV]'), '').trim();
    final parts = clean.split('.');
    if (parts.isEmpty || int.tryParse(parts[0]) == null) return null;
    final int major = int.parse(parts[0]);
    final int minor = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final int patch = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    return '${major * 10000 + minor * 100 + patch}';
  }

  /// Only advertises APK variants the release source declares as published;
  /// older sources default to arm64.
  static Set<String> selectAndroidAbis(Map<String, dynamic> data) {
    final raw = data['android_abis'];
    if (raw is! List) return const {'arm64-v8a'};
    return raw.map((item) => item.toString()).where(_supportAndroidAbis.contains).toSet();
  }

  static const Set<String> _supportAndroidAbis = {'arm64-v8a', 'armeabi-v7a', 'x86_64'};

  /// Merges release info per platform field, still accepting the top-level fields
  /// used by older release sources.
  static Map<String, dynamic> selectPlatformVersionData(Map<String, dynamic> data, {required String platform}) {
    final platforms = data['platforms'];
    final platformData = platforms is Map ? platforms[platform] : null;
    if (platformData is! Map) return data;
    return {...data, ...Map<String, dynamic>.from(platformData)};
  }

  static String get _currentPlatformKey {
    if (PlatformUtils.isWindows) return 'windows';
    if (PlatformUtils.isAndroid) return 'android';
    if (PlatformUtils.isMacOS) return 'macos';
    if (PlatformUtils.isIOS) return 'ios';
    if (PlatformUtils.isLinux) return 'linux';
    return 'default';
  }

  static bool hasNewVersion() {
    return isNewerVersion(latestVersion, version);
  }

  static bool isNewerVersion(String latest, String current) {
    try {
      final latestClean = latest.split(RegExp(r'[-+]'))[0].replaceFirst(RegExp('^[vV]'), '').trim();
      final currentClean = current.split(RegExp(r'[-+]'))[0].replaceFirst(RegExp('^[vV]'), '').trim();

      final latestParts = latestClean.split('.').map(int.parse).toList();
      final currentParts = currentClean.split('.').map(int.parse).toList();

      final maxLength = latestParts.length > currentParts.length ? latestParts.length : currentParts.length;

      while (latestParts.length < maxLength) {
        latestParts.add(0);
      }
      while (currentParts.length < maxLength) {
        currentParts.add(0);
      }

      for (int i = 0; i < maxLength; i++) {
        if (latestParts[i] > currentParts[i]) return true;
        if (latestParts[i] < currentParts[i]) return false;
      }
    } catch (_) {}
    return false;
  }

  static int? _versionInt(Object? value) {
    return switch (value) {
      int number => number,
      num number => number.toInt(),
      String text => int.tryParse(text.trim()),
      _ => null,
    };
  }

  void _resetAfterFailedCheck() {
    latestVersion = version;
    latestBuildNumber = buildNumber > 0 ? buildNumber : null;
    latestVersionNum = 0;
    latestUpdateLog = '';
    prerelease = false;
    downloadUrl = '';
    latestAndroidAbis = const {};
    latestWindowsMsixAvailable = false;
    // 清单没拿到就别留着上一份资产/历史：那属于另一个版本，混着用会给出
    // 对不上号的下载地址与校验和。
    cloudAssets = const <Map<String, dynamic>>[];
    cloudReleases = const <Map<String, dynamic>>[];
    cloudDownloadPrefixes = const <String>[];
    cloudSource = '';
    _setHasNewVersion(false);
  }
}
