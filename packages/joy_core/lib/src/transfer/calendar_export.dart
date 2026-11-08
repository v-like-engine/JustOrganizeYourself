import 'dart:convert';

import '../domain/models.dart';

class CalendarExporter {
  String exportEvents(List<JoyRecord> records) {
    final lines = <String>[
      'BEGIN:VCALENDAR',
      'VERSION:2.0',
      'PRODID:-//Just Organize Yourself//Calendar//EN',
      'CALSCALE:GREGORIAN',
      'METHOD:PUBLISH',
    ];
    for (final record in records.where((r) => r.deletedAt == null)) {
      final startValue = record.data['scheduledAt'];
      if (startValue == null) continue;
      final start = _eventTime(startValue, record.title);
      final endValue = record.data['endsAt'];
      final end = endValue == null
          ? start.add(const Duration(hours: 1))
          : _eventTime(endValue, record.title);
      if (!end.isAfter(start))
        throw FormatException('Invalid event end: ${record.title}');
      lines.addAll([
        'BEGIN:VEVENT',
        'UID:${_escape(record.id)}@justorganizeyourself',
        'DTSTAMP:${_time(DateTime.parse(record.updatedAt))}',
        'DTSTART:${_time(start)}',
        'DTEND:${_time(end)}',
        'SUMMARY:${_escape(record.title)}',
        'DESCRIPTION:${_escape(record.description)}',
        'END:VEVENT',
      ]);
    }
    lines.add('END:VCALENDAR');
    return '${lines.map(_fold).join('\r\n')}\r\n';
  }

  String _time(DateTime date) {
    final d = date.toUtc();
    String pad(int n) => n.toString().padLeft(2, '0');
    return '${d.year.toString().padLeft(4, '0')}${pad(d.month)}${pad(d.day)}T${pad(d.hour)}${pad(d.minute)}${pad(d.second)}Z';
  }

  DateTime _eventTime(Object value, String title) {
    final text = value.toString();
    final date = DateTime.tryParse(text);
    final parts = RegExp(
            r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$')
        .firstMatch(text);
    if (date == null || parts == null) {
      throw FormatException('Invalid event time or timezone: $title');
    }
    final values = List.generate(6, (i) => int.parse(parts.group(i + 1)!));
    final check = DateTime.utc(
        values[0], values[1], values[2], values[3], values[4], values[5]);
    if ([
      check.year,
      check.month,
      check.day,
      check.hour,
      check.minute,
      check.second
    ].asMap().entries.any((e) => e.value != values[e.key])) {
      throw FormatException('Invalid event time: $title');
    }
    return date.toUtc();
  }

  String _escape(String value) => value
      .replaceAll('\\', '\\\\')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll('\n', r'\n')
      .replaceAll(';', r'\;')
      .replaceAll(',', r'\,');

  String _fold(String line) {
    final chunks = <String>[];
    var current = StringBuffer();
    var length = 0;
    for (final rune in line.runes) {
      final char = String.fromCharCode(rune);
      final bytes = utf8.encode(char).length;
      if (length + bytes > 75) {
        chunks.add(current.toString());
        current = StringBuffer(' ');
        length = 1;
      }
      current.write(char);
      length += bytes;
    }
    chunks.add(current.toString());
    return chunks.join('\r\n');
  }
}
