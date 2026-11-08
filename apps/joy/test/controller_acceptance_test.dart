import 'package:flutter_test/flutter_test.dart';
import 'package:joy/controller.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  late JoyRepository repo;
  late JoyController controller;

  setUp(() {
    repo = JoyRepository.memory();
    controller = JoyController(repo);
  });

  tearDown(() {
    controller.dispose();
    repo.close();
  });

  test('similar-item hints handle the requested Russian word forms', () {
    final item = repo.create(
      kind: 'item',
      parentId: 'shopping',
      title: 'Кончилась сметана, надо купить',
    );
    repo.create(kind: 'item', parentId: 'inbox', title: 'Позвонить врачу');
    controller.refresh();
    final before = repo.snapshot().toJson();
    expect(
      controller.suggestions('купить сметану').map((r) => r.id),
      contains(item.id),
    );
    expect(
      controller.suggestions('купить').map((r) => r.id),
      contains(item.id),
    );
    expect(controller.suggestions('совершенно другая тема'), isEmpty);
    expect(repo.snapshot().toJson(), before);
  });

  test(
    'suggestions exclude discarded records and do not mutate the draft source',
    () {
      final discarded = repo.create(
        kind: 'item',
        parentId: 'inbox',
        title: 'Buy apples',
      );
      repo.trash(discarded.id);
      repo.create(kind: 'item', parentId: 'inbox', title: 'Buy bread');
      controller.refresh();
      expect(controller.suggestions('Buy').map((r) => r.title), ['Buy bread']);
      expect(
        repo.all(includeDeleted: true).where((r) => r.kind == 'item').length,
        2,
      );
    },
  );

  test(
    'deferred projects keep their identity and remain queued until completed',
    () {
      final first = repo.create(
        kind: 'item',
        parentId: 'inbox',
        title: 'First project',
      );
      final second = repo.create(
        kind: 'item',
        parentId: 'inbox',
        title: 'Second project',
      );
      repo.move(first.id, 'projects');
      repo.move(second.id, 'projects');
      controller.refresh();
      expect(
        controller.projectDrafts.map((r) => r.id),
        containsAll([first.id, second.id]),
      );
      expect(controller.inbox, isEmpty);
      repo.saveProject(
        id: first.id,
        title: 'First project',
        description: 'Description',
        plan: 'Free form plan',
        completionCriterion: 'Observable outcome',
        actions: ['First action'],
      );
      controller.refresh();
      expect(controller.projectDrafts.map((r) => r.id), [second.id]);
      expect(repo.get(first.id)?.createdAt, first.createdAt);
    },
  );

  test('trashed folders are absent from active navigation', () {
    final folder = repo.create(kind: 'folder', title: 'Temporary');
    repo.trash(folder.id);
    controller.refresh();
    expect(controller.folders.map((r) => r.id), isNot(contains(folder.id)));
  });

  test(
    'remaining workload uses exact low counts and the stated upper bands',
    () {
      final expected = {
        0: '0',
        1: '1',
        10: '10',
        11: '>10',
        20: '>10',
        21: '>20',
        50: '>20',
        51: '>50',
        100: '>50',
        101: '>100',
        200: '>100',
        201: '>200',
        500: '>200',
        501: '>500',
      };
      for (final entry in expected.entries) {
        expect(
          remainingLabel(entry.key),
          entry.value,
          reason: '${entry.key} remaining',
        );
      }
    },
  );
}
