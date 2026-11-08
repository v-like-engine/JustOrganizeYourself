import 'dart:convert';

import 'package:excel/excel.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../storage/repository.dart';

class WorkbookCodec {
  static const _metaSheet = '_joy';
  static const _columns = [
    'id',
    'kind',
    'parent_id',
    'title',
    'description',
    'created_at',
    'updated_at',
    'revision',
    'ancestors_json',
    'deleted_at',
    'data_json',
    '_index',
    '_chunk_field',
    '_chunk_index',
    '_chunk_value',
  ];

  List<int> encode(JoySnapshot snapshot) {
    JoyRepository.validateSnapshot(snapshot);
    final book = Excel.createExcel();
    book.rename(book.getDefaultSheet()!, _metaSheet);
    final meta = book[_metaSheet];
    _append(meta, ['joy_schema', snapshot.schemaVersion.toString()]);
    _append(meta, ['device_id', snapshot.deviceId]);
    _append(meta, _columns);

    final byId = {for (final record in snapshot.records) record.id: record};
    final sheets = <String, Sheet>{};
    final usedNames = <String>{_metaSheet.toLowerCase()};
    for (final folder in snapshot.records.where((r) => r.kind == 'folder')) {
      final name = _sheetName(folder.title, usedNames);
      final sheet = book[name];
      _append(sheet, _columns);
      sheets[folder.id] = sheet;
    }

    for (var index = 0; index < snapshot.records.length; index++) {
      final record = snapshot.records[index];
      var root = record;
      final visited = <String>{record.id};
      while (root.parentId != null && byId.containsKey(root.parentId)) {
        root = byId[root.parentId]!;
        if (!visited.add(root.id)) {
          throw const FormatException('Folder hierarchy contains a cycle');
        }
      }
      final sheet = sheets[root.id] ?? meta;
      final values = [
        record.id,
        record.kind,
        record.parentId ?? '',
        record.title,
        record.description,
        record.createdAt,
        record.updatedAt,
        record.revision,
        jsonEncode(record.ancestors),
        record.deletedAt ?? '',
        jsonEncode(record.data),
      ];
      final first = <String>[];
      final chunks = <List<String>>[];
      for (var field = 0; field < values.length; field++) {
        final parts = _splitCell(values[field]);
        first.add(parts.first);
        for (var part = 1; part < parts.length; part++) {
          final row = List<String>.filled(_columns.length, '');
          row[0] = record.id;
          row[1] = '_chunk';
          row[12] = _columns[field];
          row[13] = part.toString();
          row[14] = parts[part];
          chunks.add(row);
        }
      }
      first.add(index.toString());
      _append(sheet, first);
      for (final chunk in chunks) {
        _append(sheet, chunk);
      }
    }
    final result = book.encode();
    if (result == null)
      throw const FormatException('Could not create workbook');
    return result;
  }

  JoySnapshot decode(List<int> bytes) {
    final book = _open(bytes);
    final meta = book.tables[_metaSheet];
    if (meta == null || _text(meta.rows.firstOrNull, 0) != 'joy_schema') {
      throw const FormatException(
          'Not a Just Organize Yourself workbook. Use Inbox import for a simple task list.');
    }
    final version = int.tryParse(_text(meta.rows.firstOrNull, 1));
    if (version != 1)
      throw const FormatException('Unsupported workbook version');
    if (_text(meta.rows.elementAtOrNull(1), 0) != 'device_id') {
      throw const FormatException('Workbook device metadata is missing');
    }
    final deviceId = _text(meta.rows.elementAtOrNull(1), 1);
    if (deviceId.isEmpty)
      throw const FormatException('Workbook device metadata is empty');

    final raw = <String, List<String>>{};
    final order = <String, int>{};
    final chunks = <String, Map<String, Map<int, String>>>{};
    for (final entry in book.tables.entries) {
      final rows = entry.value.rows;
      final start = entry.key == _metaSheet ? 2 : 0;
      if (rows.length <= start)
        throw FormatException('Missing header in ${entry.key}');
      for (var column = 0; column < _columns.length; column++) {
        if (_text(rows[start], column) != _columns[column]) {
          throw FormatException(
              'Unexpected column in ${entry.key}: ${_columns[column]}');
        }
      }
      for (final row in rows.skip(start + 1)) {
        if (row.every(
            (cell) => cell?.value == null || cell!.value.toString().isEmpty))
          continue;
        final id = _text(row, 0);
        if (id.isEmpty) throw const FormatException('A record has no ID');
        if (_text(row, 1) == '_chunk') {
          final field = _text(row, 12);
          final part = int.tryParse(_text(row, 13));
          if (!_columns.take(11).contains(field) || part == null || part < 1) {
            throw const FormatException('Invalid long-field continuation');
          }
          final parts = (chunks[id] ??= {})[field] ??= {};
          if (parts.containsKey(part))
            throw const FormatException('Duplicate continuation');
          parts[part] = _text(row, 14);
        } else {
          if (raw.containsKey(id))
            throw FormatException('Duplicate record ID: $id');
          raw[id] = List.generate(11, (i) => _text(row, i));
          order[id] = int.tryParse(_text(row, 11)) ?? raw.length;
        }
      }
    }
    for (final entry in chunks.entries) {
      final fields = raw[entry.key];
      if (fields == null)
        throw const FormatException('Continuation without a record');
      for (final field in entry.value.entries) {
        final index = _columns.indexOf(field.key);
        final sorted = field.value.keys.toList()..sort();
        for (var i = 0; i < sorted.length; i++) {
          if (sorted[i] != i + 1)
            throw const FormatException('Missing continuation');
          fields[index] += field.value[sorted[i]]!;
        }
      }
    }
    final ids = raw.keys.toList()
      ..sort((a, b) => order[a]!.compareTo(order[b]!));
    final records = <JoyRecord>[];
    try {
      for (final id in ids) {
        final row = raw[id]!;
        final ancestors = jsonDecode(row[8]);
        final data = jsonDecode(row[10]);
        if (ancestors is! List || data is! Map)
          throw const FormatException('Invalid record metadata');
        records.add(JoyRecord.fromJson({
          'id': row[0],
          'kind': row[1],
          'parentId': row[2].isEmpty ? null : row[2],
          'title': row[3],
          'description': row[4],
          'createdAt': row[5],
          'updatedAt': row[6],
          'revision': row[7],
          'ancestors': ancestors,
          'deletedAt': row[9].isEmpty ? null : row[9],
          'data': data,
        }));
      }
      final snapshot = JoySnapshot(
          deviceId: deviceId, records: records, schemaVersion: version!);
      JoyRepository.validateSnapshot(snapshot);
      return snapshot;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid record values in workbook');
    }
  }

  List<JoyRecord> decodeInbox(
    List<int> bytes, {
    String? sheetName,
    bool hasHeader = false,
    int titleColumn = 0,
    int? descriptionColumn,
    int? createdAtColumn,
    DateTime? importedAt,
    String parentId = 'inbox',
  }) {
    if ([titleColumn, descriptionColumn, createdAtColumn]
        .whereType<int>()
        .any((c) => c < 0)) {
      throw const FormatException('Column indexes must be nonnegative');
    }
    final book = _open(bytes);
    if (book.tables.isEmpty)
      throw const FormatException('Workbook has no sheets');
    final sheet =
        sheetName == null ? book.tables.values.first : book.tables[sheetName];
    if (sheet == null) throw FormatException('Sheet not found: $sheetName');
    final timestamp = (importedAt ?? DateTime.now()).toUtc().toIso8601String();
    const uuid = Uuid();
    final result = <JoyRecord>[];
    for (final row in sheet.rows.skip(hasHeader ? 1 : 0)) {
      final title = _text(row, titleColumn).trim();
      if (title.isEmpty) continue;
      final sourceDate =
          createdAtColumn == null ? '' : _text(row, createdAtColumn).trim();
      var createdAt = timestamp;
      if (sourceDate.isNotEmpty) {
        createdAt = _sourceDate(sourceDate, title).toIso8601String();
      }
      result.add(JoyRecord(
        id: uuid.v4(),
        kind: 'item',
        parentId: parentId,
        title: title,
        description:
            descriptionColumn == null ? '' : _text(row, descriptionColumn),
        createdAt: createdAt,
        updatedAt: timestamp,
        revision: uuid.v4(),
      ));
    }
    return result;
  }

  Excel _open(List<int> bytes) {
    if (bytes.isEmpty) throw const FormatException('Workbook is empty');
    try {
      return Excel.decodeBytes(bytes);
    } catch (_) {
      throw const FormatException('Could not read this XLSX file');
    }
  }

  DateTime _sourceDate(String value, String title) {
    final parts = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})(?:[Tt ](\d{2}):(\d{2})(?::(\d{2}))?)?')
        .firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (parts == null || parsed == null)
      throw FormatException('Invalid creation time for "$title"');
    final values =
        List.generate(6, (i) => int.parse(parts.group(i + 1) ?? '0'));
    final check = DateTime.utc(
        values[0], values[1], values[2], values[3], values[4], values[5]);
    if ([
      check.year,
      check.month,
      check.day,
      check.hour,
      check.minute,
      check.second
    ].asMap().entries.any((e) => values[e.key] != e.value)) {
      throw FormatException('Invalid creation time for "$title"');
    }
    if (parsed.isUtc) return parsed;
    return DateTime.utc(parsed.year, parsed.month, parsed.day, parsed.hour,
        parsed.minute, parsed.second, parsed.millisecond, parsed.microsecond);
  }

  String _text(List<Data?>? row, int index) {
    if (row == null || index >= row.length) return '';
    final value = row[index]?.value;
    if (value is DateCellValue) {
      return DateTime.utc(value.year, value.month, value.day).toIso8601String();
    }
    if (value is DateTimeCellValue) {
      return DateTime.utc(value.year, value.month, value.day, value.hour,
              value.minute, value.second)
          .toIso8601String();
    }
    if (value is FormulaCellValue)
      throw const FormatException(
          'Formula cells are not supported for imported data');
    return value?.toString() ?? '';
  }

  void _append(Sheet sheet, List<String> row) {
    if (sheet.maxRows >= 1048576)
      throw const FormatException('Excel sheet row limit reached');
    sheet.appendRow(row.map<CellValue>((v) => TextCellValue(v)).toList());
  }

  String _sheetName(String title, Set<String> used) {
    var base = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), ' ').trim();
    base = base.replaceAll(RegExp(r"^'+|'+$"), '');
    if (base.isEmpty) base = 'Folder';
    if (base.length > 31) base = base.substring(0, 31);
    var name = base;
    var suffix = 2;
    while (used.contains(name.toLowerCase())) {
      final ending = ' ($suffix)';
      name =
          '${base.substring(0, base.length.clamp(0, 31 - ending.length))}$ending';
      suffix++;
    }
    used.add(name.toLowerCase());
    return name;
  }

  List<String> _splitCell(String text) {
    if (text.length <= 30000) return [text];
    final result = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + 30000).clamp(0, text.length);
      if (end < text.length &&
          text.codeUnitAt(end - 1) >= 0xD800 &&
          text.codeUnitAt(end - 1) <= 0xDBFF) end--;
      result.add(text.substring(start, end));
      start = end;
    }
    return result;
  }
}
