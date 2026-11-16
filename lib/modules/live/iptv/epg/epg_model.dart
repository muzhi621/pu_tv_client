/// EPG 数据模型（纯 Dart，不依赖 drift）。
///
/// 数据源是云端下发的 `sections.iptv.epgUrl`（XMLTV 格式），解析后存 Hive 缓存。
/// 之所以不进 drift：EPG 数据整包刷新、只读、无关系查询需求，用 Hive 单键存
/// JSON 足够，也避免改动 database.g.dart（本机无 build_runner 环境）。
library;

/// 一条节目：频道的某个时间段播出的内容。
class EpgProgramme {
  const EpgProgramme({
    required this.channelId,
    required this.title,
    required this.start,
    required this.end,
    this.subTitle = '',
    this.description = '',
    this.category = '',
  });

  /// XMLTV 的频道 id（<programme channel="...">）。
  final String channelId;
  final String title;
  final DateTime start;
  final DateTime end;
  final String subTitle;
  final String description;
  final String category;

  bool covers(DateTime at) => !at.isBefore(start) && at.isBefore(end);

  Duration get duration => end.difference(start);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'channelId': channelId,
        'title': title,
        'start': start.toIso8601String(),
        'end': end.toIso8601String(),
        'subTitle': subTitle,
        'description': description,
        'category': category,
      };

  factory EpgProgramme.fromJson(Map<String, dynamic> json) => EpgProgramme(
        channelId: (json['channelId'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        start: DateTime.tryParse((json['start'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0),
        end: DateTime.tryParse((json['end'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0),
        subTitle: (json['subTitle'] ?? '').toString(),
        description: (json['description'] ?? '').toString(),
        category: (json['category'] ?? '').toString(),
      );
}

/// 一个 EPG 频道（XMLTV <channel>）。
class EpgChannel {
  const EpgChannel({
    required this.id,
    required this.displayName,
    this.icon,
  });

  final String id;
  final String displayName;
  final String? icon;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'displayName': displayName,
        'icon': icon,
      };

  factory EpgChannel.fromJson(Map<String, dynamic> json) => EpgChannel(
        id: (json['id'] ?? '').toString(),
        displayName: (json['displayName'] ?? '').toString(),
        icon: json['icon'] == null ? null : json['icon'].toString(),
      );
}

/// 一次完整解析结果（频道 + 节目）。缓存整体序列化为一个 Hive 键。
class EpgGuide {
  const EpgGuide({
    this.channels = const <EpgChannel>[],
    this.programmes = const <EpgProgramme>[],
    required this.fetchedAt,
  });

  final List<EpgChannel> channels;
  final List<EpgProgramme> programmes;
  final DateTime fetchedAt;

  bool get isEmpty => channels.isEmpty && programmes.isEmpty;

  /// 某频道在某一天的节目，按开始时间升序。
  List<EpgProgramme> programmesOf(String channelId, DateTime day) {
    final nextDay = DateTime(day.year, day.month, day.day + 1);
    final list = programmes.where((p) {
      if (p.channelId != channelId) return false;
      // 节目跨零点时用「开始时间落在该日」归属，避免重复出现。
      return !p.start.isBefore(day) && p.start.isBefore(nextDay);
    }).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fetchedAt': fetchedAt.toIso8601String(),
        'channels': channels.map((c) => c.toJson()).toList(),
        'programmes': programmes.map((p) => p.toJson()).toList(),
      };

  factory EpgGuide.fromJson(Map<String, dynamic> json) {
    final channels = <EpgChannel>[];
    for (final item in (json['channels'] as List? ?? const <dynamic>[])) {
      if (item is Map) channels.add(EpgChannel.fromJson(Map<String, dynamic>.from(item)));
    }
    final programmes = <EpgProgramme>[];
    for (final item in (json['programmes'] as List? ?? const <dynamic>[])) {
      if (item is Map) programmes.add(EpgProgramme.fromJson(Map<String, dynamic>.from(item)));
    }
    return EpgGuide(
      channels: channels,
      programmes: programmes,
      fetchedAt: DateTime.tryParse((json['fetchedAt'] ?? '').toString())
          ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
