import 'dart:convert';
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  group('Workbook exchange', () {
    late JoyRepository repository;
    final codec = WorkbookCodec();

    setUp(() => repository = JoyRepository.memory(deviceId: 'workbook-device'));
    tearDown(() => repository.close());

    test('round trips folders, empty groups, ordering and extensible data', () {
      final a = repository.create(kind: 'folder', title: 'Pharmacy / Summer');
      final b = repository.create(kind: 'folder', title: 'Pharmacy : Summer');
      repository.create(
          kind: 'subfolder',
          title: 'Empty group',
          parentId: a.id,
          description: 'Keep this even when empty',
          data: {'order': 4});
      repository
          .create(kind: 'item', title: 'Buy supplies', parentId: b.id, data: {
        'duration': 15,
        'custom': {'preserve': true},
        'embedding': [0.4, 0.8]
      });
      final deleted =
          repository.create(kind: 'item', title: 'Old item', parentId: 'inbox');
      repository.trash(deleted.id);
      final original = repository.snapshot();
      final decoded = codec.decode(codec.encode(original));
      expect(decoded.toJson(), original.toJson());
      expect(
          Excel.decodeBytes(codec.encode(original))
              .tables
              .keys
              .where((name) => name.startsWith('Pharmacy')),
          hasLength(2));
    });

    test('preserves fields larger than one Excel cell without losing Unicode',
        () {
      repository.create(
          kind: 'item',
          title: 'Long note',
          parentId: 'knowledge',
          description: List.filled(20000, '🙂').join(),
          data: {'payload': List.filled(40000, 'я').join()});
      final original = repository.snapshot();
      expect(codec.decode(codec.encode(original)).toJson(), original.toJson());
    });

    test('headerless Inbox retains first row and shares one batch timestamp',
        () {
      final book = Excel.createExcel();
      final sheet = book[book.getDefaultSheet()!];
      sheet.appendRow([TextCellValue('First task')]);
      sheet.appendRow([TextCellValue('')]);
      sheet.appendRow([TextCellValue('Second task')]);
      final timestamp = DateTime.utc(2026, 11, 8, 12, 13, 14);
      final imported = codec.decodeInbox(book.encode()!, importedAt: timestamp);
      expect(imported.map((record) => record.title),
          ['First task', 'Second task']);
      expect(imported.map((record) => record.createdAt).toSet(),
          {timestamp.toIso8601String()});
      expect(imported.map((record) => record.id).toSet(), hasLength(2));
    });

    test('Inbox maps description and dates and rejects invalid source date',
        () {
      final book = Excel.createExcel();
      final sheet = book[book.getDefaultSheet()!];
      sheet.appendRow([
        TextCellValue('Title'),
        TextCellValue('Description'),
        TextCellValue('Created')
      ]);
      sheet.appendRow([
        TextCellValue('Task'),
        TextCellValue('Details'),
        TextCellValue('2026-01-02T03:04:05+03:00')
      ]);
      final imported = codec.decodeInbox(book.encode()!,
          hasHeader: true, descriptionColumn: 1, createdAtColumn: 2);
      expect(imported.single.description, 'Details');
      expect(imported.single.createdAt, '2026-01-02T00:04:05.000Z');
      sheet.appendRow([
        TextCellValue('Bad task'),
        TextCellValue(''),
        TextCellValue('not a date')
      ]);
      expect(
          () => codec.decodeInbox(book.encode()!,
              hasHeader: true, createdAtColumn: 2),
          throwsFormatException);
    });

    test('invalid full workbook and invalid hierarchy never mutate storage',
        () {
      final before = repository.stateToken;
      expect(() => codec.decode([1, 2, 3]), throwsFormatException);
      final book = Excel.decodeBytes(codec.encode(repository.snapshot()));
      final inbox = book['Inbox'];
      inbox
          .cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: 1))
          .value = TextCellValue('action');
      expect(() => codec.decode(book.encode()!), throwsFormatException);
      expect(repository.stateToken, before);
    });

    test('Inbox rejects impossible dates and treats unzoned dates as UTC', () {
      final book = Excel.createExcel();
      final sheet = book[book.getDefaultSheet()!];
      sheet.appendRow(
          [TextCellValue('Task'), TextCellValue('2026-02-28T12:30:00')]);
      expect(
          codec
              .decodeInbox(book.encode()!, createdAtColumn: 1)
              .single
              .createdAt,
          '2026-02-28T12:30:00.000Z');
      sheet.appendRow([
        TextCellValue('Impossible date'),
        TextCellValue('2026-02-31T12:30:00Z')
      ]);
      expect(() => codec.decodeInbox(book.encode()!, createdAtColumn: 1),
          throwsFormatException);
    });

    test('full import undo restores both data and folder structure', () {
      final other = JoyRepository.memory(deviceId: 'other');
      addTearDown(other.close);
      other.create(kind: 'folder', title: 'Imported folder');
      other.create(kind: 'item', title: 'Imported item', parentId: 'inbox');
      final before = repository.snapshot().toJson();
      repository.importSnapshot(codec.decode(codec.encode(other.snapshot())));
      expect(repository.inboxItems.single.title, 'Imported item');
      expect(repository.undoImport(), isTrue);
      expect(repository.snapshot().toJson(), before);
    });
  });

  group('Calendar export', () {
    test('exports UTC calendar event with valid escapes and UTF-8 folds', () {
      final record = JoyRecord(
        id: 'calendar-test',
        kind: 'item',
        parentId: 'calendar',
        title: '${List.filled(40, 'Я').join()}, meeting;',
        description: 'Line one\nLine two',
        createdAt: '2026-11-08T10:00:00.000Z',
        updatedAt: '2026-11-08T10:00:00.000Z',
        revision: 'r1',
        data: {
          'scheduledAt': '2026-11-09T12:30:00.000Z',
          'endsAt': '2026-11-09T13:30:00.000Z'
        },
      );
      final ics = CalendarExporter().exportEvents([record]);
      expect(ics, contains('DTSTART:20261109T123000Z'));
      expect(ics, contains('DTEND:20261109T133000Z'));
      expect(ics, contains(r'DESCRIPTION:Line one\nLine two'));
      expect(ics.replaceAll('\r\n ', ''), contains(r'\, meeting\;'));
      for (final line in ics.split('\r\n')) {
        expect(utf8.encode(line).length, lessThanOrEqualTo(75));
      }
    });
  });

  group('Merge planning and direct peer exchange', () {
    late JoyRepository local;
    late JoyRepository remote;

    setUp(() {
      local = JoyRepository.memory(deviceId: 'local');
      remote = JoyRepository.memory(deviceId: 'remote');
    });
    tearDown(() {
      local.close();
      remote.close();
    });

    test('independent IDs survive despite same title and creation time', () {
      final left =
          local.create(kind: 'item', title: 'Same title', parentId: 'inbox');
      final right =
          remote.create(kind: 'item', title: 'Same title', parentId: 'inbox');
      final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
      expect(plan.conflicts, isEmpty);
      final merged = plan.resolve({});
      local.replaceAll(merged);
      remote.replaceAll(merged);
      expect(local.inboxItems, hasLength(2));
      expect(local.ordinalOf(left.id), remote.ordinalOf(left.id));
      expect(local.ordinalOf(right.id), remote.ordinalOf(right.id));
      expect(local.ordinalOf(left.id), isNot(local.ordinalOf(right.id)));
    });

    test(
        'descendant edits transfer automatically but divergent edits require a choice',
        () {
      final task =
          local.create(kind: 'item', title: 'Original', parentId: 'inbox');
      remote.replaceAll(local.snapshot());
      remote.edit(task.id, title: 'Changed on remote');
      final first = mergeSnapshots(local.snapshot(), remote.snapshot());
      expect(first.conflicts, isEmpty);
      local.replaceAll(first.resolve({}));
      local.edit(task.id, title: 'Local branch');
      remote.edit(task.id, title: 'Remote branch');
      final conflict = mergeSnapshots(local.snapshot(), remote.snapshot());
      expect(conflict.conflicts.single.changedFields, contains('title'));
      expect(() => conflict.resolve({}), throwsStateError);
      final resolved = conflict.resolve({task.id: ConflictChoice.remote});
      local.replaceAll(resolved);
      remote.replaceAll(resolved);
      expect(local.get(task.id)!.title, 'Remote branch');
      expect(mergeSnapshots(local.snapshot(), remote.snapshot()).conflicts,
          isEmpty);
    });

    test('delete versus edit is a conflict, never a title-based replacement',
        () {
      final task =
          local.create(kind: 'item', title: 'Original', parentId: 'inbox');
      remote.replaceAll(local.snapshot());
      local.trash(task.id);
      remote.edit(task.id, description: 'New text on remote');
      final plan = mergeSnapshots(local.snapshot(), remote.snapshot());
      expect(plan.conflicts.single.id, task.id);
      expect(plan.conflicts.single.changedFields,
          containsAll(['parentId', 'description']));
      final resolved = plan.resolve({task.id: ConflictChoice.remote});
      expect(resolved.records.firstWhere((r) => r.id == task.id).parentId,
          'inbox');
    });

    test('same revision with different content is rejected', () {
      final task =
          local.create(kind: 'item', title: 'Original', parentId: 'inbox');
      final altered = JoySnapshot(
          deviceId: 'remote',
          records: local
              .snapshot()
              .records
              .map((r) =>
                  r.id == task.id ? r.copyWith(title: 'Invalid edit') : r)
              .toList());
      expect(() => mergeSnapshots(local.snapshot(), altered),
          throwsFormatException);
    });

    test(
        'two live HTTP peers converge and repeated exchange creates no duplicates',
        () async {
      local.create(kind: 'item', title: 'From local', parentId: 'inbox');
      remote.create(kind: 'item', title: 'From remote', parentId: 'inbox');
      final server = await PeerServer.start(remote,
          address: '127.0.0.1', pairingCode: '123456');
      addTearDown(server.close);
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final session =
          await PeerClient().preview(uri, server.pairingCode, local.snapshot());
      await session.commit(local, {});
      expect(local.inboxItems, hasLength(2));
      expect(remote.inboxItems, hasLength(2));
      final repeated =
          await PeerClient().preview(uri, server.pairingCode, local.snapshot());
      expect(repeated.plan.conflicts, isEmpty);
      await repeated.commit(local, {});
      expect(local.inboxItems, hasLength(2));
      expect(local.snapshot().records.map((r) => r.toJson()),
          remote.snapshot().records.map((r) => r.toJson()));
    });

    test('wrong pairing code cannot read snapshots or mutate data', () async {
      final server = await PeerServer.start(remote,
          address: '127.0.0.1', pairingCode: '123456');
      addTearDown(server.close);
      final before = remote.stateToken;
      await expectLater(
          PeerClient().preview(Uri.parse('http://127.0.0.1:${server.port}'),
              'wrong', local.snapshot()),
          throwsStateError);
      expect(remote.stateToken, before);
    });

    test(
        'remote changes after preview reject commit without losing either side',
        () async {
      local.create(kind: 'item', title: 'Local task', parentId: 'inbox');
      final server = await PeerServer.start(remote,
          address: '127.0.0.1', pairingCode: '123456');
      addTearDown(server.close);
      final session = await PeerClient().preview(
          Uri.parse('http://127.0.0.1:${server.port}'),
          '123456',
          local.snapshot());
      remote.create(
          kind: 'item', title: 'New during preview', parentId: 'inbox');
      await expectLater(session.commit(local, {}), throwsStateError);
      expect(local.inboxItems.single.title, 'Local task');
      expect(remote.inboxItems.single.title, 'New during preview');
    });

    test('local changes after preview reject before sending a commit',
        () async {
      final server = await PeerServer.start(remote,
          address: '127.0.0.1', pairingCode: '123456');
      addTearDown(server.close);
      final before = remote.stateToken;
      final session = await PeerClient().preview(
          Uri.parse('http://127.0.0.1:${server.port}'),
          '123456',
          local.snapshot());
      local.create(kind: 'item', title: 'New local task', parentId: 'inbox');
      await expectLater(session.commit(local, {}), throwsStateError);
      expect(remote.stateToken, before);
      expect(local.inboxItems.single.title, 'New local task');
    });

    test('failed connection leaves local state intact', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final before = local.stateToken;
      await expectLater(
          PeerClient().preview(
              Uri.parse('http://127.0.0.1:$port'), '123456', local.snapshot()),
          throwsA(isA<SocketException>()));
      expect(local.stateToken, before);
    });
  });
}
