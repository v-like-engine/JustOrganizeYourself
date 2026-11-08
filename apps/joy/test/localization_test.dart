import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:joy/controller.dart';
import 'package:joy/l10n.dart';
import 'package:joy_core/joy_core.dart';

void main() {
  test('all six languages have a complete nonempty set of interface strings', () {
    expect(translations.keys.toSet(), {'en', 'ru', 'fr', 'es', 'de', 'sr'});
    expect(languageNames.keys.toSet(), translations.keys.toSet());
    final keys = translations['en']!.keys.toSet();
    for (final locale in translations.keys) {
      expect(translations[locale]!.keys.toSet(), keys, reason: locale);
      for (final key in keys) {
        expect(translations[locale]![key]!.trim(), isNotEmpty, reason: '$locale/$key');
        expect(Words(locale)[key], translations[locale]![key], reason: '$locale/$key');
      }
    }
  });

  test('literal interface lookups have explicit translations in every language', () {
    final lookup = RegExp(r'''\b(?:words|w)\[['"]([A-Za-z0-9_-]+)['"]\]''');
    final keys = <String>{'modelMismatch', 'noVectors'};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('l10n.dart')) continue;
      keys.addAll(lookup.allMatches(file.readAsStringSync()).map((match) => match.group(1)!));
    }
    expect(keys, contains('graphTooLarge'));
    for (final locale in translations.keys) {
      for (final key in keys) {
        expect(translations[locale], contains(key), reason: '$locale/$key');
        expect(Words(locale)[key], translations[locale]![key], reason: '$locale/$key');
      }
    }
  });

  test('changing every language persists the selection without changing user data', () {
    final directory = Directory.systemTemp.createTempSync('joy-i18n-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final path = '${directory.path}/joy.sqlite';
    var repo = JoyRepository.open(path: path);
    addTearDown(() => repo.close());
    final record = repo.create(
      kind: 'item', parentId: 'inbox', title: 'Купить сметану — Acheter du lait',
      description: 'Млеко · Größe · mañana', data: {'custom': 'Не переводить'},
    );
    final original = record.toJson();
    final ordinal = repo.ordinalOf(record.id);
    for (final locale in languageNames.keys) {
      final controller = JoyController(repo);
      controller.saveSettings({'locale': locale});
      controller.dispose();
      repo.close();
      repo = JoyRepository.open(path: path);
      expect(JoyController(repo).locale, locale);
      expect(repo.get(record.id)!.toJson(), original);
      expect(repo.ordinalOf(record.id), ordinal);
    }
  });

  test('unsupported locales fall back to English', () {
    expect(const Words('unknown')['save'], const Words('en')['save']);
  });
}
