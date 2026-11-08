import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/open.dart' as sqlite;
import 'package:uuid/uuid.dart';
import '../domain/models.dart';

const _keep = Object();
const _uuid = Uuid();

dynamic _sortedJson(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sortedJson(value[key])};
  }
  if (value is List) return value.map(_sortedJson).toList();
  return value;
}

class JoyRepository {
  final Database _db;
  late final String deviceId;
  JoySnapshot? _undo;
  static bool _loaderConfigured = false;

  static void _configureLoader() {
    if (_loaderConfigured) return;
    if (Platform.isLinux) {
      sqlite.open.overrideFor(sqlite.OperatingSystem.linux, () {
        try {
          return DynamicLibrary.open('libsqlite3_flutter_libs_plugin.so');
        } on ArgumentError {
          try {
            return DynamicLibrary.open('libsqlite3.so');
          } on ArgumentError {
            return DynamicLibrary.open('libsqlite3.so.0');
          }
        }
      });
    }
    _loaderConfigured = true;
  }

  JoyRepository._(this._db, String? requestedDeviceId) {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA busy_timeout=5000');
    _db.execute(
        'CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, body TEXT NOT NULL)');
    _db.execute(
        'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    final saved = _db.select("SELECT value FROM metadata WHERE key='deviceId'");
    deviceId = saved.isEmpty
        ? requestedDeviceId ?? _uuid.v4()
        : saved.first['value'] as String;
    _db.execute(
        "INSERT OR IGNORE INTO metadata (key, value) VALUES ('deviceId', ?)",
        [deviceId]);
    if (_db
        .select("SELECT value FROM metadata WHERE key='initialized'")
        .isEmpty) {
      _transaction(() {
        for (final record in _seeds()) _put(record);
        _db.execute(
            "INSERT INTO metadata (key, value) VALUES ('initialized', '1')");
      });
    }
  }

  factory JoyRepository.open({required String path, String? deviceId}) {
    _configureLoader();
    return JoyRepository._(sqlite3.open(path), deviceId);
  }

  factory JoyRepository.memory({String? deviceId}) {
    _configureLoader();
    return JoyRepository._(sqlite3.openInMemory(), deviceId);
  }

  static List<JoyRecord> _seeds() {
    const names = {
      'inbox': 'Inbox',
      'projects': 'Projects',
      'knowledge': 'Knowledge',
      'contacts': 'Contacts',
      'shopping': 'Shopping Lists',
      'calendar': 'Calendar',
      'delegated': 'Delegated',
      'someday': 'Someday / Later',
      'urgent': 'Urgent',
      'by-date': 'By Date',
      'conditional': 'Conditional',
      'trash': 'Trash',
    };
    const epoch = '2000-01-01T00:00:00.000Z';
    final records = <JoyRecord>[];
    var order = 0;
    for (final entry in names.entries) {
      records.add(JoyRecord(
        id: entry.key,
        kind: 'folder',
        title: entry.value,
        createdAt: epoch,
        updatedAt: epoch,
        revision: 'seed-v1',
        data: {'order': order++, 'preset': true, 'category': entry.key},
      ));
    }
    records.add(JoyRecord(
      id: 'settings',
      kind: 'settings',
      title: 'Settings',
      createdAt: epoch,
      updatedAt: epoch,
      revision: 'seed-v1',
      data: {
        'locale': 'en',
        'trashDays': 30,
        'triageMenus': <String, dynamic>{}
      },
    ));
    return records;
  }

  List<JoyRecord> all({bool includeDeleted = false}) {
    final records = _db
        .select('SELECT body FROM records')
        .map((row) => JoyRecord.fromJson(
            jsonDecode(row['body'] as String) as Map<String, dynamic>))
        .where((record) => includeDeleted || !record.isDeleted)
        .toList();
    records.sort(_chronological);
    return records;
  }

  static int _chronological(JoyRecord a, JoyRecord b) {
    final date =
        DateTime.parse(a.createdAt).compareTo(DateTime.parse(b.createdAt));
    return date == 0 ? a.id.compareTo(b.id) : date;
  }

  JoyRecord? get(String id) {
    final rows = _db.select('SELECT body FROM records WHERE id = ?', [id]);
    return rows.isEmpty
        ? null
        : JoyRecord.fromJson(
            jsonDecode(rows.first['body'] as String) as Map<String, dynamic>);
  }

  JoyRecord _require(String id) {
    final record = get(id);
    if (record == null || record.isDeleted)
      throw StateError('Record not found');
    return record;
  }

  List<JoyRecord> children(String parentId) {
    final records =
        all().where((record) => record.parentId == parentId).toList();
    records.sort((a, b) {
      final order = ((a.data['order'] as num?) ?? 0)
          .compareTo((b.data['order'] as num?) ?? 0);
      return order == 0 ? _chronological(a, b) : order;
    });
    return records;
  }

  List<JoyRecord> get folders =>
      all().where((record) => record.kind == 'folder').toList()
        ..sort((a, b) => ((a.data['order'] as num?) ?? 0)
            .compareTo((b.data['order'] as num?) ?? 0));
  List<JoyRecord> get inboxItems =>
      children('inbox').where((record) => record.kind == 'item').toList();
  JoyRecord get settings => _require('settings');
  bool get canUndoImport => _undo != null;

  int? ordinalOf(String id) {
    final tasks = all(includeDeleted: true)
        .where((record) => ['item', 'project', 'action'].contains(record.kind))
        .toList();
    final index = tasks.indexWhere((record) => record.id == id);
    return index < 0 ? null : index + 1;
  }

  JoySnapshot snapshot() =>
      JoySnapshot(deviceId: deviceId, records: all(includeDeleted: true));

  String get stateToken => sha256
      .convert(utf8.encode(jsonEncode(_sortedJson(snapshot().toJson()))))
      .toString();

  JoyRecord create(
      {required String kind,
      required String title,
      String? parentId,
      String description = '',
      Map<String, dynamic> data = const {}}) {
    if (title.trim().isEmpty) throw ArgumentError('Title is required');
    final now = DateTime.now().toUtc().toIso8601String();
    final order = parentId == null ? folders.length : children(parentId).length;
    final record = JoyRecord(
      id: _uuid.v4(),
      kind: kind,
      parentId: parentId,
      title: title.trim(),
      description: description,
      createdAt: now,
      updatedAt: now,
      revision: _uuid.v4(),
      data: {'order': order, ...data},
    );
    _write(record);
    return record;
  }

  JoyRecord edit(String id,
      {String? title,
      String? description,
      Object? parentId = _keep,
      Map<String, dynamic>? data}) {
    final old = _require(id);
    if (title != null && title.trim().isEmpty)
      throw ArgumentError('Title is required');
    final record = _revised(old,
        title: title?.trim(),
        description: description,
        parentId: parentId,
        data: data);
    _write(record);
    return record;
  }

  JoyRecord _revised(JoyRecord record,
          {String? title,
          String? description,
          String? kind,
          Object? parentId = _keep,
          Object? deletedAt = _keep,
          Map<String, dynamic>? data}) =>
      record.copyWith(
        title: title,
        description: description,
        kind: kind,
        parentId: identical(parentId, _keep) ? record.parentId : parentId,
        deletedAt: identical(deletedAt, _keep) ? record.deletedAt : deletedAt,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        revision: _uuid.v4(),
        ancestors: {...record.ancestors, record.revision}.toList(),
        data: data,
      );

  JoyRecord move(String id, String parentId) {
    if (parentId == 'trash') return trash(id);
    final old = _require(id);
    final data = Map<String, dynamic>.from(old.data)..remove('trashedAt');
    data.remove('previousParentId');
    final projectTarget = _folderId(parentId) == 'projects';
    if (projectTarget && old.kind == 'item') data['draft'] = true;
    final record = _revised(old,
        parentId: parentId,
        kind: projectTarget && old.kind == 'item' ? 'project' : old.kind,
        data: data);
    _write(record);
    return record;
  }

  String? _folderId(String id) {
    var record = _require(id);
    final seen = <String>{};
    while (record.parentId != null) {
      if (!seen.add(record.id)) throw StateError('Hierarchy cycle');
      record = _require(record.parentId!);
    }
    return record.kind == 'folder' ? record.id : null;
  }

  JoyRecord trash(String id) {
    if (['inbox', 'trash', 'settings'].contains(id))
      throw StateError('Required section');
    final old = _require(id);
    final record = _revised(old, parentId: 'trash', data: {
      ...old.data,
      'trashedAt': DateTime.now().toUtc().toIso8601String(),
      'previousParentId': old.parentId,
    });
    _write(record);
    return record;
  }

  JoyRecord restore(String id) {
    final old = _require(id);
    if (old.parentId != 'trash') throw StateError('Record is not in Trash');
    final previous = old.data['previousParentId'] as String?;
    if (old.kind == 'folder') {
      final data = Map<String, dynamic>.from(old.data)
        ..remove('trashedAt')
        ..remove('previousParentId');
      final restored = _revised(old, parentId: null, data: data);
      _write(restored);
      return restored;
    }
    final destination = previous != null && get(previous)?.isDeleted == false
        ? previous
        : 'inbox';
    return move(id, destination);
  }

  void delete(String id) {
    if (['inbox', 'trash', 'settings'].contains(id))
      throw StateError('Required section');
    final record = _require(id);
    if (children(id).isNotEmpty) throw StateError('Section is not empty');
    _write(
        _revised(record, deletedAt: DateTime.now().toUtc().toIso8601String()));
  }

  int purgeTrash({DateTime? now}) {
    final days = settings.data['trashDays'] as int? ?? 30;
    if (days < 1) throw StateError('Trash retention must be at least one day');
    final cutoff =
        (now ?? DateTime.now()).toUtc().subtract(Duration(days: days));
    final due = children('trash').where((record) {
      final entered =
          DateTime.tryParse(record.data['trashedAt'] as String? ?? '');
      return entered != null && !entered.isAfter(cutoff);
    }).toList();
    if (due.isEmpty) return 0;
    final records = {
      for (final record in all(includeDeleted: true)) record.id: record
    };
    final pending = due.map((record) => record.id).toSet();
    var changed = true;
    while (changed) {
      changed = false;
      for (final record in records.values) {
        if (pending.contains(record.parentId) && pending.add(record.id))
          changed = true;
      }
    }
    final deletedAt = (now ?? DateTime.now()).toUtc().toIso8601String();
    _transaction(() {
      for (final id in pending)
        _put(_revised(records[id]!,
            title: '', description: '', data: {}, deletedAt: deletedAt));
    });
    _undo = null;
    return pending.length;
  }

  JoyRecord saveSettings(Map<String, dynamic> data) {
    final updated = {...settings.data, ...data};
    if (updated['trashDays'] is! int || (updated['trashDays'] as int) < 1) {
      throw ArgumentError('Trash retention must be a positive number of days');
    }
    return edit('settings', data: updated);
  }

  JoyRecord saveProject(
      {String? id,
      required String title,
      String description = '',
      String plan = '',
      String criterion = '',
      String? completionCriterion,
      required List<String> actions,
      String parentId = 'projects',
      bool draft = false}) {
    criterion = completionCriterion ?? criterion;
    final titles = actions
        .map((text) => text.trim())
        .where((text) => text.isNotEmpty)
        .toList();
    if (!draft &&
        (description.trim().isEmpty ||
            plan.trim().isEmpty ||
            criterion.trim().isEmpty ||
            titles.isEmpty)) {
      throw ArgumentError(
          'Description, plan, completion criterion and an action are required');
    }
    if (title.trim().isEmpty) throw ArgumentError('Title is required');
    final now = DateTime.now().toUtc().toIso8601String();
    final old = id == null ? null : _require(id);
    final record = old == null
        ? JoyRecord(
            id: _uuid.v4(),
            kind: 'project',
            parentId: parentId,
            title: title.trim(),
            description: description,
            createdAt: now,
            updatedAt: now,
            revision: _uuid.v4(),
            data: {
              'plan': plan,
              'completionCriterion': criterion,
              'draft': draft
            },
          )
        : _revised(old,
            kind: 'project',
            parentId: parentId,
            title: title.trim(),
            description: description,
            data: {
                ...old.data,
                'plan': plan,
                'completionCriterion': criterion,
                'draft': draft
              });
    final allRecords = {
      for (final entry in all(includeDeleted: true)) entry.id: entry
    };
    allRecords[record.id] = record;
    final previous =
        children(record.id).where((entry) => entry.kind == 'action').toList();
    final matches = List<JoyRecord?>.filled(titles.length, null);
    final used = <String>{};
    for (var i = 0; i < titles.length; i++) {
      for (final oldAction in previous) {
        if (oldAction.title == titles[i] && used.add(oldAction.id)) {
          matches[i] = oldAction;
          break;
        }
      }
    }
    for (var i = 0; i < titles.length; i++) {
      if (matches[i] != null) continue;
      if (i < previous.length && used.add(previous[i].id))
        matches[i] = previous[i];
    }
    for (var i = 0; i < titles.length; i++) {
      final oldAction = matches[i];
      final action = oldAction != null
          ? _revised(oldAction,
              title: titles[i], data: {...oldAction.data, 'order': i})
          : JoyRecord(
              id: _uuid.v4(),
              kind: 'action',
              parentId: record.id,
              title: titles[i],
              createdAt: now,
              updatedAt: now,
              revision: _uuid.v4(),
              data: {'order': i});
      allRecords[action.id] = action;
    }
    for (final removed
        in previous.where((action) => !used.contains(action.id))) {
      allRecords[removed.id] = _revised(removed, deletedAt: now);
    }
    _validate(allRecords.values.toList());
    _transaction(() {
      for (final entry in allRecords.values) _put(entry);
    });
    _undo = null;
    return record;
  }

  void _write(JoyRecord record) {
    final records = {
      for (final existing in all(includeDeleted: true)) existing.id: existing
    };
    records[record.id] = record;
    _validate(records.values.toList());
    _transaction(() => _put(record));
    _undo = null;
  }

  void replaceAll(JoySnapshot incoming,
      {bool rememberUndo = false, String? expectedState}) {
    validateSnapshot(incoming);
    final previous = rememberUndo ? snapshot() : null;
    _transaction(() {
      if (expectedState != null && expectedState != stateToken)
        throw StateError('Data changed during synchronization');
      _db.execute('DELETE FROM records');
      for (final record in incoming.records) _put(record);
    });
    _undo = previous;
  }

  void importSnapshot(JoySnapshot incoming,
      {bool replace = false, String? expectedState}) {
    if (incoming.schemaVersion != 1)
      throw const FormatException('Unsupported snapshot version');
    final ids = <String>{};
    for (final record in incoming.records) {
      JoyRecord.fromJson(record.toJson());
      if (!ids.add(record.id))
        throw const FormatException('Duplicate imported ID');
    }
    final beforeState = expectedState ?? stateToken;
    final records = {
      for (final record in all(includeDeleted: true)) record.id: record
    };
    if (replace) {
      validateSnapshot(incoming);
      final imported = {
        for (final record in incoming.records) record.id: record
      };
      final removedAt = DateTime.now().toUtc().toIso8601String();
      for (final existing in records.values) {
        if (!imported.containsKey(existing.id)) {
          imported[existing.id] = existing.isDeleted
              ? existing
              : _revised(existing,
                  title: '', description: '', data: {}, deletedAt: removedAt);
        }
      }
      for (final record in incoming.records) {
        final existing = records[record.id];
        if (existing != null &&
            !record.ancestors.contains(existing.revision) &&
            jsonEncode(_sortedJson(existing.toJson())) !=
                jsonEncode(_sortedJson(record.toJson()))) {
          imported[record.id] = record.copyWith(
            revision: _uuid.v4(),
            updatedAt: removedAt,
            ancestors: {
              ...existing.ancestors,
              existing.revision,
              ...record.ancestors,
              record.revision,
            }.toList()
              ..sort(),
          );
        }
      }
      replaceAll(
          JoySnapshot(deviceId: deviceId, records: imported.values.toList()),
          rememberUndo: true,
          expectedState: beforeState);
      return;
    }
    for (final record in incoming.records) {
      final existing = records[record.id];
      if (existing != null &&
          jsonEncode(_sortedJson(existing.toJson())) !=
              jsonEncode(_sortedJson(record.toJson()))) {
        throw StateError('Import conflict: ${record.title}');
      }
      records[record.id] = record;
    }
    replaceAll(
        JoySnapshot(deviceId: deviceId, records: records.values.toList()),
        rememberUndo: true,
        expectedState: beforeState);
  }

  bool undoImport() {
    final previous = _undo;
    if (previous == null) return false;
    replaceAll(previous);
    return true;
  }

  static void validateSnapshot(JoySnapshot incoming) {
    if (incoming.schemaVersion != 1)
      throw const FormatException('Unsupported snapshot version');
    _validate(incoming.records);
  }

  static void _validate(List<JoyRecord> records) {
    const kinds = {
      'folder',
      'subfolder',
      'item',
      'project',
      'action',
      'settings'
    };
    final byId = <String, JoyRecord>{};
    for (final record in records) {
      JoyRecord.fromJson(record.toJson());
      if (!kinds.contains(record.kind))
        throw const FormatException('Unknown record kind');
      if (byId.containsKey(record.id))
        throw const FormatException('Duplicate record ID');
      if (!record.isDeleted && record.title.trim().isEmpty)
        throw const FormatException('Empty title');
      byId[record.id] = record;
    }
    for (final id in ['inbox', 'trash']) {
      final record = byId[id];
      if (record == null ||
          record.isDeleted ||
          record.kind != 'folder' ||
          record.parentId != null) {
        throw FormatException('Missing required folder: $id');
      }
    }
    final settings = byId['settings'];
    if (settings == null ||
        settings.kind != 'settings' ||
        settings.isDeleted ||
        settings.data['trashDays'] is! int ||
        (settings.data['trashDays'] as int) < 1) {
      throw const FormatException('Invalid settings');
    }
    for (final record in records) {
      if (record.isDeleted) continue;
      if (record.kind == 'settings') {
        if (record.parentId != null)
          throw const FormatException('Settings cannot have a parent');
        continue;
      }
      if (record.kind == 'folder' && record.parentId == null) continue;
      final parent = byId[record.parentId];
      if (parent == null || parent.isDeleted)
        throw const FormatException('Missing parent');
      if (parent.id == 'trash') continue;
      final allowed = switch (record.kind) {
        'folder' => false,
        'subfolder' => parent.kind == 'folder',
        'item' ||
        'project' =>
          parent.kind == 'folder' || parent.kind == 'subfolder',
        'action' => parent.kind == 'project',
        _ => false,
      };
      if (!allowed) throw const FormatException('Invalid hierarchy');
      final seen = {record.id};
      var current = parent;
      while (current.parentId != null) {
        if (!seen.add(current.id))
          throw const FormatException('Hierarchy cycle');
        final next = byId[current.parentId];
        if (next == null) throw const FormatException('Missing ancestor');
        current = next;
      }
      if (record.kind == 'project' && record.data['draft'] != true) {
        if (record.description.trim().isEmpty ||
            (record.data['plan'] as String? ?? '').trim().isEmpty ||
            (record.data['completionCriterion'] as String? ?? '')
                .trim()
                .isEmpty ||
            !records.any((action) =>
                action.kind == 'action' &&
                action.parentId == record.id &&
                !action.isDeleted)) {
          throw const FormatException('Incomplete project');
        }
      }
    }
  }

  void _put(JoyRecord record) => _db.execute(
        'INSERT OR REPLACE INTO records (id, body) VALUES (?, ?)',
        [record.id, jsonEncode(record.toJson())],
      );

  void _transaction(void Function() write) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      write();
      _db.execute('COMMIT');
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _db.dispose();
}
