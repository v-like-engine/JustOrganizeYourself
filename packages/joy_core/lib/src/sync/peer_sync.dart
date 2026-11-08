import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../domain/models.dart';
import '../storage/repository.dart';

enum ConflictChoice { local, remote }

class MergeConflict {
  final String id;
  final JoyRecord local;
  final JoyRecord remote;
  final List<String> changedFields;
  final List<JoyRecord> dependentChildren;
  final ConflictChoice? blockedChoice;

  MergeConflict(
    this.local,
    this.remote, {
    List<JoyRecord> dependentChildren = const [],
    this.blockedChoice,
  })  : id = local.id,
        dependentChildren = List.unmodifiable(dependentChildren),
        changedFields = _changes(local.toJson(), remote.toJson());
}

class MergePlan {
  final JoySnapshot local;
  final JoySnapshot remote;
  final List<MergeConflict> conflicts;
  final Map<String, JoyRecord> _merged;

  MergePlan._(this.local, this.remote, this._merged, this.conflicts);

  JoySnapshot resolve(Map<String, ConflictChoice> choices) {
    final records = Map<String, JoyRecord>.from(_merged);
    const uuid = Uuid();
    for (final conflict in conflicts) {
      final choice = choices[conflict.id];
      if (choice == null)
        throw StateError('Choose a version for ${conflict.local.title}');
      if (choice == conflict.blockedChoice) {
        throw StateError(
            'Keep ${conflict.local.title}, or move its live tasks before synchronizing. Deleting it would orphan ${conflict.dependentChildren.map((r) => r.title).join(', ')}.');
      }
      final selected =
          choice == ConflictChoice.local ? conflict.local : conflict.remote;
      records[conflict.id] = selected.copyWith(
        revision: uuid.v4(),
        ancestors: {
          ...conflict.local.ancestors,
          conflict.local.revision,
          ...conflict.remote.ancestors,
          conflict.remote.revision,
        }.toList()
          ..sort(),
        updatedAt: DateTime.now().toUtc().toIso8601String(),
      );
    }
    final result = records.values.toList()..sort(_recordOrder);
    final snapshot = JoySnapshot(deviceId: local.deviceId, records: result);
    JoyRepository.validateSnapshot(snapshot);
    return snapshot;
  }

  JoySnapshot resolved(Map<String, ConflictChoice> choices) => resolve(choices);
}

MergePlan mergeSnapshots(JoySnapshot local, JoySnapshot remote) {
  JoyRepository.validateSnapshot(local);
  JoyRepository.validateSnapshot(remote);
  final merged = {for (final record in local.records) record.id: record};
  final conflicts = <MergeConflict>[];
  for (final incoming in remote.records) {
    final current = merged[incoming.id];
    if (current == null) {
      merged[incoming.id] = incoming;
    } else if (_canonical(current.toJson()) == _canonical(incoming.toJson())) {
      continue;
    } else if (current.revision == incoming.revision) {
      throw FormatException(
          'Different contents share one revision: ${current.title}');
    } else if (current.ancestors.contains(incoming.revision)) {
      continue;
    } else if (incoming.ancestors.contains(current.revision)) {
      merged[incoming.id] = incoming;
    } else {
      conflicts.add(MergeConflict(current, incoming));
    }
  }
  final localById = {for (final record in local.records) record.id: record};
  final remoteById = {for (final record in remote.records) record.id: record};
  final dependents = <String, List<JoyRecord>>{};
  for (final child in merged.values.where((record) => !record.isDeleted)) {
    if (child.parentId == null) continue;
    final left = localById[child.parentId];
    final right = remoteById[child.parentId];
    if (left != null && right != null && left.isDeleted != right.isDeleted) {
      (dependents[left.id] ??= []).add(child);
    }
  }
  for (final entry in dependents.entries) {
    final left = localById[entry.key]!;
    final right = remoteById[entry.key]!;
    final conflict = MergeConflict(
      left,
      right,
      dependentChildren: entry.value,
      blockedChoice:
          left.isDeleted ? ConflictChoice.local : ConflictChoice.remote,
    );
    final index = conflicts.indexWhere((c) => c.id == entry.key);
    if (index == -1) {
      conflicts.add(conflict);
    } else {
      conflicts[index] = conflict;
    }
  }
  return MergePlan._(local, remote, merged, List.unmodifiable(conflicts));
}

class PeerServer {
  final JoyRepository _repository;
  final HttpServer _server;
  final String pairingCode;
  final Map<String, _Prepared> _prepared = {};
  final Map<String, String> _committed = {};
  bool _closed = false;

  PeerServer._(this._repository, this._server, this.pairingCode) {
    _server.listen(_handle);
  }

  static Future<PeerServer> start(
    JoyRepository repository, {
    String address = '0.0.0.0',
    int port = 0,
    String? pairingCode,
  }) async {
    if (pairingCode != null && pairingCode.trim().isEmpty) {
      throw ArgumentError('Pairing code cannot be empty');
    }
    final server = await HttpServer.bind(address, port);
    final code =
        pairingCode ?? (100000 + Random.secure().nextInt(900000)).toString();
    return PeerServer._(repository, server, code);
  }

  int get port => _server.port;
  String get code => pairingCode;
  InternetAddress get address => _server.address;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _prepared.clear();
    _committed.clear();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.headers.value('x-joy-code') != pairingCode) {
        await _reply(request, HttpStatus.unauthorized,
            {'error': 'Pairing code does not match'});
        return;
      }
      _prepared
          .removeWhere((_, value) => value.expires.isBefore(DateTime.now()));
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/v1/info') {
        await _reply(request, HttpStatus.ok, {
          'apiVersion': 1,
          'deviceId': _repository.deviceId,
          'stateToken': _repository.stateToken,
        });
      } else if (request.method == 'GET' && path == '/v1/snapshot') {
        await _reply(request, HttpStatus.ok, {
          'snapshot': _repository.snapshot().toJson(),
          'stateToken': _repository.stateToken,
        });
      } else if (request.method == 'POST' && path == '/v1/prepare') {
        final body = await _readJson(request);
        final expected = body['expectedState'];
        if (expected is! String || expected != _repository.stateToken) {
          await _reply(request, HttpStatus.conflict,
              {'error': 'Remote data changed. Preview again.'});
          return;
        }
        final snapshot = JoySnapshot.fromJson(
            Map<String, dynamic>.from(body['snapshot'] as Map));
        JoyRepository.validateSnapshot(snapshot);
        const uuid = Uuid();
        final token = uuid.v4();
        _prepared[token] = _Prepared(
            snapshot, expected, DateTime.now().add(const Duration(minutes: 5)));
        await _reply(request, HttpStatus.ok, {'token': token});
      } else if (request.method == 'POST' && path == '/v1/commit') {
        final body = await _readJson(request);
        final token = body['token'];
        if (token is! String)
          throw const FormatException('Missing commit token');
        final committedState = _committed[token];
        if (committedState != null) {
          if (_repository.stateToken != committedState) {
            await _reply(request, HttpStatus.conflict,
                {'error': 'Remote data changed after commit'});
          } else {
            await _reply(request, HttpStatus.ok,
                {'committed': true, 'stateToken': committedState});
          }
          return;
        }
        final prepared = _prepared.remove(token);
        if (prepared == null) {
          await _reply(request, HttpStatus.conflict,
              {'error': 'Synchronization preview expired. Preview again.'});
          return;
        }
        _repository.replaceAll(prepared.snapshot,
            expectedState: prepared.expectedState);
        final state = _repository.stateToken;
        _committed[token] = state;
        if (_committed.length > 64) _committed.remove(_committed.keys.first);
        await _reply(
            request, HttpStatus.ok, {'committed': true, 'stateToken': state});
      } else {
        await _reply(
            request, HttpStatus.notFound, {'error': 'Unknown sync operation'});
      }
    } on StateError catch (error) {
      await _reply(request, HttpStatus.conflict, {'error': error.message});
    } on FormatException catch (error) {
      await _reply(request, HttpStatus.badRequest, {'error': error.message});
    } on Object {
      await _reply(request, HttpStatus.badRequest,
          {'error': 'Invalid synchronization request'});
    }
  }

  Future<void> _reply(
      HttpRequest request, int status, Map<String, dynamic> payload) async {
    try {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('cache-control', 'no-store');
      request.response.write(jsonEncode(payload));
      await request.response.close();
    } on SocketException {
      return;
    } on HttpException {
      return;
    }
  }
}

class PeerClient {
  Future<RemoteSyncSession> preview(
      Uri endpoint, String pairingCode, JoySnapshot local) async {
    final remote = await _request(endpoint, pairingCode, 'GET', '/v1/snapshot');
    final snapshot = JoySnapshot.fromJson(
        Map<String, dynamic>.from(remote['snapshot'] as Map));
    if (remote['stateToken'] is! String)
      throw const FormatException('Missing remote state');
    return RemoteSyncSession._(
      endpoint,
      pairingCode,
      mergeSnapshots(local, snapshot),
      remote['stateToken'] as String,
      _snapshotToken(local),
    );
  }
}

class RemoteSyncSession {
  final Uri endpoint;
  final String _pairingCode;
  final MergePlan plan;
  final String _expectedRemote;
  final String _expectedLocal;
  bool _completed = false;

  RemoteSyncSession._(this.endpoint, this._pairingCode, this.plan,
      this._expectedRemote, this._expectedLocal);

  Future<void> commit(
      JoyRepository repository, Map<String, ConflictChoice> choices) async {
    if (_completed) return;
    if (repository.stateToken != _expectedLocal) {
      throw StateError('Local data changed. Preview again.');
    }
    final snapshot = plan.resolve(choices);
    final prepared =
        await _request(endpoint, _pairingCode, 'POST', '/v1/prepare', {
      'expectedState': _expectedRemote,
      'snapshot': snapshot.toJson(),
    });
    if (repository.stateToken != _expectedLocal) {
      throw StateError('Local data changed. Preview again.');
    }
    final response = await _request(endpoint, _pairingCode, 'POST',
        '/v1/commit', {'token': prepared['token']});
    if (response['committed'] != true)
      throw StateError('Remote device did not confirm synchronization');
    try {
      repository.replaceAll(snapshot, expectedState: _expectedLocal);
    } on StateError {
      throw StateError(
          'Remote device saved the merge, but local data changed. Synchronize again to finish safely.');
    }
    _completed = true;
  }
}

class _Prepared {
  final JoySnapshot snapshot;
  final String expectedState;
  final DateTime expires;
  _Prepared(this.snapshot, this.expectedState, this.expires);
}

Future<Map<String, dynamic>> _request(
    Uri endpoint, String code, String method, String path,
    [Map<String, dynamic>? payload]) async {
  if (!['http', 'https'].contains(endpoint.scheme) ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty) {
    throw const FormatException(
        'Enter an HTTP device address, including its port');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final uri = endpoint.replace(path: path, query: '', fragment: '');
    final request =
        await client.openUrl(method, uri).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    request.headers.set('x-joy-code', code);
    request.headers.contentType = ContentType.json;
    if (payload != null) request.write(jsonEncode(payload));
    final response = await request.close().timeout(const Duration(seconds: 30));
    final result =
        await _readJson(response).timeout(const Duration(seconds: 30));
    if (response.statusCode != HttpStatus.ok) {
      throw StateError(result['error']?.toString() ??
          'Device request failed (${response.statusCode})');
    }
    return result;
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> _readJson(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final part in stream) {
    if (bytes.length + part.length > 64 * 1024 * 1024)
      throw const FormatException('Synchronization payload is too large');
    bytes.addAll(part);
  }
  final data = jsonDecode(utf8.decode(bytes));
  if (data is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(data);
}

String _snapshotToken(JoySnapshot snapshot) =>
    sha256.convert(utf8.encode(_canonical(snapshot.toJson()))).toString();

String _canonical(dynamic value) {
  dynamic sorted(dynamic entry) {
    if (entry is Map) {
      final keys = entry.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(entry[key])};
    }
    if (entry is List) return entry.map(sorted).toList();
    return entry;
  }

  return jsonEncode(sorted(value));
}

int _recordOrder(JoyRecord a, JoyRecord b) {
  final created =
      DateTime.parse(a.createdAt).compareTo(DateTime.parse(b.createdAt));
  return created == 0 ? a.id.compareTo(b.id) : created;
}

List<String> _changes(Map<String, dynamic> local, Map<String, dynamic> remote,
    [String prefix = '']) {
  final fields = <String>[];
  for (final key in {...local.keys, ...remote.keys}) {
    if (['revision', 'ancestors', 'updatedAt'].contains(key) && prefix.isEmpty)
      continue;
    final path = prefix.isEmpty ? key : '$prefix.$key';
    final left = local[key];
    final right = remote[key];
    if (left is Map && right is Map) {
      fields.addAll(_changes(Map<String, dynamic>.from(left),
          Map<String, dynamic>.from(right), path));
    } else if (_canonical(left) != _canonical(right)) {
      fields.add(path);
    }
  }
  return fields;
}
