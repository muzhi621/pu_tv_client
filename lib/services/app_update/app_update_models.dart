// Models for the app-update domain: phases, records, release asset info.
// Split from app_update_service.dart — the controller file keeps the
// riverpod state machinery; these are the plain data types.

import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as path;
import 'package:pure_live/core/models/release_model/release_model.dart';
import 'package:pure_live/core/utils/version_util.dart';
import 'package:pure_live/services/remote_config/remote_config_service.dart';

enum AppUpdatePhase { idle, checking, upToDate, available, downloading, readyToInstall, failed }

/// What the app did to this device's copy of itself.
enum AppUpdateAction { checked, available, downloaded, installed, failed }

/// What happened when a downloaded package was handed to the installer.
///
/// The download dialog owns the install action, so the controller reports the
/// outcome instead of showing anything itself: the caller picks the message.
enum AppInstallResult { launched, permissionDenied, launchFailed, missingPackage }

/// One line of local update log; kept in Hive so it survives the restart.
const List<String> appUpdateAssetMirrors = [
    // 🟢 asset=206: resumable, best for large files
    'https://cdn.gh-proxy.org/',
    'https://edgeone.gh-proxy.org/',
    'https://hk.gh-proxy.org/',
    'https://gh.noki.eu.org/',
    'https://gh-proxy.com/',
    'https://slink.ltd/',
    'https://gh.catmak.name/',
    'https://proxy.gitwarp.top/',
    'https://github.ednovas.xyz/',
    'https://ghproxy.monkeyray.net/',
    'https://fastgit.cc/',
    'https://ghfile.geekertao.top/',

    // 🟠 asset=200: works, but no resume
    'https://gh-proxy.org/',
    'https://ghproxy.net/',
    'https://wget.la/',
    'https://git.yylx.win/',
    'https://g.blfrp.cn/',
  ];

/// 当前该用哪一组下载镜像前缀。
///
/// 云端清单下发的优先：反代经常挂，放在云端就能一次换掉全部终端的镜像，不用发版；
/// 云端清单没拿到（离线 / 云端不可达）时才用 APK 内置列表。
List<String> effectiveAssetMirrors() {
  final cloud = VersionUtil.cloudDownloadPrefixes;
  if (cloud.isNotEmpty) return cloud;
  // 云端把更新源指到某个反代时，下载也走同一家：清单和包在同一个域名下，
  // 能用就是都能用，免得清单拿到了、包还在原地打转。
  final prefix = RemoteConfigService.updateMirrorPrefix;
  if (RemoteConfigService.updateSource == 'mirror' && prefix.isNotEmpty) {
    return <String>[prefix];
  }
  return appUpdateAssetMirrors;
}

/// 云端清单里的 `assets` 数组 → 可下载的 APK 资产。
///
/// 字段与 GitHub Releases API 一致（`name` / `url` / `size` / `digest`），所以云端
/// 代取之后客户端不必再请求 api.github.com。非 APK 条目直接丢弃。
List<ReleaseAssetInfo> parseAssetList(Object? raw) {
  if (raw is! List) return const <ReleaseAssetInfo>[];
  final result = <ReleaseAssetInfo>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final name = '${entry['name'] ?? ''}'.trim();
    final url = '${entry['url'] ?? ''}'.trim();
    if (name.isEmpty || !url.startsWith('http')) continue;
    if (!isApkAsset(name, url)) continue;
    result.add(ReleaseAssetInfo(
      name: name,
      url: url,
      sizeBytes: (entry['size'] as num?)?.toInt() ?? 0,
      sha256: parseAssetDigest(entry['digest']),
    ));
  }
  return result;
}


class AppUpdateRecord {
  const AppUpdateRecord({required this.version, required this.action, required this.time});

  final String version;
  final AppUpdateAction action;
  final DateTime time;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'version': version,
    'action': action.name,
    'time': time.toIso8601String(),
  };

  /// Lenient on purpose: one unreadable entry must not drop the whole log.
  static AppUpdateRecord fromJson(Map<String, dynamic> json) {
    final String name = '${json['action']}';
    AppUpdateAction action = AppUpdateAction.checked;
    for (final AppUpdateAction candidate in AppUpdateAction.values) {
      if (candidate.name == name) action = candidate;
    }
    return AppUpdateRecord(
      version: '${json['version'] ?? ''}',
      action: action,
      time: DateTime.tryParse('${json['time']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// The ABI one release asset name belongs to, null when the name carries none
/// (checksums, source zips, …).
///
/// Matched as a token instead of a prefix: the TV packages are named
/// `SUTV-arm64-v8a-impeller.apk` (older releases used `PureLive-TV-`), the older mobile ones
/// `PureLive-2.0.20-12020-android-arm64-v8a-release.apk` and `app-armeabi-v7a-release.apk`,
/// and the manifest writes a bare `arm64-v8a` — a `startsWith` test sees none of
/// the prefixed ones.
String? abiForAssetName(String name) {
  final String lower = name.trim().toLowerCase();
  for (final String abi in const <String>['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
    // Boundaries keep `armeabi-v7a` from answering for `arm64-v8a`.
    if (RegExp(
      '(^|[^a-z0-9])${RegExp.escape(abi)}'
      r'([^a-z0-9]|$)',
    ).hasMatch(lower)) {
      return abi;
    }
  }
  return null;
}

/// `impeller` / `skia` when the name carries the renderer tag, '' for the
/// pre-variant asset naming.
String rendererForAssetName(String name) {
  final String lower = name.trim().toLowerCase();
  if (lower.contains('skia')) return 'skia';
  if (lower.contains('impeller')) return 'impeller';
  return '';
}

/// Whether an entry is an installable package. The GitHub API names end in
/// `.apk`; the releases.json entries carry the extension on the url instead.
bool isApkAsset(String name, String url) {
  final String fileName = name.trim().toLowerCase();
  if (fileName.endsWith('.apk')) return true;
  return url.trim().toLowerCase().split('?').first.endsWith('.apk');
}

/// One release asset from GitHub's releases API — the source of truth for
/// downloads (version.json is only a hint).
/// 从 GitHub Releases API 的 `asset.digest`（`sha256:<hex>`）取出十六进制摘要；
/// 空串/非 sha256 前缀一律返回 ''（旧 release 没有该字段，退化为大小校验）。
String parseAssetDigest(Object? raw) {
  final value = raw.toString().trim().toLowerCase();
  if (!value.startsWith('sha256:')) return '';
  final hex = value.substring(7).trim();
  if (hex.length != 64 || !hex.codeUnits.every(_isHexCode)) return '';
  return hex;
}

bool _isHexCode(int c) =>
    (c >= 0x30 && c <= 0x39) // 0-9
    || (c >= 0x61 && c <= 0x66); // a-f（上面已 toLowerCase）

class ReleaseAssetInfo {
  const ReleaseAssetInfo({
    required this.name,
    required this.url,
    required this.sizeBytes,
    this.sha256 = '',
  });

  final String name;
  final String url;
  final int sizeBytes;

  /// GitHub Releases API 的 asset.digest（`sha256:<hex>`），用于下载后端到端
  /// 校验。旧 release / 镜像清单没有该字段时为空，退化为大小 + ZIP 魔数校验。
  final String sha256;

  /// `arm64-v8a`, `armeabi-v7a` or `x86_64` when the file name carries one,
  /// null for anything else.
  String? get abi => abiForAssetName(name);

  bool get isApk => isApkAsset(name, url);

  /// `impeller` / `skia` when the file name carries the renderer tag.
  String get renderer => rendererForAssetName(name);

  String get sizeText {
    if (sizeBytes <= 0) return '';
    if (sizeBytes < 1024 * 1024) return '${(sizeBytes / 1024).toStringAsFixed(0)} KB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The release of an API payload (`/releases`) that describes [version].
///
/// The entry whose tag is that version wins, the newest non-prerelease release
/// answers when the version is not published, and a payload of nothing but
/// prereleases still describes its first entry. The manifest is what the update
/// page shows, so a manifest behind the newest release must not pair its notes
/// with that release's files.
Map<String, dynamic>? selectReleaseEntry(Object? decoded, String version) {
  if (decoded is! List || decoded.isEmpty) return null;
  final String wanted = version.trim().replaceFirst(RegExp('^[vV]'), '');
  Map<String, dynamic>? newest;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final map = Map<String, dynamic>.from(entry);
    if (map['prerelease'] == true) continue;
    newest ??= map;
    if (wanted.isEmpty) continue;
    final tag = '${map['tag_name'] ?? map['name'] ?? ''}'.trim().replaceFirst(RegExp('^[vV]'), '');
    if (tag == wanted) return map;
  }
  if (newest != null) return newest;
  final first = decoded.first;
  return first is Map ? Map<String, dynamic>.from(first) : null;
}

/// The release history payload (JSON array or `releases` object), newest first.
List<ReleaseModel> parseReleaseHistoryPayload(Object? decoded) {
  final rawList = switch (decoded) {
    final List values => values,
    final Map values when values['releases'] is List => values['releases'] as List,
    _ => null,
  };
  if (rawList == null) throw const FormatException('Invalid release history payload');

  final releases = <ReleaseModel>[];
  for (final entry in rawList) {
    if (entry is! Map) continue;
    try {
      final json = Map<String, dynamic>.from(entry);
      // `author` is required by the model but not every manifest entry has one; the
      // release list would otherwise fail to load over a missing avatar.
      json['author'] ??= <String, dynamic>{};
      final release = ReleaseModel.fromJson(json);
      if (release.version.trim().isEmpty) continue;
      releases.add(release);
    } catch (_) {
      // One unreadable entry must not cost the whole history.
      continue;
    }
  }
  releases.sort((left, right) {
    final byDate = right.date.compareTo(left.date);
    return byDate != 0 ? byDate : compareReleaseVersions(right.version, left.version);
  });
  return releases;
}

/// Numeric comparison of dotted versions, so 3.0.10 sorts after 3.0.9 when two
/// releases share a date. Non-numeric parts fall back to text order.
int compareReleaseVersions(String left, String right) {
  List<String> parts(String value) => value.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[.+-]'));
  final a = parts(left);
  final b = parts(right);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : '0';
    final y = i < b.length ? b[i] : '0';
    final nx = int.tryParse(x);
    final ny = int.tryParse(y);
    final byPart = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y);
    if (byPart != 0) return byPart;
  }
  return 0;
}

/// Release notes stripped of markdown the TV view cannot draw. Manifests embed
/// plain text, so the table rows and the `#`/`---` markers are dropped and the header
/// text is kept.
String cleanReleaseNotes(String raw) {
  final buffer = <String>[];
  for (final line in raw.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('|')) continue;
    if (trimmed.startsWith('---')) continue;
    if (trimmed.startsWith('#')) {
      final withoutHash = trimmed.replaceFirst(RegExp(r'^#+\s*'), '');
      if (withoutHash.isNotEmpty) buffer.add(withoutHash);
      continue;
    }
    buffer.add(line);
  }
  return buffer.join('\n').trim();
}

/// Longest file name (in UTF-8 bytes) [safeDownloadFileName] may return.
///
/// The cap keeps the name inside the 255-byte limit every filesystem the TV
/// build writes to enforces, with room left for the `.part` / `.previous`
/// staging suffixes the download uses.
const int _maxDownloadBaseNameBytes = 240;
const int _maxDownloadExtensionBytes = 32;

/// Turns [url] (or [suggestedName]) into a file name that is safe on every
/// filesystem the TV build writes to.
///
/// Ported from the mobile app's updater: the release asset names carry spaces,
/// non-ASCII characters and occasionally path separators, and the `.part` /
/// `.previous` staging files add to the name, so the result has to be a valid
/// single path segment and short enough to leave room for those suffixes.
String safeDownloadFileName(String url, {String? suggestedName}) {
  var candidate = suggestedName?.trim() ?? '';

  if (candidate.isEmpty) {
    try {
      final uri = Uri.parse(url.trim());
      final segments = uri.pathSegments.where((segment) => segment.trim().isNotEmpty).toList();

      if (segments.isNotEmpty) {
        candidate = segments.last;
      }
    } catch (_) {}
  }

  try {
    candidate = Uri.decodeComponent(candidate);
  } catch (_) {}

  candidate = candidate.replaceAll('\\', '/').split('/').last.trim();

  candidate = candidate
      .replaceAll(RegExp(r'[\x00-\x1F\x7F<>:"/\\|?*\u202A-\u202E\u2066-\u2069]'), '_')
      .replaceFirst(RegExp(r'^[. ]+'), '')
      .replaceFirst(RegExp(r'[. ]+$'), '');

  candidate = String.fromCharCodes(candidate.runes);

  if (candidate.isEmpty || candidate == '.' || candidate == '..') {
    candidate = 'SUTV-update.apk';
  }

  if (RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)', caseSensitive: false).hasMatch(candidate)) {
    candidate = '_$candidate';
  }

  return _fitDownloadBaseName(candidate);
}

/// Shortens [candidate] to [_maxDownloadBaseNameBytes] without splitting a
/// multi-byte character, keeping the extension and adding a content hash so two
/// different long names cannot collide on the same shortened one.
String _fitDownloadBaseName(String candidate) {
  if (utf8.encode(candidate).length <= _maxDownloadBaseNameBytes) {
    return candidate;
  }

  final rawExtension = path.extension(candidate);
  final extension = _truncateUtf8(rawExtension, _maxDownloadExtensionBytes);

  final stem = rawExtension.isEmpty ? candidate : candidate.substring(0, candidate.length - rawExtension.length);

  final digest = crypto.sha256.convert(utf8.encode(candidate)).toString().substring(0, 12);

  final suffix = '-$digest$extension';

  final stemBudget = _maxDownloadBaseNameBytes - utf8.encode(suffix).length;

  var fittedStem = _truncateUtf8(stem, stemBudget);

  if (fittedStem.isEmpty) {
    fittedStem = _truncateUtf8('PureLive', stemBudget);
  }

  return '$fittedStem$suffix';
}

String _truncateUtf8(String value, int maxBytes) {
  if (maxBytes <= 0 || value.isEmpty) {
    return '';
  }

  final buffer = StringBuffer();
  var usedBytes = 0;

  for (final rune in value.runes) {
    final scalar = String.fromCharCode(rune);
    final scalarBytes = utf8.encode(scalar).length;

    if (usedBytes + scalarBytes > maxBytes) {
      break;
    }

    buffer.write(scalar);
    usedBytes += scalarBytes;
  }

  return buffer.toString();
}

/// The mirror prefix [url] already carries, '' when it is the plain github url.
String _mirrorPrefixOf(String url, List<String> mirrors) {
  for (final String mirror in mirrors) {
    if (url.startsWith(mirror)) return mirror;
  }
  return '';
}

/// The urls one download tries, in order.
///
/// [url] is either a plain release url or one already behind a mirror — the
/// download page builds its sources that way. The picked source goes first when
/// [preferGivenUrl] ("source 3" really means source 3), the remaining mirrors
/// follow, and the plain origin is always last. [mirrors] 为 null 时用
/// [effectiveAssetMirrors]（云端下发优先）；传空列表表示只走原始地址
/// （用户显式选择「直连 GitHub，不走镜像」）。
///
/// Every candidate is built from the github url the given one wraps: a proxy
/// prefix stacked on an already prefixed url (`proxy/proxy/github.com/…`) is a
/// request no proxy can serve, which used to leave the fallback chain dead.
List<String> downloadCandidates(String url, {bool preferGivenUrl = false, List<String>? mirrors}) {
  final List<String> pool = mirrors ?? effectiveAssetMirrors();
  final String used = _mirrorPrefixOf(url, pool);
  final String origin = used.isEmpty ? url : url.substring(used.length);
  return <String>[
    if (preferGivenUrl) url,
    for (final String mirror in pool)
      if (mirror != used) '$mirror$origin',
    origin,
  ];
}
