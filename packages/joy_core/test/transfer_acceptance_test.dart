import 'package:excel/excel.dart';
import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  test(
      'one workbook restores colliding sheet names, empty groups and large metadata',
      () {
    final source = JoyRepository.memory(deviceId: 'source');
    final target = JoyRepository.memory(deviceId: 'target');
    addTearDown(source.close);
    addTearDown(target.close);
    final first = source.create(kind: 'folder', title: 'X' * 40);
    final second = source.create(kind: 'folder', title: '${'X' * 40}:?[]');
    source.create(
        kind: 'subfolder', title: 'Empty / pharmacy', parentId: first.id);
    final nested = source.create(
        kind: 'subfolder', title: 'Marketplace', parentId: second.id);
    final description = '${'a' * 29999}🧭${'б' * 35000}';
    source.create(
      kind: 'item',
      parentId: nested.id,
      title: '=SUM(1,2) — literal text',
      description: description,
      data: {
        'embedding': {
          'modelId': 'qa-model',
          'revision': 'qa-revision',
          'vector': List<double>.generate(10000, (i) => i / 10000),
          'sourceText': description,
          'textHash': 'source-hash',
        },
      },
    );
    source.saveSettings(
        {...source.settings.data, 'locale': 'sr', 'trashDays': 7});
    final codec = WorkbookCodec();
    final bytes = codec.encode(source.snapshot());
    final excel = Excel.decodeBytes(bytes);
    expect(excel.tables.length, source.folders.length + 1);
    expect(excel.tables.keys.map((name) => name.toLowerCase()).toSet().length,
        excel.tables.length);
    expect(excel.tables.keys.every((name) => name.length <= 31), isTrue);
    final restored = codec.decode(bytes);
    target.importSnapshot(restored, replace: true);
    expect(target.snapshot().records.map((r) => r.toJson()).toList(),
        source.snapshot().records.map((r) => r.toJson()).toList());
    expect(target.get(nested.id)?.parentId, second.id);
  });

  test('headerless Inbox import preserves first row and one batch timestamp',
      () {
    final book = Excel.createExcel();
    final sheet = book[book.getDefaultSheet()!];
    sheet.appendRow([TextCellValue('Первая задача')]);
    sheet.appendRow([TextCellValue('')]);
    sheet.appendRow([TextCellValue('Deuxième tâche')]);
    sheet.appendRow([TextCellValue('Трећи задатак')]);
    final importedAt = DateTime.utc(2026, 11, 8, 13, 42, 5);
    final rows =
        WorkbookCodec().decodeInbox(book.encode()!, importedAt: importedAt);
    expect(rows.map((r) => r.title),
        ['Первая задача', 'Deuxième tâche', 'Трећи задатак']);
    expect(
        rows.map((r) => r.createdAt).toSet(), {importedAt.toIso8601String()});
    expect(rows.map((r) => r.id).toSet().length, 3);
  });

  test('Inbox column mapping keeps descriptions and source creation times', () {
    final book = Excel.createExcel();
    final sheet = book[book.getDefaultSheet()!];
    sheet.appendRow([
      TextCellValue('Task'),
      TextCellValue('Description'),
      TextCellValue('Created')
    ]);
    sheet.appendRow([
      TextCellValue('One'),
      TextCellValue('Extra details'),
      TextCellValue('2025-02-03T04:05:06Z')
    ]);
    sheet.appendRow(
        [TextCellValue('Two'), TextCellValue(''), TextCellValue('')]);
    final importedAt = DateTime.utc(2026, 11, 8);
    final rows = WorkbookCodec().decodeInbox(
      book.encode()!,
      hasHeader: true,
      descriptionColumn: 1,
      createdAtColumn: 2,
      importedAt: importedAt,
    );
    expect(rows[0].description, 'Extra details');
    expect(
        DateTime.parse(rows[0].createdAt), DateTime.utc(2025, 2, 3, 4, 5, 6));
    expect(rows[1].createdAt, importedAt.toIso8601String());
  });

  test(
      'Calendar export is outbound UTC with escaped text and folded UTF-8 lines',
      () {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    final event = repo.create(
      kind: 'item',
      parentId: 'calendar',
      title: 'Гараж, мастер; запись ${'д' * 100}',
      description: 'Line one\nLine two\\literal',
      data: {'scheduledAt': '2026-11-08T12:30:00.000Z'},
    );
    final text = CalendarExporter().exportEvents([event]);
    expect(text, contains('DTSTART:20261108T123000Z\r\n'));
    expect(text, contains('DTEND:20261108T133000Z\r\n'));
    expect(text, contains(r'Гараж\, мастер\;'));
    expect(text, contains(r'DESCRIPTION:Line one\nLine two\\literal'));
    expect(text.split('BEGIN:VEVENT').length - 1, 1);
    expect(text.endsWith('END:VCALENDAR\r\n'), isTrue);
  });

  test(
      'merge keeps both independent tasks and resolves one-sided edit through history',
      () {
    final local = JoyRepository.memory(deviceId: 'local');
    final remote = JoyRepository.memory(deviceId: 'remote');
    addTearDown(local.close);
    addTearDown(remote.close);
    final common =
        local.create(kind: 'item', parentId: 'inbox', title: 'Common');
    remote.replaceAll(local.snapshot());
    local.create(kind: 'item', parentId: 'inbox', title: 'Local new');
    remote.create(kind: 'item', parentId: 'inbox', title: 'Remote new');
    remote.edit(common.id, title: 'Changed remotely');
    final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
    expect(plan.conflicts, isEmpty);
    final merged = plan.resolve({});
    local.replaceAll(merged);
    expect(local.inboxItems.map((r) => r.title),
        containsAll(['Changed remotely', 'Local new', 'Remote new']));
    expect(
        mergeSnapshots(local.snapshot(), remote.snapshot()).conflicts, isEmpty);
  });

  test(
      'divergent edit requires explicit choice and resolution joins both histories',
      () {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final common =
        local.create(kind: 'item', parentId: 'inbox', title: 'Common');
    remote.replaceAll(local.snapshot());
    final left = local.edit(common.id, title: 'My version');
    final right = remote.edit(common.id, description: 'Remote details');
    final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
    expect(plan.conflicts.single.id, common.id);
    expect(plan.conflicts.single.changedFields,
        containsAll(['title', 'description']));
    expect(() => plan.resolve({}), throwsStateError);
    final result = plan.resolve({common.id: ConflictChoice.remote});
    final selected = result.records.singleWhere((r) => r.id == common.id);
    expect(selected.description, 'Remote details');
    expect(selected.ancestors, containsAll([left.revision, right.revision]));
    expect(selected.revision, isNot(anyOf(left.revision, right.revision)));
    expect(mergeSnapshots(result, local.snapshot()).conflicts, isEmpty);
    expect(mergeSnapshots(result, remote.snapshot()).conflicts, isEmpty);
  });

  test('delete/edit conflict cannot silently resurrect a task', () {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final common =
        local.create(kind: 'item', parentId: 'inbox', title: 'Common');
    remote.replaceAll(local.snapshot());
    local.delete(common.id);
    remote.edit(common.id, title: 'Edited on phone');
    final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
    expect(plan.conflicts.single.changedFields, contains('deletedAt'));
    final result = plan.resolve({common.id: ConflictChoice.local});
    local.replaceAll(result);
    expect(local.inboxItems, isEmpty);
    expect(local.get(common.id)?.deletedAt, isNotNull);
    expect(
        mergeSnapshots(local.snapshot(), remote.snapshot()).conflicts, isEmpty);
  });

  test('different content with identical revision is rejected as invalid', () {
    final repo = JoyRepository.memory();
    addTearDown(repo.close);
    final item =
        repo.create(kind: 'item', parentId: 'inbox', title: 'Original');
    final local = repo.snapshot();
    final remote = JoySnapshot(
        deviceId: 'remote',
        records: local.records
            .map((r) => r.id == item.id
                ? r.copyWith(title: 'Changed without revision')
                : r)
            .toList());
    expect(() => mergeSnapshots(local, remote), throwsFormatException);
  });

  test(
      'parent deletion exposes independent children and blocks the unsafe choice',
      () {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final folder = local.create(kind: 'folder', title: 'Shared folder');
    remote.replaceAll(local.snapshot());
    final independent = local.create(
        kind: 'item', parentId: folder.id, title: 'New task on computer');
    remote.delete(folder.id);
    final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
    final conflict = plan.conflicts.singleWhere((c) => c.id == folder.id);
    expect(
        conflict.dependentChildren.map((r) => r.id), contains(independent.id));
    expect(conflict.blockedChoice, ConflictChoice.remote);
    expect(() => plan.resolve({folder.id: ConflictChoice.remote}),
        throwsStateError);
    final kept = plan.resolve({folder.id: ConflictChoice.local});
    local.replaceAll(kept);
    expect(local.get(independent.id)?.parentId, folder.id);
    expect(local.get(folder.id)?.isDeleted, isFalse);
  });

  test(
      'Replace from XLSX does not resurrect removed tasks on the next peer exchange',
      () {
    final local = JoyRepository.memory();
    final stalePeer = JoyRepository.memory();
    final replacement = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(stalePeer.close);
    addTearDown(replacement.close);
    final removed = local.create(
        kind: 'item', parentId: 'inbox', title: 'Removed by replacement');
    stalePeer.replaceAll(local.snapshot());
    replacement.create(
        kind: 'item', parentId: 'inbox', title: 'Keep from restored workbook');
    final codec = WorkbookCodec();
    local.importSnapshot(codec.decode(codec.encode(replacement.snapshot())),
        replace: true);
    final plan = mergeSnapshots(local.snapshot(), stalePeer.snapshot());
    expect(plan.conflicts, isEmpty);
    final afterExchange = plan.resolve({});
    expect(afterExchange.records.any((r) => r.id == removed.id && !r.isDeleted),
        isFalse);
    expect(
        afterExchange.records
            .where((r) => r.kind == 'item' && !r.isDeleted)
            .map((r) => r.title),
        ['Keep from restored workbook']);
  });

  test(
      'deliberate older restore supersedes known revision but not unseen peer edits',
      () {
    final local = JoyRepository.memory();
    final peer = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(peer.close);
    final item = local.create(
        kind: 'item', parentId: 'inbox', title: 'Original backup text');
    final codec = WorkbookCodec();
    final backup = codec.encode(local.snapshot());
    local.edit(item.id, title: 'Known current text');
    peer.replaceAll(local.snapshot());
    local.importSnapshot(codec.decode(backup), replace: true);
    expect(local.get(item.id)?.title, 'Original backup text');
    expect(
        mergeSnapshots(local.snapshot(), peer.snapshot()).conflicts, isEmpty);
    final result =
        mergeSnapshots(local.snapshot(), peer.snapshot()).resolve({});
    expect(result.records.singleWhere((r) => r.id == item.id).title,
        'Original backup text');
    peer.edit(item.id, title: 'Unseen phone edit');
    final conflict = mergeSnapshots(local.snapshot(), peer.snapshot());
    expect(conflict.conflicts.map((c) => c.id), contains(item.id));
  });
}
