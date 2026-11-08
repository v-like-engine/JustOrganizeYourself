import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/features/exchange.dart';
import 'package:joy/l10n.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  testWidgets('conflict versions show paths and bounded embedding metadata', (tester) async {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final folder = local.create(kind: 'subfolder', parentId: 'shopping', title: 'Pharmacy');
    final item = local.create(kind: 'item', parentId: folder.id, title: 'Buy supplies');
    remote.replaceAll(local.snapshot());
    local.edit(item.id, description: 'Local details', data: {
      'embedding': {'modelId': 'local-model', 'revision': 'v1', 'vector': List.filled(384, 12345.6789)},
    });
    remote.edit(item.id, description: 'Remote details');
    final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConflictDialog(plan: plan, words: const Words('en')))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Shopping Lists / Pharmacy'), findsWidgets);
    expect(find.textContaining('local-model / v1 · 384'), findsOneWidget);
    expect(find.textContaining('12345.6789'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
