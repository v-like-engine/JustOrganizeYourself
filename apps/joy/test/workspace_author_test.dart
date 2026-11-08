import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/app.dart';
import 'package:joy/controller.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  late JoyRepository repository;
  late JoyController controller;

  setUp(() {
    repository = JoyRepository.memory(deviceId: 'ui-test');
    controller = JoyController(repository);
  });

  tearDown(() {
    controller.dispose();
    repository.close();
  });

  testWidgets('capture sends one durable record from the keyboard', (tester) async {
    await tester.pumpWidget(JoyApp(controller: controller));
    await tester.enterText(find.byKey(const ValueKey('inbox-composer')), 'Prepare weekend list');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();
    expect(repository.inboxItems.map((r) => r.title), ['Prepare weekend list']);
    expect(find.text('Prepare weekend list'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('choosing a word-form hint clears only the unsaved draft', (tester) async {
    final original = repository.create(kind: 'item', parentId: 'shopping', title: 'кончилась сметана, надо купить');
    controller.refresh();
    await tester.pumpWidget(JoyApp(controller: controller));
    await tester.enterText(find.byKey(const ValueKey('inbox-composer')), 'купить сметану');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.history), findsOneWidget);
    await tester.tap(find.ancestor(of: find.byIcon(Icons.history), matching: find.byType(ListTile)).first);
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byKey(const ValueKey('inbox-composer')));
    expect(field.controller!.text, isEmpty);
    expect(repository.inboxItems, isEmpty);
    expect(repository.get(original.id)!.title, original.title);
    expect(repository.get(original.id)!.parentId, 'shopping');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('small phone keeps capture reachable while keyboard is open', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    for (var i = 0; i < 12; i++) {
      repository.create(kind: 'item', parentId: 'inbox', title: 'Task $i');
    }
    controller.refresh();
    await tester.pumpWidget(JoyApp(controller: controller));
    await tester.enterText(find.byKey(const ValueKey('inbox-composer')), 'Another task');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(const ValueKey('inbox-composer'))).bottom, lessThan(360));
    await tester.tap(find.byTooltip('Add to Inbox'));
    await tester.pumpAndSettle();
    expect(repository.inboxItems.length, 13);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('numpad routes the active card to configured destination', (tester) async {
    final record = repository.create(kind: 'item', parentId: 'inbox', title: 'Discard this thought');
    controller.processing = true;
    controller.refresh();
    await tester.pumpWidget(JoyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
    await tester.pumpAndSettle();
    expect(repository.get(record.id)!.parentId, 'trash');
    expect(repository.inboxItems, isEmpty);
    expect(find.text('Inbox clear'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
