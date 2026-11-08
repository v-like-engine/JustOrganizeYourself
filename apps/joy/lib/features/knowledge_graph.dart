import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:joy_core/joy_core.dart';
import '../controller.dart';
import '../l10n.dart';

class KnowledgeGraph extends StatefulWidget {
  final JoyController controller;
  final Words words;

  const KnowledgeGraph({
    super.key,
    required this.controller,
    required this.words,
  });

  @override
  State<KnowledgeGraph> createState() => _KnowledgeGraphState();
}

class _KnowledgeGraphState extends State<KnowledgeGraph> {
  bool busy = false;
  String? failure;
  String? selectedId;

  List<JoyRecord> get entries => widget.controller.records
      .where(
        (r) =>
            ['item', 'project'].contains(r.kind) &&
            (widget.controller.isWithin(r.parentId, 'knowledge') ||
                widget.controller.isWithin(r.parentId, 'contacts')),
      )
      .toList();

  String textOf(JoyRecord record) => '${record.title}\n${record.description}';

  Map<String, dynamic>? embeddingOf(JoyRecord record) {
    final value = record.data['embedding'];
    if (value is! Map || value['sourceText'] != textOf(record)) return null;
    return Map<String, dynamic>.from(value);
  }

  Future<Map<String, dynamic>> request(
    String path,
    Map<String, dynamic> body,
  ) async {
    final address =
        widget.controller.settings['embeddingUrl'] as String? ??
        'http://127.0.0.1:8766';
    final base = Uri.parse(address);
    if (!['http', 'https'].contains(base.scheme) || base.host.isEmpty) {
      throw const FormatException(
        'Use an HTTP address for the local embedding service.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final call = await client
          .postUrl(base.resolve(path))
          .timeout(const Duration(seconds: 15));
      call.headers.contentType = ContentType.json;
      call.write(jsonEncode(body));
      final response = await call.close().timeout(const Duration(minutes: 2));
      final payload =
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw HttpException(
          payload['detail']?.toString() ??
              'The local service could not calculate embeddings.',
        );
      }
      return payload;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> calculate() async {
    final source = entries;
    if (source.isEmpty) return;
    if (source.length > 1000) {
      setState(() => failure = widget.words['graphTooLarge']);
      return;
    }
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      final vectors = <String, Map<String, dynamic>>{};
      String? modelKey;
      for (var from = 0; from < source.length; from += 64) {
        final batch = source.sublist(from, math.min(from + 64, source.length));
        final response = await request('/v1/embed', {
          'entries': batch.map((r) => {'id': r.id, 'text': textOf(r)}).toList(),
        });
        final model = Map<String, dynamic>.from(response['model'] as Map);
        final key = '${model['id']}@${model['revision']}';
        if (modelKey != null && modelKey != key) {
          throw const FormatException(
            'The embedding model changed during calculation. Please retry.',
          );
        }
        modelKey = key;
        final batchVectors = response['embeddings'] as List;
        if (batchVectors.length != batch.length)
          throw const FormatException('Incomplete embedding response.');
        for (final item in batchVectors) {
          final value = Map<String, dynamic>.from(item as Map);
          final id = value['id'] as String;
          final record = batch.where((r) => r.id == id).firstOrNull;
          final vector = value['vector'];
          if (record == null ||
              vectors.containsKey(id) ||
              vector is! List ||
              vector.length != model['dimensions'] ||
              vector.any((n) => n is! num || !n.isFinite)) {
            throw const FormatException('Invalid embedding response.');
          }
          vectors[id] = {
            'modelId': model['id'],
            'revision': model['revision'],
            'vector': vector,
            'textHash': value['textHash'],
            'sourceText': textOf(record),
          };
        }
      }
      final graph = await request('/v1/graph', {
        'nodes': source
            .map(
              (r) => {
                'id': r.id,
                'kind': widget.controller.isWithin(r.parentId, 'contacts')
                    ? 'contact'
                    : 'knowledge',
                'title': r.title,
                'vector': vectors[r.id]!['vector'],
              },
            )
            .toList(),
      });
      final positions = <String, Map<String, dynamic>>{};
      for (final node in graph['nodes'] as List) {
        final data = Map<String, dynamic>.from(node as Map);
        if (data['x'] is! num ||
            data['y'] is! num ||
            !(data['x'] as num).isFinite ||
            !(data['y'] as num).isFinite) {
          throw const FormatException('Invalid graph coordinates.');
        }
        positions[data['id'] as String] = data;
      }
      if (positions.length != source.length ||
          source.any((r) => !positions.containsKey(r.id))) {
        throw const FormatException('Incomplete graph response.');
      }
      for (final original in source) {
        final current = widget.controller.repository.get(original.id);
        if (current == null ||
            current.deletedAt != null ||
            current.revision != original.revision) {
          throw const FormatException(
            'Entries changed during calculation. Please retry.',
          );
        }
      }
      final edges = graph['edges'] as List;
      for (final record in source) {
        widget.controller.repository.edit(
          record.id,
          data: {
            ...record.data,
            'embedding': {
              ...vectors[record.id]!,
              'x': positions[record.id]!['x'],
              'y': positions[record.id]!['y'],
              'neighbors': edges
                  .where(
                    (e) => e['source'] == record.id || e['target'] == record.id,
                  )
                  .map(
                    (e) => {
                      'id': e['source'] == record.id
                          ? e['target']
                          : e['source'],
                      'similarity': e['similarity'],
                    },
                  )
                  .toList(),
            },
          },
        );
      }
      widget.controller.refresh();
    } catch (error) {
      if (mounted) setState(() => failure = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final words = widget.words;
    final source = entries;
    final candidates = source
        .where(
          (r) => embeddingOf(r)?['x'] is num && embeddingOf(r)?['y'] is num,
        )
        .toList();
    final models = candidates.map((r) {
      final embedding = embeddingOf(r)!;
      return '${embedding['modelId']}@${embedding['revision']}';
    }).toSet();
    final ready = models.length > 1 ? <JoyRecord>[] : candidates;
    final selected = source.where((r) => r.id == selectedId).firstOrNull;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              Text(
                words['graph'],
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              FilledButton.icon(
                onPressed: busy || source.isEmpty ? null : calculate,
                icon: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.hub_outlined),
                label: Text(words['calculate']),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(words['graphHelp']),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _Legend(
                color: const Color(0xff237b72),
                label: words['knowledge'],
              ),
              _Legend(color: const Color(0xffc1842c), label: words['contacts']),
            ],
          ),
          if (failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                failure!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 420,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ColoredBox(
                color: const Color(0xffedf2ed),
                child: ready.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            words[models.length > 1
                                ? 'modelMismatch'
                                : 'noVectors'],
                            textAlign: TextAlign.center,
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, bounds) {
                          final size = Size(
                            math.max(bounds.maxWidth, 720),
                            420,
                          );
                          final points = _layoutPoints(ready, size);
                          return InteractiveViewer(
                            constrained: false,
                            minScale: 0.5,
                            maxScale: 3,
                            child: GestureDetector(
                              onTapUp: (tap) {
                                final hit = ready
                                    .where(
                                      (r) =>
                                          (points[r.id]! - tap.localPosition)
                                              .distance <
                                          24,
                                    )
                                    .firstOrNull;
                                setState(() => selectedId = hit?.id);
                              },
                              child: Semantics(
                                label:
                                    '${words['graph']}: ${ready.length} ${words['count']}',
                                child: CustomPaint(
                                  size: size,
                                  painter: _GraphPainter(
                                    ready,
                                    points,
                                    selectedId,
                                    (r) => widget.controller.isWithin(
                                      r.parentId,
                                      'contacts',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.title,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (selected.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(selected.description),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Offset _point(JoyRecord record, Size size) {
  final vector = record.data['embedding'] as Map;
  return Offset(
    80 + ((vector['x'] as num).toDouble() + 1) / 2 * (size.width - 160),
    50 + ((vector['y'] as num).toDouble() + 1) / 2 * (size.height - 100),
  );
}

Map<String, Offset> _layoutPoints(List<JoyRecord> records, Size size) {
  final points = {
    for (final record in records) record.id: _point(record, size),
  };
  final ids = points.keys.toList()..sort();
  for (var pass = 0; pass < 6; pass++) {
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final delta = points[ids[j]]! - points[ids[i]]!;
        final distance = delta.distance;
        if (distance >= 28) continue;
        final direction = distance < 0.001
            ? Offset(math.cos(i + j.toDouble()), math.sin(i + j.toDouble()))
            : delta / distance;
        final move = direction * ((28 - distance) / 2);
        final first = points[ids[i]]! - move;
        final second = points[ids[j]]! + move;
        points[ids[i]] = Offset(
          first.dx.clamp(20, size.width - 20),
          first.dy.clamp(20, size.height - 40),
        );
        points[ids[j]] = Offset(
          second.dx.clamp(20, size.width - 20),
          second.dy.clamp(20, size.height - 40),
        );
      }
    }
  }
  return points;
}

class _GraphPainter extends CustomPainter {
  final List<JoyRecord> records;
  final Map<String, Offset> points;
  final String? selected;
  final bool Function(JoyRecord) isContact;

  _GraphPainter(this.records, this.points, this.selected, this.isContact);

  @override
  void paint(Canvas canvas, Size size) {
    final byId = {for (final record in records) record.id: record};
    final edgePaint = Paint()
      ..color = const Color(0xffb9cbc5)
      ..strokeWidth = 1.5;
    for (final record in records) {
      final embedding = record.data['embedding'] as Map;
      for (final link in (embedding['neighbors'] as List? ?? [])) {
        final other = byId[link['id']];
        if (other == null || record.id.compareTo(other.id) >= 0) continue;
        final otherEmbedding = other.data['embedding'] as Map;
        if (embedding['modelId'] != otherEmbedding['modelId'] ||
            embedding['revision'] != otherEmbedding['revision'])
          continue;
        canvas.drawLine(points[record.id]!, points[other.id]!, edgePaint);
      }
    }
    final labels = <Rect>[];
    final paintOrder = [...records]
      ..sort(
        (a, b) => a.id == selected
            ? -1
            : b.id == selected
            ? 1
            : a.id.compareTo(b.id),
      );
    for (final record in paintOrder) {
      final point = points[record.id]!;
      final color = isContact(record)
          ? const Color(0xffc1842c)
          : const Color(0xff237b72);
      if (record.id == selected)
        canvas.drawCircle(
          point,
          16,
          Paint()..color = color.withValues(alpha: 0.2),
        );
      canvas.drawCircle(point, 9, Paint()..color = color);
      final label = TextPainter(
        text: TextSpan(
          text: record.title,
          style: const TextStyle(color: Color(0xff203a34), fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: 130);
      final origin = Offset(
        (point.dx - label.width / 2).clamp(0, size.width - label.width),
        point.dy + 16,
      );
      final box = origin & label.size;
      if (!labels.any((other) => other.inflate(3).overlaps(box))) {
        label.paint(canvas, origin);
        labels.add(box);
      }
    }
  }

  @override
  bool shouldRepaint(_GraphPainter oldDelegate) => true;
}

class _Legend extends StatelessWidget {
  final Color color;
  final String label;

  const _Legend({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(Icons.circle, color: color, size: 12),
      const SizedBox(width: 8),
      Text(label),
    ],
  );
}
