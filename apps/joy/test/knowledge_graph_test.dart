import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy_core/joy_core.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/knowledge_graph.dart';
import 'package:joy/l10n.dart';

void main() {
  testWidgets('knowledge and contacts work without a model or vectors', (
    tester,
  ) async {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    repo.create(kind: 'item', parentId: 'knowledge', title: 'Garage address');
    repo.create(kind: 'item', parentId: 'contacts', title: 'Grigory');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: KnowledgeGraph(
                controller: JoyController(repo),
                words: const Words('en'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Knowledge graph'), findsOneWidget);
    expect(find.text('Knowledge'), findsOneWidget);
    expect(find.text('Contacts'), findsOneWidget);
    expect(find.text(const Words('en')['noVectors']), findsOneWidget);
    expect(repo.all().where((r) => r.kind == 'item').length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached graph is visible offline and text edits invalidate it', (
    tester,
  ) async {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    final record = repo.create(
      kind: 'item',
      parentId: 'knowledge',
      title: 'Garage address',
      data: {
        'embedding': {
          'modelId': 'test-model',
          'revision': 'test-revision',
          'vector': [1, 0],
          'textHash': 'test-hash',
          'sourceText': 'Garage address\n',
          'x': 0,
          'y': 0,
          'neighbors': [],
        },
      },
    );
    final controller = JoyController(repo);
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: KnowledgeGraph(
                controller: controller,
                words: const Words('en'),
              ),
            ),
          ),
        ),
      ),
    );
    await show();
    expect(find.text(const Words('en')['noVectors']), findsNothing);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    repo.edit(record.id, title: 'New garage address');
    controller.refresh();
    await show();
    expect(find.text(const Words('en')['noVectors']), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('different model revisions are not projected together', (
    tester,
  ) async {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    for (final entry in [
      ('knowledge', 'Address', 'v1'),
      ('contacts', 'Mechanic', 'v2'),
    ]) {
      repo.create(
        kind: 'item',
        parentId: entry.$1,
        title: entry.$2,
        data: {
          'embedding': {
            'modelId': 'test-model',
            'revision': entry.$3,
            'vector': [1, 0],
            'sourceText': '${entry.$2}\n',
            'textHash': 'test',
            'x': 0,
            'y': 0,
            'neighbors': [],
          },
        },
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KnowledgeGraph(
            controller: JoyController(repo),
            words: const Words('en'),
          ),
        ),
      ),
    );
    expect(find.byType(InteractiveViewer), findsNothing);
    expect(find.text(const Words('en')['modelMismatch']), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
