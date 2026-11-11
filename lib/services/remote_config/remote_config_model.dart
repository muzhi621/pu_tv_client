import 'dart:convert';

/// 云端配置文档（需求文档 4.2）。
///
/// 刻意手写解析而非使用 freezed/json_serializable：本模块不参与代码生成，
/// 便于在只拿到源码、无法运行 build_runner 的环境中直接编译。
class RemoteConfigDocument {
  const RemoteConfigDocument({
    required this.schemaVersion,
    required this.revision,
    required this.updatedAt,
    required this.sections,
  });

  static const int supportedSchemaVersion = 1;

  final int schemaVersion;
  final int revision;
  final String updatedAt;
  final Map<String, dynamic> sections;

  factory RemoteConfigDocument.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version != supportedSchemaVersion) {
      throw FormatException('不支持的 schemaVersion: $version');
    }
    final sections = json['sections'];
    if (sections is! Map) {
      throw const FormatException('配置缺少 sections 对象');
    }
    final revision = json['revision'];
    return RemoteConfigDocument(
      schemaVersion: supportedSchemaVersion,
      revision: revision is int && revision >= 0 ? revision : 0,
      updatedAt: json['updatedAt'] is String ? json['updatedAt'] as String : '',
      sections: Map<String, dynamic>.from(sections),
    );
  }

  static RemoteConfigDocument? tryDecode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RemoteConfigDocument.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  String encode() => jsonEncode(toJson());

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'revision': revision,
        'updatedAt': updatedAt,
        'sections': sections,
      };

  Map<String, dynamic> section(String name) {
    final value = sections[name];
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }

  /// 未接管（含字段缺失、类型错误）一律返回 false，保证默认零影响。
  bool managed(String name) => section(name)['managed'] == true;

  Map<String, dynamic> subsection(String sectionName, String name) {
    final value = section(sectionName)[name];
    return value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  }
}

bool rcBool(dynamic value, bool fallback) => value is bool ? value : fallback;

int rcInt(dynamic value, int fallback) => value is int ? value : fallback;

String rcString(dynamic value, String fallback) => value is String ? value : fallback;

List<String> rcStringList(dynamic value) {
  if (value is! List) return <String>[];
  return value.whereType<String>().map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
}

String rcLocalized(dynamic value, String locale, [String fallback = '']) {
  if (value is! Map) return fallback;
  final direct = value[locale];
  if (direct is String && direct.isNotEmpty) return direct;
  final chinese = value['zh'];
  if (chinese is String && chinese.isNotEmpty) return chinese;
  for (final entry in value.values) {
    if (entry is String && entry.isNotEmpty) return entry;
  }
  return fallback;
}
