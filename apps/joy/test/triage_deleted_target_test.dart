import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/triage.dart';
import 'package:joy/l10n.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  testWidgets(
    'deleted routing targets request reconfiguration and keep the card',
    (tester) async {
      final repo = JoyRepository.memory();
      addTearDown(repo.close);
      final folder = repo.create(kind: 'folder', title: 'Old destination');
      repo.saveSettings({
        ...repo.settings.data,
        'triageMenus': {
          'root': {
            'label': 'Root',
            'bindings': {
              '6': {'type': 'destination', 'targetId': folder.id},
            },
          },
        },
      });
      final item = repo.create(
        kind: 'item',
        parentId: 'inbox',
        title: 'Keep this card',
      );
      repo.delete(folder.id);
      final controller = JoyController(repo);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TriageView(controller: controller, words: const Words('en')),
          ),
        ),
      );
      expect(find.textContaining('— · Configure controls'), findsWidgets);
      await tester.tap(find.widgetWithText(OutlinedButton, '6'));
      await tester.pumpAndSettle();
      expect(repo.get(item.id)!.parentId, 'inbox');
      expect(find.text('Bad state: Configure controls'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
