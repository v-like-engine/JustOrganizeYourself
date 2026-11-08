import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/controller.dart';
import 'package:joy/features/editors.dart';
import 'package:joy/features/triage.dart';
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

  final directions = <String, Offset>{
    '7': const Offset(-100, -100),
    '8': const Offset(0, -100),
    '9': const Offset(100, -100),
    '4': const Offset(-100, 0),
    '6': const Offset(100, 0),
    '1': const Offset(-100, 100),
    '2': const Offset(0, 100),
    '3': const Offset(100, 100),
  };
  for (final direction in directions.entries) {
    testWidgets(
      'swipe ${direction.key} files exactly one card to its configured destination',
      (tester) async {
        final destinations = {
          for (final key in directions.keys)
            key: repo.create(kind: 'folder', title: 'Destination $key').id,
        };
        repo.saveSettings({
          ...repo.settings.data,
          'triageMenus': {
            'root': {
              'label': 'Root',
              'bindings': {
                for (final entry in destinations.entries)
                  entry.key: {'type': 'destination', 'targetId': entry.value},
                '5': {'type': 'details'},
              },
            },
          },
        });
        final item = repo.create(
          kind: 'item',
          parentId: 'inbox',
          title: 'Swipe this card',
        );
        controller.refresh();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListenableBuilder(
                listenable: controller,
                builder: (context, child) => TriageView(
                  controller: controller,
                  words: const Words('en'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.drag(find.byType(Card).first, direction.value);
        await tester.pumpAndSettle();
        expect(repo.get(item.id)?.parentId, destinations[direction.key]);
        expect(repo.inboxItems, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'folder editor remains usable on a phone with the keyboard open',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () =>
                      editFolder(context, controller, const Words('en')),
                  child: const Text('Open folder'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextFormField).first, 'Phone folder');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(repo.folders.map((r) => r.title), contains('Phone folder'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'canceling a project form does not move or mutate its Inbox source',
    (tester) async {
      final item = repo.create(
        kind: 'item',
        parentId: 'inbox',
        title: 'Source thought',
      );
      final before = repo.snapshot().toJson();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () => editProject(
                    context,
                    controller,
                    const Words('en'),
                    record: item,
                    parentId: 'projects',
                  ),
                  child: const Text('Open project'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open project'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'Edited but canceled',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(repo.snapshot().toJson(), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'project editor with more than three actions fits a small viewport',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final project = repo.saveProject(
        title: 'Project',
        description: 'Description',
        plan: 'Plan',
        completionCriterion: 'Done',
        actions: ['One', 'Two', 'Three', 'Four', 'Five'],
      );
      controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                return TextButton(
                  onPressed: () => editProject(
                    context,
                    controller,
                    const Words('en'),
                    record: project,
                  ),
                  child: const Text('Open project'),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open project'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(
        repo
            .children(project.id)
            .where((r) => r.kind == 'action')
            .map((r) => r.title),
        ['One', 'Two', 'Three', 'Four', 'Five'],
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('triage shows one card and submenu entry does not file it', (
    tester,
  ) async {
    repo.create(kind: 'item', parentId: 'inbox', title: 'Visible first card');
    repo.create(kind: 'item', parentId: 'inbox', title: 'Hidden second card');
    controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (context, child) =>
                TriageView(controller: controller, words: const Words('en')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Visible first card'), findsOneWidget);
    expect(find.text('Hidden second card'), findsNothing);
    await tester.tap(find.text('6'));
    await tester.pumpAndSettle();
    expect(repo.inboxItems.length, 2);
    expect(find.text('Visible first card'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad7);
    await tester.pumpAndSettle();
    expect(repo.inboxItems.length, 1);
    expect(
      repo.children('someday').map((r) => r.title),
      contains('Visible first card'),
    );
    expect(find.text('Hidden second card'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('center tap can edit and numpad does not file a card while typing', (tester) async {
    repo.saveSettings({
      ...repo.settings.data,
      'triageMenus': {
        'root': {
          'label': 'Root',
          'bindings': {
            '5': {'type': 'edit'},
            '2': {'type': 'destination', 'targetId': 'trash'},
          },
        },
      },
    });
    final item = repo.create(kind: 'item', parentId: 'inbox', title: 'Edit this card');
    controller.refresh();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListenableBuilder(
      listenable: controller,
      builder: (context, child) => TriageView(controller: controller, words: const Words('en')),
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Card).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Edited task 42');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
    await tester.pumpAndSettle();
    expect(repo.get(item.id)?.parentId, 'inbox');
    expect(find.byType(TextFormField), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repo.get(item.id)?.title, 'Edited task 42');
    expect(repo.get(item.id)?.parentId, 'inbox');
    expect(tester.takeException(), isNull);
  });
}
