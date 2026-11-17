/// 把 IPTV 频道名对应到 XMLTV 里的频道，并给出「正在播」与「下一档」。
///
/// XMLTV 的频道 id 是 tvg-id（如 `cctv2`、`sansha`），而 IPTV 频道表里是中文名
/// （`CCTV2 高清`、`三沙卫视`）。两边对不上，所以这里做一次归一化匹配：
/// 去掉空格/标点与「高清/HD/4K/频道/台」这类后缀，再按「完全相等 → 前缀」顺序找。
///
/// EpgGuide 是整包数据（几万条节目），所以索引只在构造时建一次；
/// 之后每次查询都是拍平的 Map 查找，播放页切台时不会有解析开销。
library;

import 'epg_model.dart';

/// 频道名归一化：消除全角、空格、常见标点与清晰度后缀。
///
/// 两边用同一个函数处理，只要「写法的差异」都是这些装饰，就能对上；
/// 差异在语义层（例如「CCTV-2」与「中央二套」）时无法匹配，此时调用方
/// 回退到不显示节目信息，不做模糊猜测。
String normalizeChannelName(String raw) {
  if (raw.isEmpty) return '';
  final buffer = StringBuffer();
  for (final rune in raw.toLowerCase().runes) {
    var code = rune;
    // 全角 ASCII（！到 ～）转半角：XMLTV 里常见全角括号和字母
    if (code >= 0xFF01 && code <= 0xFF5E) code -= 0xFEE0;
    if (code == 0x3000) continue; // 全角空格
    final ch = String.fromCharCode(code);
    if (RegExp(r'[\s\-_·•:：|/\\、,，.。()（）\[\]【】《》<>"]').hasMatch(ch)) continue;
    buffer.write(ch);
  }
  var name = buffer.toString();
  // 常见后缀：清晰度与「频道/台」这类量词。两边的名字都去掉，才不会一边有
  // 一边没有导致对不上（「CCTV2」vs「CCTV2 高清」）。
  name = name.replaceAll(RegExp(r'(高清|标清|超清|蓝光|原画|杜比|4k|8k|uhd|fhd|hd|sd)$'), '');
  name = name.replaceAll(RegExp(r'(频道|台)$'), '');
  return name;
}

class EpgLookup {
  EpgLookup(this.guide) {
    for (final channel in guide.channels) {
      final key = normalizeChannelName(channel.displayName);
      if (key.isEmpty) continue;
      _byName.putIfAbsent(key, () => channel.id);
    }
    for (final programme in guide.programmes) {
      (_byChannel[programme.channelId] ??= <EpgProgramme>[]).add(programme);
    }
    // 每个频道按开始时间排序：current/next 都按顺序扫，几十条而已，
    // 比每次重新排序或二分查找都简单可靠。
    for (final list in _byChannel.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }
  }

  final EpgGuide guide;
  final Map<String, String> _byName = <String, String>{};
  final Map<String, List<EpgProgramme>> _byChannel = <String, List<EpgProgramme>>{};

  /// 频道名 → 匹配结果缓存：切台时同一个频道会被反复查（banner + 列表每行）。
  final Map<String, String?> _matchCache = <String, String?>{};

  /// 找不到返回 null。
  String? channelIdOf(String channelName) {
    if (channelName.isEmpty) return null;
    if (_matchCache.containsKey(channelName)) return _matchCache[channelName];

    final key = normalizeChannelName(channelName);
    String? id = _byName[key];
    if (id == null && key.length >= 2) {
      // 前缀匹配兜底：「三沙卫视」对「三沙卫视高清」这类被截断/加长的写法。
      // 要求长度差不超过 4 个字符，避免「cctv1」误配到「cctv11」。
      for (final entry in _byName.entries) {
        if (entry.key.startsWith(key) || key.startsWith(entry.key)) {
          if ((entry.key.length - key.length).abs() <= 4) {
            id = entry.value;
            break;
          }
        }
      }
    }
    _matchCache[channelName] = id;
    return id;
  }

  /// 当前正在播的节目；该频道没有节目表时返回 null。
  EpgProgramme? currentAt(String channelName, DateTime at) {
    final list = _programmesFor(channelName);
    if (list == null) return null;
    for (final programme in list) {
      if (programme.covers(at)) return programme;
    }
    return null;
  }

  /// 下一档节目（当前节目之后开始的那一条）。
  EpgProgramme? nextAfter(String channelName, DateTime at) {
    final list = _programmesFor(channelName);
    if (list == null) return null;
    for (final programme in list) {
      if (programme.covers(at)) continue;
      if (programme.start.isAfter(at)) return programme;
      if (programme.end.isAfter(at)) return programme;
    }
    return null;
  }

  List<EpgProgramme>? _programmesFor(String channelName) {
    final id = channelIdOf(channelName);
    if (id == null) return null;
    return _byChannel[id];
  }
}

/// `19:00 - 19:35`：节目单里到处都要这一段，格式化收在一处。
String formatEpgRange(DateTime start, DateTime end) {
  String hhmm(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  return '${hhmm(start)} - ${hhmm(end)}';
}
