import 'package:flutter/foundation.dart';
import 'package:joy_core/joy_core.dart';

class JoyController extends ChangeNotifier {
  final JoyRepository repository;
  late JoySnapshot state;
  String folderId = 'inbox';
  String? subfolderId;
  bool processing = false;

  JoyController(this.repository) {
    state = repository.snapshot();
  }

  Map<String, dynamic> get settings => repository.settings.data;
  String get locale {
    final value = settings['locale'];
    return const {'en', 'ru', 'fr', 'es', 'de', 'sr'}.contains(value)
        ? value as String
        : 'en';
  }

  List<JoyRecord> get records =>
      state.records.where((r) => r.deletedAt == null).toList();
  List<JoyRecord> get folders =>
      ordered(records.where((r) => r.kind == 'folder' && r.parentId == null));
  JoyRecord? get selectedFolder => repository.get(folderId);
  String get destination => subfolderId ?? folderId;
  List<JoyRecord> get subfolders => ordered(
    records.where((r) => r.kind == 'subfolder' && r.parentId == folderId),
  );
  List<JoyRecord> get items => ordered(
    records.where(
      (r) =>
          r.parentId == destination &&
          (r.kind == 'item' || r.kind == 'project'),
    ),
  );
  List<JoyRecord> get inbox => ordered(
    records.where(
      (r) => r.parentId == 'inbox' && (r.kind == 'item' || r.kind == 'project'),
    ),
  );
  List<JoyRecord> get projectDrafts => records
      .where(
        (r) =>
            r.kind == 'project' &&
            r.data['draft'] == true &&
            !isWithin(r.parentId, 'trash'),
      )
      .toList();

  List<JoyRecord> ordered(Iterable<JoyRecord> values) {
    final result = values.toList();
    result.sort((a, b) {
      final order = ((a.data['order'] as num?) ?? 0).compareTo(
        (b.data['order'] as num?) ?? 0,
      );
      if (order != 0) return order;
      final date = a.createdAt.compareTo(b.createdAt);
      return date == 0 ? a.id.compareTo(b.id) : date;
    });
    return result;
  }

  void refresh() {
    state = repository.snapshot();
    if (repository.get(folderId)?.deletedAt != null ||
        repository.get(folderId)?.parentId != null ||
        repository.get(folderId) == null) {
      folderId = 'inbox';
      subfolderId = null;
    }
    notifyListeners();
  }

  void select(String id, {String? child}) {
    folderId = id;
    subfolderId = child;
    processing = false;
    notifyListeners();
  }

  void capture(String title, [String description = '']) {
    if (title.trim().isEmpty) return;
    repository.create(
      kind: 'item',
      parentId: 'inbox',
      title: title.trim(),
      description: description.trim(),
    );
    refresh();
  }

  void saveSettings(Map<String, dynamic> changes) {
    repository.saveSettings({...settings, ...changes});
    refresh();
  }

  void reorder(JoyRecord record, int offset) {
    final siblings = ordered(
      records.where(
        (r) => r.parentId == record.parentId && r.kind == record.kind,
      ),
    );
    final from = siblings.indexWhere((r) => r.id == record.id);
    final to = from + offset;
    if (to < 0 || to >= siblings.length) return;
    siblings.removeAt(from);
    siblings.insert(to, record);
    for (var i = 0; i < siblings.length; i++) {
      repository.edit(siblings[i].id, data: {...siblings[i].data, 'order': i});
    }
    refresh();
  }

  bool isWithin(String? parentId, String ancestor) {
    final seen = <String>{};
    while (parentId != null && seen.add(parentId)) {
      if (parentId == ancestor) return true;
      parentId = repository.get(parentId)?.parentId;
    }
    return false;
  }

  List<JoyRecord> suggestions(String query) {
    final terms = _terms(query);
    if (terms.isEmpty) return [];
    final ranked = <(JoyRecord, double)>[];
    for (final record in records) {
      if (!['item', 'project'].contains(record.kind) ||
          isWithin(record.parentId, 'trash'))
        continue;
      final tokens = _terms(record.title);
      final hits = terms
          .where(
            (term) =>
                tokens.any((token) => token == term || token.startsWith(term)),
          )
          .length;
      final exact = record.title.toLowerCase().contains(
        query.trim().toLowerCase(),
      );
      if (exact || hits >= (terms.length / 2).ceil()) {
        ranked.add((record, (exact ? 2 : 0) + hits / terms.length));
      }
    }
    ranked.sort((a, b) => b.$2.compareTo(a.$2));
    return ranked.map((e) => e.$1).toList();
  }

  Set<String> _terms(String text) {
    final words = RegExp(
      r'[a-zа-яёà-ÿčćšžđ0-9]+',
      unicode: true,
    ).allMatches(text.toLowerCase());
    return words
        .map((m) {
          var word = m.group(0)!;
          if (RegExp(r'[а-яё]').hasMatch(word) && word.length > 4) {
            word = word.replaceFirst(
              RegExp(
                r'(иями|ями|ами|ого|ему|ому|ими|ыми|ать|ить|ять|ов|ев|ам|ям|ах|ях|ой|ий|ый|ая|ое|ые|ую|юю|а|у|ы|и|е|я|ю|о)$',
              ),
              '',
            );
          } else if (word.length > 4) {
            word = word.replaceFirst(RegExp(r'(ing|es|s)$'), '');
          }
          return word;
        })
        .where((s) => s.isNotEmpty)
        .toSet();
  }
}

String remainingLabel(int count) {
  if (count <= 10) return '$count';
  for (final limit in [500, 200, 100, 50, 20, 10]) {
    if (count > limit) return '>$limit';
  }
  return '$count';
}
