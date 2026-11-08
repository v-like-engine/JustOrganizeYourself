import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/app.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/exchange.dart';
import 'package:joy/l10n.dart';
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

  for (final locale in languageNames.keys) {
    testWidgets('Inbox stays usable in $locale on a phone with keyboard', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      repo.saveSettings({...repo.settings.data, 'locale': locale});
      for (var i = 0; i < 20; i++) {
        repo.create(kind: 'item', parentId: 'inbox', title: 'Existing item $i');
      }
      controller.refresh();
      await tester.pumpWidget(JoyApp(controller: controller));
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('inbox-composer'));
      expect(composer, findsOneWidget);
      await tester.enterText(composer, 'Fresh captured task');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final beforeScroll = tester.getRect(composer);
      expect(beforeScroll.top, greaterThan(0));
      expect(beforeScroll.bottom, lessThanOrEqualTo(360));
      await tester.drag(
        find.byKey(const ValueKey('inbox-items')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(composer).top, beforeScroll.top);
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        repo.inboxItems.where((r) => r.title == 'Fresh captured task').length,
        1,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop Enter and send button each create exactly one task', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(JoyApp(controller: controller));
    await tester.pumpAndSettle();
    final composer = find.byKey(const ValueKey('inbox-composer'));
    await tester.enterText(composer, 'Sent with Enter');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.inboxItems.map((r) => r.title), ['Sent with Enter']);
    await tester.enterText(composer, 'Sent with arrow');
    await tester.tap(find.byTooltip('Add to Inbox'));
    await tester.pumpAndSettle();
    expect(
      repo.inboxItems.map((r) => r.title),
      containsAll(['Sent with Enter', 'Sent with arrow']),
    );
    expect(repo.inboxItems.length, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'choosing an existing suggestion only discards the unsaved draft',
    (tester) async {
      final existing = repo.create(
        kind: 'item',
        parentId: 'shopping',
        title: 'Buy apples',
      );
      controller.refresh();
      await tester.pumpWidget(JoyApp(controller: controller));
      await tester.pumpAndSettle();
      final composer = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(composer, 'Buy apple');
      await tester.pumpAndSettle();
      expect(find.text('Buy apples'), findsOneWidget);
      await tester.tap(find.text('Buy apples'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller?.text, '');
      expect(repo.get(existing.id)?.toJson(), existing.toJson());
      expect(repo.inboxItems, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Inbox import defaults to Add with no-header first-column input',
    (tester) async {
      ImportOptions? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () async {
                    chosen = await showDialog<ImportOptions>(
                      context: context,
                      builder: (_) => const ImportDialog(
                        words: Words('en'),
                        inboxOnly: true,
                      ),
                    );
                  },
                  child: const Text('Open import'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open import'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Import system from XLSX'),
      );
      await tester.pumpAndSettle();
      expect(chosen?.replace, isFalse);
      expect(chosen?.header, isFalse);
      expect(chosen?.titleColumn, 0);
      expect(chosen?.descriptionColumn, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
