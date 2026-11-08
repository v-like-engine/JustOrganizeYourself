import 'dart:io';

import 'package:joy_core/joy_core.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln('Usage: dart run bin/peer.dart <database.sqlite> [port]');
    exitCode = 64;
    return;
  }
  final port = args.length == 2 ? int.tryParse(args[1]) : 0;
  if (port == null || port < 0 || port > 65535) {
    stderr.writeln('Port must be between 0 and 65535');
    exitCode = 64;
    return;
  }
  final repository = JoyRepository.open(path: args[0]);
  final server = await PeerServer.start(repository, port: port);
  stdout.writeln('Peer receiver listening on port ${server.port}');
  stdout.writeln('Pairing code: ${server.pairingCode}');
  for (final interface
      in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final address in interface.addresses) {
      stdout
          .writeln('Device address: http://${address.address}:${server.port}');
    }
  }
  await ProcessSignal.sigint.watch().first;
  await server.close();
  repository.close();
}
