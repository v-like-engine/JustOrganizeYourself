import 'dart:convert';

const _unchanged = Object();

bool _validUtc(String value) {
  final match = RegExp(
          r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$')
      .firstMatch(value);
  final date = DateTime.tryParse(value);
  if (match == null || date == null || !date.isUtc) return false;
  final actual = [
    date.year,
    date.month,
    date.day,
    date.hour,
    date.minute,
    date.second
  ];
  for (var i = 0; i < actual.length; i++) {
    if (actual[i] != int.parse(match.group(i + 1)!)) return false;
  }
  return true;
}

dynamic _freeze(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, value) => MapEntry(key as String, _freeze(value))),
    );
  }
  if (value is List) return List<dynamic>.unmodifiable(value.map(_freeze));
  return value;
}

class JoyRecord {
  final String id;
  final String kind;
  final String? parentId;
  final String title;
  final String description;
  final String createdAt;
  final String updatedAt;
  final String revision;
  final List<String> ancestors;
  final String? deletedAt;
  final Map<String, dynamic> data;

  JoyRecord({
    required this.id,
    required this.kind,
    this.parentId,
    required this.title,
    this.description = '',
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    List<String> ancestors = const [],
    this.deletedAt,
    Map<String, dynamic> data = const {},
  })  : ancestors = List.unmodifiable(ancestors),
        data = _freeze(data) as Map<String, dynamic>;

  factory JoyRecord.fromJson(Map<String, dynamic> json) {
    for (final key in [
      'id',
      'kind',
      'title',
      'createdAt',
      'updatedAt',
      'revision'
    ]) {
      if (json[key] is! String) throw FormatException('Invalid record $key');
    }
    for (final key in ['id', 'kind', 'revision']) {
      if ((json[key] as String).isEmpty) throw FormatException('Empty $key');
    }
    for (final key in ['createdAt', 'updatedAt']) {
      if (!_validUtc(json[key] as String)) {
        throw FormatException('Invalid $key');
      }
    }
    if (json['deletedAt'] != null &&
        (json['deletedAt'] is! String ||
            !_validUtc(json['deletedAt'] as String))) {
      throw const FormatException('Invalid deletedAt');
    }
    if ((json['parentId'] != null && json['parentId'] is! String) ||
        (json['description'] != null && json['description'] is! String) ||
        (json['ancestors'] != null &&
            (json['ancestors'] is! List ||
                (json['ancestors'] as List)
                    .any((value) => value is! String || value.isEmpty))) ||
        (json['data'] != null && json['data'] is! Map)) {
      throw const FormatException('Invalid record metadata');
    }
    return JoyRecord(
      id: json['id'] as String,
      kind: json['kind'] as String,
      parentId: json['parentId'] as String?,
      title: json['title'] as String,
      description: json['description'] as String? ?? '',
      createdAt: json['createdAt'] as String,
      updatedAt: json['updatedAt'] as String,
      revision: json['revision'] as String,
      ancestors: (json['ancestors'] as List? ?? []).cast<String>(),
      deletedAt: json['deletedAt'] as String?,
      data: Map<String, dynamic>.from(json['data'] as Map? ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'parentId': parentId,
        'title': title,
        'description': description,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'revision': revision,
        'ancestors': ancestors,
        'deletedAt': deletedAt,
        'data': data,
      };

  JoyRecord copyWith({
    String? id,
    String? kind,
    Object? parentId = _unchanged,
    String? title,
    String? description,
    String? createdAt,
    String? updatedAt,
    String? revision,
    List<String>? ancestors,
    Object? deletedAt = _unchanged,
    Map<String, dynamic>? data,
  }) =>
      JoyRecord(
        id: id ?? this.id,
        kind: kind ?? this.kind,
        parentId: identical(parentId, _unchanged)
            ? this.parentId
            : parentId as String?,
        title: title ?? this.title,
        description: description ?? this.description,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        revision: revision ?? this.revision,
        ancestors: ancestors ?? this.ancestors,
        deletedAt: identical(deletedAt, _unchanged)
            ? this.deletedAt
            : deletedAt as String?,
        data: data ?? this.data,
      );

  bool get isDeleted => deletedAt != null;
}

class JoySnapshot {
  final int schemaVersion;
  final String deviceId;
  final List<JoyRecord> records;

  JoySnapshot({
    this.schemaVersion = 1,
    required this.deviceId,
    required List<JoyRecord> records,
  }) : records = List.unmodifiable(records);

  factory JoySnapshot.fromJson(Map<String, dynamic> json) {
    if (json['schemaVersion'] != 1 ||
        json['deviceId'] is! String ||
        json['records'] is! List) {
      throw const FormatException('Unsupported snapshot');
    }
    return JoySnapshot(
      deviceId: json['deviceId'] as String,
      records: (json['records'] as List)
          .map((row) =>
              JoyRecord.fromJson(Map<String, dynamic>.from(row as Map)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'deviceId': deviceId,
        'records': records.map((record) => record.toJson()).toList(),
      };

  String encode() => jsonEncode(toJson());
}
