import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  test('expired Trash clears payload but keeps deletion history and numbering',
      () {
    final local = JoyRepository.memory();
    final peer = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(peer.close);
    final item = local.create(
      kind: 'item',
      parentId: 'inbox',
      title: 'Expired note',
      description: 'The content should no longer be retained',
      data: {
        'embedding': {
          'vector': [1.0, 0.5]
        },
        'custom': 'old value'
      },
    );
    peer.replaceAll(local.snapshot());
    final ordinal = local.ordinalOf(item.id);
    final trashed = local.trash(item.id);
    final entered = DateTime.parse(trashed.data['trashedAt'] as String);
    expect(local.purgeTrash(now: entered.add(const Duration(days: 31))), 1);
    final tombstone = local.get(item.id)!;
    expect(tombstone.title, isEmpty);
    expect(tombstone.description, isEmpty);
    expect(tombstone.data, isEmpty);
    expect(tombstone.id, item.id);
    expect(tombstone.kind, item.kind);
    expect(tombstone.createdAt, item.createdAt);
    expect(tombstone.isDeleted, isTrue);
    expect(tombstone.ancestors, contains(trashed.revision));
    expect(local.ordinalOf(item.id), ordinal);
    final plan = mergeSnapshots(local.snapshot(), peer.snapshot());
    expect(plan.conflicts, isEmpty);
    expect(
        plan.resolve({}).records.singleWhere((r) => r.id == item.id).isDeleted,
        isTrue);
  });

  test('expired folder clears payload of the complete subtree', () {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    final folder = repo.create(kind: 'folder', title: 'Temporary folder');
    final section = repo.create(
        kind: 'subfolder', title: 'Temporary section', parentId: folder.id);
    final item = repo.create(
        kind: 'item',
        title: 'Temporary item',
        parentId: section.id,
        data: {'priority': 'high'});
    final trashed = repo.trash(folder.id);
    final entered = DateTime.parse(trashed.data['trashedAt'] as String);
    expect(repo.purgeTrash(now: entered.add(const Duration(days: 31))), 3);
    for (final id in [folder.id, section.id, item.id]) {
      final removed = repo.get(id)!;
      expect(removed.isDeleted, isTrue);
      expect(removed.title, isEmpty);
      expect(removed.description, isEmpty);
      expect(removed.data, isEmpty);
    }
    JoyRepository.validateSnapshot(repo.snapshot());
  });

  test('stale import preview cannot replace newer local edits', () {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    final old = repo.snapshot();
    final expected = repo.stateToken;
    repo.create(
        kind: 'item', title: 'Changed after preview', parentId: 'inbox');
    final current = repo.snapshot().toJson();
    expect(
        () => repo.importSnapshot(old, replace: true, expectedState: expected),
        throwsStateError);
    expect(repo.snapshot().toJson(), current);
    expect(repo.canUndoImport, isFalse);
  });
}
