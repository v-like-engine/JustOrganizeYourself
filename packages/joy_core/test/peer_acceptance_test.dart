import 'package:joy_core/joy_core.dart';
import 'package:test/test.dart';

void main() {
  test(
      'two real loopback peers retain independent changes and retry idempotently',
      () async {
    final computer = JoyRepository.memory(deviceId: 'computer');
    final phone = JoyRepository.memory(deviceId: 'phone');
    addTearDown(computer.close);
    addTearDown(phone.close);
    computer.create(kind: 'item', parentId: 'inbox', title: 'Computer task');
    phone.create(kind: 'item', parentId: 'inbox', title: 'Phone task');
    final server = await PeerServer.start(phone,
        address: '127.0.0.1', pairingCode: '123456');
    addTearDown(server.close);
    final address = Uri.parse('http://127.0.0.1:${server.port}');
    final session =
        await PeerClient().preview(address, '123456', computer.snapshot());
    expect(session.plan.conflicts, isEmpty);
    await session.commit(computer, {});
    expect(computer.inboxItems.map((r) => r.title),
        containsAll(['Computer task', 'Phone task']));
    expect(phone.inboxItems.map((r) => r.id).toSet(),
        computer.inboxItems.map((r) => r.id).toSet());
    expect(phone.snapshot().deviceId, 'phone');
    expect(computer.snapshot().deviceId, 'computer');
    final repeat =
        await PeerClient().preview(address, '123456', computer.snapshot());
    await repeat.commit(computer, {});
    expect(computer.inboxItems.length, 2);
    expect(phone.inboxItems.length, 2);
  });

  test('wrong pairing code does not expose or change data', () async {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final server = await PeerServer.start(remote,
        address: '127.0.0.1', pairingCode: '123456');
    addTearDown(server.close);
    final before = remote.snapshot().toJson();
    await expectLater(
      PeerClient().preview(Uri.parse('http://127.0.0.1:${server.port}'),
          '654321', local.snapshot()),
      throwsStateError,
    );
    expect(remote.snapshot().toJson(), before);
  });

  test(
      'remote change after preview rejects stale result without losing new data',
      () async {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final server = await PeerServer.start(remote,
        address: '127.0.0.1', pairingCode: '123456');
    addTearDown(server.close);
    final session = await PeerClient().preview(
        Uri.parse('http://127.0.0.1:${server.port}'),
        '123456',
        local.snapshot());
    final newTask = remote.create(
        kind: 'item', parentId: 'inbox', title: 'Created after preview');
    final before = local.snapshot().toJson();
    await expectLater(session.commit(local, {}), throwsStateError);
    expect(local.snapshot().toJson(), before);
    expect(remote.get(newTask.id)?.title, 'Created after preview');
  });

  test(
      'local change after preview rejects stale result without claiming success',
      () async {
    final local = JoyRepository.memory();
    final remote = JoyRepository.memory();
    addTearDown(local.close);
    addTearDown(remote.close);
    final server = await PeerServer.start(remote,
        address: '127.0.0.1', pairingCode: '123456');
    addTearDown(server.close);
    final session = await PeerClient().preview(
        Uri.parse('http://127.0.0.1:${server.port}'),
        '123456',
        local.snapshot());
    final newTask = local.create(
        kind: 'item', parentId: 'inbox', title: 'Changed after preview');
    final before = remote.snapshot().toJson();
    await expectLater(session.commit(local, {}), throwsStateError);
    expect(remote.snapshot().toJson(), before);
    expect(local.get(newTask.id)?.title, 'Changed after preview');
  });
}
