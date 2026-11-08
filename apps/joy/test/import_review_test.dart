import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/exchange.dart';
import 'package:joy/l10n.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  test(
    'an unknown portable locale uses English without losing the setting',
    () {
      final repository = JoyRepository.memory();
      addTearDown(repository.close);
      repository.saveSettings({
        ...repository.settings.data,
        'locale': 'unknown-locale',
      });
      final controller = JoyController(repository);
      addTearDown(controller.dispose);
      expect(controller.locale, 'en');
      expect(repository.settings.data['locale'], 'unknown-locale');
    },
  );

  testWidgets('Replace preview names the scope, file and before-after counts', (
    tester,
  ) async {
    final current = JoyRepository.memory();
    final incoming = JoyRepository.memory();
    addTearDown(current.close);
    addTearDown(incoming.close);
    current.create(kind: 'item', parentId: 'inbox', title: 'Old task');
    current.create(kind: 'item', parentId: 'shopping', title: 'Old purchase');
    incoming.create(kind: 'item', parentId: 'inbox', title: 'Imported task');
    final before = current.stateToken;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImportReviewDialog(
            words: const Words('en'),
            fileName: 'backup.xlsx',
            current: current.snapshot(),
            incoming: incoming.snapshot(),
          ),
        ),
      ),
    );
    expect(find.text('Import system from XLSX'), findsOneWidget);
    expect(find.text('backup.xlsx'), findsOneWidget);
    expect(find.text('items: 2 → 1'), findsOneWidget);
    expect(current.stateToken, before);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImportReviewDialog(
            words: const Words('en'),
            fileName: 'inbox.xlsx',
            current: current.snapshot(),
            incoming: incoming.snapshot(),
            inboxOnly: true,
          ),
        ),
      ),
    );
    expect(find.text('Import Inbox from XLSX'), findsOneWidget);
    expect(find.text('items: 1 → 1'), findsOneWidget);
    expect(current.stateToken, before);
    expect(tester.takeException(), isNull);
  });
}
