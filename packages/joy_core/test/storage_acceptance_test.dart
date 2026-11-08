import 'dart:io';

import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  late JoyRepository repo;

  setUp(() {
    repo = JoyRepository.memory(deviceId: 'qa-device');
  });

  tearDown(() {
    repo.close();
  });

  test('SQLite reopen preserves hierarchy, text and additional fields', () {
    final directory = Directory.systemTemp.createTempSync('joy-acceptance-');
    final path = '${directory.path}/data.sqlite';
    final disk = JoyRepository.open(path: path, deviceId: 'qa-disk');
    final folder = disk.create(kind: 'folder', title: 'Мои покупки 🛒');
    final section = disk.create(
      kind: 'subfolder',
      parentId: folder.id,
      title: 'Аптека',
      description: 'Список для поездки',
    );
    final item = disk.create(
      kind: 'item',
      parentId: section.id,
      title: 'Купить лекарство',
      description: 'Не забыть рецепт',
      data: {
        'priority': 2,
        'durationMinutes': 15,
        'custom': {
          'source': 'phone',
          'tags': ['дом', '药']
        },
      },
    );
    disk.close();

    final reopened = JoyRepository.open(path: path);
    try {
      expect(reopened.get(item.id)?.toJson(), item.toJson());
      expect(reopened.get(section.id)?.description, 'Список для поездки');
      expect(reopened.children(folder.id).map((r) => r.id), [section.id]);
      expect(item.createdAt, endsWith('Z'));
      expect(DateTime.parse(item.createdAt).isUtc, isTrue);
    } finally {
      reopened.close();
      directory.deleteSync(recursive: true);
    }
  });

  test('replace import undo restores folders, records and settings together',
      () {
    final folder = repo.create(kind: 'folder', title: 'Original folder');
    repo.create(kind: 'subfolder', parentId: folder.id, title: 'Empty section');
    repo.create(kind: 'item', parentId: 'inbox', title: 'Original task');
    repo.saveSettings({...repo.settings.data, 'trashDays': 7, 'locale': 'ru'});
    final before = repo.snapshot().toJson();

    final other = JoyRepository.memory(deviceId: 'qa-remote');
    other.create(kind: 'folder', title: 'Imported folder');
    other.create(kind: 'item', parentId: 'inbox', title: 'Imported task');
    other.saveSettings({...other.settings.data, 'locale': 'de'});
    final incoming = other.snapshot();
    other.close();

    repo.importSnapshot(incoming, replace: true);
    expect(repo.inboxItems.map((r) => r.title), ['Imported task']);
    repo.folders;
    repo.children('inbox');
    repo.snapshot();
    expect(repo.undoImport(), isTrue);
    expect(repo.snapshot().toJson(), before);
    expect(repo.undoImport(), isFalse);
  });

  test('add import keeps original tasks and can undo the whole addition', () {
    repo.create(kind: 'item', parentId: 'inbox', title: 'Existing');
    final before = repo.snapshot().toJson();
    final base = repo.snapshot();
    final folder =
        qaRecord('added-folder', kind: 'folder', title: 'New folder');
    final section = qaRecord(
      'added-section',
      kind: 'subfolder',
      title: 'New empty section',
      parentId: folder.id,
    );
    final item = qaRecord('added-item', parentId: 'inbox', title: 'Imported');

    repo.importSnapshot(JoySnapshot(
      deviceId: 'remote',
      records: [...base.records, folder, section, item],
    ));
    expect(repo.inboxItems.map((r) => r.title),
        containsAll(['Existing', 'Imported']));
    expect(repo.get(section.id)?.parentId, folder.id);
    expect(repo.undoImport(), isTrue);
    expect(repo.snapshot().toJson(), before);
  });

  test('data mutation closes import undo, navigation does not', () {
    final base = repo.snapshot();
    repo.importSnapshot(JoySnapshot(
      deviceId: 'remote',
      records: [...base.records, qaRecord('imported', parentId: 'inbox')],
    ));
    repo.inboxItems;
    repo.settings;
    repo.get('imported');
    repo.create(kind: 'item', parentId: 'inbox', title: 'After import');
    expect(repo.undoImport(), isFalse);
    expect(repo.get('imported'), isNotNull);
  });

  test('invalid snapshot cannot partially replace the existing data', () {
    repo.create(kind: 'item', parentId: 'inbox', title: 'Keep me');
    repo.saveSettings({...repo.settings.data, 'locale': 'fr'});
    final before = repo.snapshot().toJson();
    final base = repo.snapshot();
    final orphan = qaRecord('orphan', parentId: 'missing-folder');

    expect(
      () => repo.importSnapshot(
        JoySnapshot(deviceId: 'remote', records: [...base.records, orphan]),
        replace: true,
      ),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('same-ID conflicting addition is rejected before any mutation', () {
    final item =
        repo.create(kind: 'item', parentId: 'inbox', title: 'Original');
    final before = repo.snapshot().toJson();
    final records = repo.snapshot().records.map((r) {
      if (r.id != item.id) return r;
      return JoyRecord.fromJson({
        ...r.toJson(),
        'title': 'Divergent imported title',
        'revision': 'unrelated-revision',
      });
    }).toList();

    expect(
      () => repo
          .importSnapshot(JoySnapshot(deviceId: 'remote', records: records)),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('unsupported Add schema cannot bypass snapshot version validation', () {
    final before = repo.snapshot().toJson();
    expect(
      () => repo.importSnapshot(JoySnapshot(
        schemaVersion: 2,
        deviceId: 'remote',
        records: [
          ...repo.snapshot().records,
          qaRecord('newer', parentId: 'inbox')
        ],
      )),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('duplicate IDs in incoming Add are invalid even when rows are identical',
      () {
    final before = repo.snapshot().toJson();
    final added = qaRecord('duplicated', parentId: 'inbox');
    expect(
      () => repo.importSnapshot(JoySnapshot(
        deviceId: 'remote',
        records: [added, added],
      )),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('impossible dates cannot be silently normalized during import', () {
    final before = repo.snapshot().toJson();
    final invalid = qaRecord('bad-date', parentId: 'inbox').copyWith(
      createdAt: '2026-02-31T12:00:00.000Z',
    );
    expect(
      () => repo
          .importSnapshot(JoySnapshot(deviceId: 'remote', records: [invalid])),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('complete project requirements cannot be bypassed through import', () {
    final before = repo.snapshot().toJson();
    final incomplete =
        qaRecord('bad-project', kind: 'project', parentId: 'projects')
            .copyWith(data: {'draft': false});
    expect(
      () => repo.importSnapshot(
          JoySnapshot(deviceId: 'remote', records: [incomplete])),
      throwsA(anyOf(
          isA<ArgumentError>(), isA<FormatException>(), isA<StateError>())),
    );
    expect(repo.snapshot().toJson(), before);
  });

  test('caller mutation cannot change an already created record', () {
    final labels = <String>['original'];
    final nested = <String, dynamic>{'labels': labels};
    final record = repo.create(
      kind: 'item',
      parentId: 'inbox',
      title: 'Immutable data',
      data: {'custom': nested},
    );
    labels.add('changed');
    nested['other'] = true;
    expect(record.data['custom'], {
      'labels': ['original']
    });
    expect(repo.get(record.id)?.data['custom'], {
      'labels': ['original']
    });
  });

  test(
      'task numbers use creation instant and stable ID, never local insertion order',
      () {
    final a = qaRecord('a-task', parentId: 'inbox');
    final b = qaRecord('b-task', parentId: 'inbox');
    final base = repo.snapshot();
    repo.replaceAll(JoySnapshot(
      deviceId: 'remote',
      records: [...base.records, b, a],
    ));
    expect(repo.ordinalOf(a.id), 1);
    expect(repo.ordinalOf(b.id), 2);
    repo.edit(a.id, title: 'Renamed');
    repo.move(a.id, 'shopping');
    expect(repo.ordinalOf(a.id), 1);
    expect(repo.ordinalOf(b.id), 2);
    expect(repo.get(a.id)?.id, a.id);
  });

  test('Trash lifetime starts at trash time and produces a retained tombstone',
      () {
    repo.saveSettings({...repo.settings.data, 'trashDays': 7});
    final item = repo.create(kind: 'item', parentId: 'inbox', title: 'Discard');
    final trashed = repo.trash(item.id);
    final start = DateTime.parse(trashed.data['trashedAt'] as String);
    expect(trashed.createdAt, item.createdAt);
    expect(
        repo.purgeTrash(now: start.add(const Duration(days: 6, hours: 23))), 0);
    expect(repo.purgeTrash(now: start.add(const Duration(days: 7, seconds: 1))),
        1);
    expect(repo.all().any((r) => r.id == item.id), isFalse);
    final retained =
        repo.all(includeDeleted: true).singleWhere((r) => r.id == item.id);
    expect(retained.deletedAt, isNotNull);
  });
}

JoyRecord qaRecord(
  String id, {
  String kind = 'item',
  String title = 'Task',
  String? parentId,
}) {
  return JoyRecord.fromJson({
    'id': id,
    'kind': kind,
    'parentId': parentId,
    'title': title,
    'description': '',
    'createdAt': '2026-11-08T12:00:00.000Z',
    'updatedAt': '2026-11-08T12:00:00.000Z',
    'revision': 'revision-$id',
    'ancestors': <String>[],
    'deletedAt': null,
    'data': <String, dynamic>{},
  });
}
