import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy_core/joy_core.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/knowledge_graph.dart';
import 'package:joy/l10n.dart';

class _LocalNetwork extends HttpOverrides {}

void main() {
  final address = Platform.environment['JOY_TEST_EMBEDDINGS_URL'];
  testWidgets(
    'real local model populates the graph and survives workbook restore',
    (tester) async {
      final repository = JoyRepository.memory();
      addTearDown(repository.close);
      repository.saveSettings({
        ...repository.settings.data,
        'embeddingUrl': address,
      });
      final garage = repository.create(
        kind: 'item',
        parentId: 'knowledge',
        title: 'Адрес гаража',
        description: 'Ремонт автомобиля на Лесной улице.',
      );
      repository.create(
        kind: 'item',
        parentId: 'contacts',
        title: 'Григорий — гаражный мастер',
        description: 'Ремонтирует автомобили в гараже на Лесной улице.',
      );
      repository.create(
        kind: 'item',
        parentId: 'knowledge',
        title: 'Рецепт шоколадного торта',
      );
      final controller = JoyController(repository);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KnowledgeGraph(
              controller: controller,
              words: const Words('en'),
            ),
          ),
        ),
      );
      final dynamic state = tester.state(find.byType(KnowledgeGraph));
      await tester.runAsync(() async {
        await HttpOverrides.runZoned(
          () => state.calculate(),
          createHttpClient: (context) =>
              _LocalNetwork().createHttpClient(context),
        );
      });
      await tester.pumpAndSettle();
      final embedding = repository.get(garage.id)!.data['embedding'] as Map?;
      expect(embedding, isNotNull, reason: state.failure as String?);
      expect((embedding!['vector'] as List).length, 384);
      expect(embedding['x'], isA<num>());
      expect(embedding['modelId'], contains('multilingual'));
      expect(find.byType(InteractiveViewer), findsOneWidget);
      final book = WorkbookCodec().encode(repository.snapshot());
      final restored = JoyRepository.memory();
      addTearDown(restored.close);
      restored.importSnapshot(WorkbookCodec().decode(book), replace: true);
      expect(restored.get(garage.id)!.data['embedding'], embedding);
      expect(tester.takeException(), isNull);
    },
    skip: address == null,
  );
}
