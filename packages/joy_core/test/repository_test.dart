import 'dart:io';
import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  late JoyRepository repo;
  setUp(() => repo = JoyRepository.memory(deviceId: 'test-device'));
  tearDown(() => repo.close());

  test(
      'durable metadata, UTC capture and arbitrary nested fields survive restart',
      () {
    final dir = Directory.systemTemp.createTempSync('joy-repository-');
    final path = '${dir.path}/joy.sqlite';
    final db = JoyRepository.open(path: path, deviceId: 'first-device');
    final task =
        db.create(kind: 'item', title: 'Buy milk', parentId: 'inbox', data: {
      'priority': 2,
      'extra': {
        'tags': ['food']
      }
    });
    db.close();
    final reopened = JoyRepository.open(path: path, deviceId: 'other-device');
    expect(reopened.deviceId, 'first-device');
    expect(reopened.get(task.id)!.createdAt, task.createdAt);
    expect(task.createdAt.endsWith('Z'), isTrue);
    expect(reopened.get(task.id)!.data['extra'], {
      'tags': ['food']
    });
    reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('immutable record prevents mutations without revision', () {
    final task =
        repo.create(kind: 'item', title: 'Read', parentId: 'inbox', data: {
      'extra': {
        'tags': ['book']
      }
    });
    expect(() => task.data['x'] = 1, throwsUnsupportedError);
    expect(
        () => (task.data['extra'] as Map)['tags'] = [], throwsUnsupportedError);
    expect(() => ((task.data['extra'] as Map)['tags'] as List).add('x'),
        throwsUnsupportedError);
  });

  test('editing makes a descendant revision and retains creation date', () {
    final task = repo.create(kind: 'item', title: 'Read', parentId: 'inbox');
    final changed = repo.edit(task.id, title: 'Read tomorrow');
    expect(changed.id, task.id);
    expect(changed.createdAt, task.createdAt);
    expect(changed.revision, isNot(task.revision));
    expect(changed.ancestors, contains(task.revision));
  });

  test('hierarchy accepts empty sections, rejects cycles and wrong parents',
      () {
    final folder = repo.create(kind: 'folder', title: 'Purchases');
    final sub =
        repo.create(kind: 'subfolder', title: 'Pharmacy', parentId: folder.id);
    repo.create(kind: 'item', title: 'Vitamins', parentId: sub.id);
    final before = repo.stateToken;
    expect(() => repo.move(folder.id, sub.id), throwsFormatException);
    expect(
        () =>
            repo.create(kind: 'action', title: 'Invalid', parentId: folder.id),
        throwsFormatException);
    expect(repo.stateToken, before);
    expect(() => repo.delete(folder.id), throwsStateError);
  });

  test('Add and undo restore empty folders, settings and task data', () {
    final original = repo.snapshot().encode();
    final external = JoyRepository.memory(deviceId: 'other');
    final folder = external.create(
        kind: 'folder', title: 'Another list', description: 'Imported');
    external.create(kind: 'subfolder', title: 'Empty', parentId: folder.id);
    repo.importSnapshot(external.snapshot());
    expect(repo.get(folder.id)?.description, 'Imported');
    expect(repo.canUndoImport, isTrue);
    expect(repo.undoImport(), isTrue);
    expect(repo.snapshot().encode(), original);
    external.close();
  });

  test('Replace and undo recover all local records and settings', () {
    repo.create(kind: 'item', title: 'Local', parentId: 'inbox');
    repo.saveSettings({'locale': 'ru', 'trashDays': 7});
    final original = repo.snapshot().encode();
    final external = JoyRepository.memory(deviceId: 'other');
    repo.importSnapshot(external.snapshot(), replace: true);
    expect(repo.inboxItems, isEmpty);
    expect(repo.settings.data['locale'], 'en');
    expect(repo.deviceId, 'test-device');
    repo.undoImport();
    expect(repo.snapshot().encode(), original);
    external.close();
  });

  test('next mutation closes immediate import undo window', () {
    repo.importSnapshot(repo.snapshot());
    expect(repo.canUndoImport, isTrue);
    repo.create(kind: 'item', title: 'New', parentId: 'inbox');
    expect(repo.canUndoImport, isFalse);
    expect(repo.undoImport(), isFalse);
  });

  test('invalid import fails atomically and keeps previous undo state', () {
    final original = repo.stateToken;
    final missingParent = JoyRecord(
        id: 'invalid',
        kind: 'item',
        title: 'Orphan',
        parentId: 'missing',
        createdAt: '2026-01-01T00:00:00Z',
        updatedAt: '2026-01-01T00:00:00Z',
        revision: 'new');
    expect(
        () => repo.importSnapshot(
            JoySnapshot(deviceId: 'x', records: [missingParent])),
        throwsFormatException);
    expect(repo.stateToken, original);
    expect(
        () => repo.importSnapshot(
            JoySnapshot(schemaVersion: 2, deviceId: 'x', records: [])),
        throwsFormatException);
    final seed = repo.get('inbox')!;
    expect(
        () => repo
            .importSnapshot(JoySnapshot(deviceId: 'x', records: [seed, seed])),
        throwsFormatException);
    expect(repo.stateToken, original);
  });

  test('Add never silently overwrites matching identities', () {
    final task = repo.create(kind: 'item', title: 'Local', parentId: 'inbox');
    final before = repo.stateToken;
    expect(
        () => repo.importSnapshot(JoySnapshot(
            deviceId: 'x', records: [task.copyWith(title: 'Remote')])),
        throwsStateError);
    expect(repo.stateToken, before);
  });

  test('reordered JSON property names do not create an import conflict', () {
    final task =
        repo.create(kind: 'item', title: 'Read', parentId: 'inbox', data: {
      'priority': 2,
      'extra': {'a': 1, 'b': 2}
    });
    final reordered = task.copyWith(data: {
      'extra': {'b': 2, 'a': 1},
      'priority': 2,
      'order': 0
    });
    final before = repo.stateToken;
    repo.importSnapshot(JoySnapshot(deviceId: 'x', records: [reordered]));
    expect(repo.stateToken, before);
  });

  test(
      'draft conversion and project completion preserve record and action identity',
      () {
    final captured =
        repo.create(kind: 'item', title: 'Move house', parentId: 'inbox');
    final draft = repo.move(captured.id, 'projects');
    expect(draft.kind, 'project');
    expect(draft.data['draft'], isTrue);
    expect(draft.createdAt, captured.createdAt);
    final project = repo.saveProject(
        id: draft.id,
        title: draft.title,
        description: 'Relocation',
        plan: 'Pack then travel',
        criterion: 'All moved',
        actions: ['Pack', 'Book a van']);
    final actions = repo.children(project.id);
    expect(actions.map((record) => record.title), ['Pack', 'Book a van']);
    repo.saveProject(
        id: project.id,
        title: project.title,
        description: 'Relocation',
        plan: 'Revised plan',
        criterion: 'All moved',
        actions: ['Pack carefully']);
    expect(repo.children(project.id).single.id, actions.first.id);
    expect(repo.get(actions.last.id)!.isDeleted, isTrue);
    expect(repo.get(project.id)!.data['completionCriterion'], 'All moved');
  });

  test('project validation leaves Inbox unchanged', () {
    final captured =
        repo.create(kind: 'item', title: 'Move', parentId: 'inbox');
    final before = repo.stateToken;
    expect(
        () => repo.saveProject(
            id: captured.id,
            title: captured.title,
            description: '',
            plan: '',
            criterion: '',
            actions: []),
        throwsArgumentError);
    expect(repo.stateToken, before);
    expect(repo.get(captured.id)!.parentId, 'inbox');
  });

  test(
      'project action identities survive reordering and removing the first action',
      () {
    final project = repo.saveProject(
        title: 'Travel',
        description: 'Holiday',
        plan: 'Book everything',
        criterion: 'Ready',
        actions: ['Flights', 'Hotel']);
    final actions = repo.children(project.id);
    repo.saveProject(
        id: project.id,
        title: project.title,
        description: project.description,
        plan: 'Book everything',
        criterion: 'Ready',
        actions: ['Hotel', 'Flights']);
    expect(repo.children(project.id).map((record) => record.id),
        [actions[1].id, actions[0].id]);
    repo.saveProject(
        id: project.id,
        title: project.title,
        description: project.description,
        plan: 'Book everything',
        criterion: 'Ready',
        actions: ['Hotel']);
    expect(repo.children(project.id).single.id, actions[1].id);
    expect(repo.get(actions[0].id)!.isDeleted, isTrue);
  });

  test(
      'Trash timestamp is independent and purge tombstones nested project actions',
      () {
    final project = repo.saveProject(
        title: 'Project',
        description: 'Description',
        plan: 'Plan',
        criterion: 'Done',
        actions: ['First']);
    final task = repo.trash(project.id);
    final timestamp = DateTime.parse(task.data['trashedAt'] as String);
    expect(task.createdAt, project.createdAt);
    expect(repo.purgeTrash(now: timestamp.add(const Duration(days: 29))), 0);
    expect(repo.purgeTrash(now: timestamp.add(const Duration(days: 30))), 2);
    expect(repo.get(project.id)!.isDeleted, isTrue);
    expect(
        repo.all().where((record) => record.parentId == project.id), isEmpty);
    expect(repo.snapshot().records.where((record) => record.isDeleted),
        hasLength(2));
  });

  test('Trash remains required and folder restore returns it to root', () {
    expect(() => repo.trash('trash'), throwsStateError);
    final folder = repo.create(kind: 'folder', title: 'Custom');
    repo.trash(folder.id);
    expect(repo.get(folder.id)!.parentId, 'trash');
    expect(repo.restore(folder.id).parentId, isNull);
  });

  test(
      'numbers resolve identical timestamps deterministically without changing IDs',
      () {
    final now = '2026-11-08T12:00:00Z';
    final first = JoyRecord(
        id: 'b',
        kind: 'item',
        parentId: 'inbox',
        title: 'B',
        createdAt: now,
        updatedAt: now,
        revision: 'r-b');
    final second = first.copyWith(id: 'a', title: 'A', revision: 'r-a');
    repo.importSnapshot(
        JoySnapshot(deviceId: 'other', records: [first, second]));
    expect(repo.ordinalOf('a'), 1);
    expect(repo.ordinalOf('b'), 2);
    expect(repo.get('a')!.id, 'a');
    repo.trash('a');
    repo.purgeTrash(now: DateTime.now().toUtc().add(const Duration(days: 31)));
    expect(repo.ordinalOf('b'), 2);
  });

  test('stale prepared snapshot cannot overwrite a concurrent edit', () {
    final prepared = repo.snapshot();
    final token = repo.stateToken;
    repo.create(kind: 'item', title: 'Concurrent', parentId: 'inbox');
    expect(() => repo.replaceAll(prepared, expectedState: token),
        throwsStateError);
    expect(repo.inboxItems.single.title, 'Concurrent');
  });

  test('model rejects timestamps without UTC and impossible calendar dates',
      () {
    final json = repo.get('inbox')!.toJson();
    for (final date in [
      '2026-01-01',
      '2026-01-01T00:00:00',
      '2026-02-31T00:00:00Z'
    ]) {
      expect(() => JoyRecord.fromJson({...json, 'createdAt': date}),
          throwsFormatException);
    }
  });
}
