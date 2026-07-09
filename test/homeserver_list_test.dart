import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/login/homeserver_list.dart';

void main() {
  group('parseHomeservers', () {
    test('parses domain + label entries', () {
      const json = '''
[
  { "domain": "matrix.org", "label": "Matrix.org" },
  { "domain": "kde.org", "label": "KDE" }
]''';
      final list = parseHomeservers(json);

      expect(list.length, 2);
      expect(list[0].domain, 'matrix.org');
      expect(list[0].label, 'Matrix.org');
      expect(list[1].domain, 'kde.org');
      expect(list[1].label, 'KDE');
    });

    test('falls back to domain when label is missing', () {
      const json = '[{"domain": "envs.net"}]';
      final list = parseHomeservers(json);

      expect(list.single.label, 'envs.net');
    });

    test('skips entries with empty or blank domain', () {
      const json = '''
[
  { "domain": "", "label": "empty" },
  { "domain": "  ", "label": "blank" },
  { "domain": "matrix.org", "label": "Matrix.org" }
]''';
      final list = parseHomeservers(json);

      expect(list.length, 1);
      expect(list.single.domain, 'matrix.org');
    });

    test('trims surrounding whitespace in fields', () {
      const json =
          '[{ "domain": "  matrix.org  ", "label": "  Matrix.org  " }]';
      final list = parseHomeservers(json);

      expect(list.single.domain, 'matrix.org');
      expect(list.single.label, 'Matrix.org');
    });

    test('returns empty list when JSON is malformed', () {
      expect(parseHomeservers('not json {{{'), isEmpty);
      expect(parseHomeservers(''), isEmpty);
    });

    test('returns empty list when root is not a JSON array', () {
      expect(parseHomeservers('{"a": 1}'), isEmpty);
      expect(parseHomeservers('"string"'), isEmpty);
      expect(parseHomeservers('42'), isEmpty);
    });

    test('skips non-object array elements', () {
      const json = '["string", 1, null, {"domain": "matrix.org"}]';
      final list = parseHomeservers(json);

      expect(list.length, 1);
      expect(list.single.domain, 'matrix.org');
    });
  });
}
