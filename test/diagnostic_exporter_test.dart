import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/diagnostics/diagnostic_exporter.dart';

void main() {
  test('builds a readable report and redacts sensitive log values', () {
    final report = buildDiagnosticReport(
      generatedAt: DateTime.utc(2026, 7, 20, 12, 30),
      appInfo: const {
        'Name': 'Matter',
        'Version': '0.1.4 (3)',
        'Package': 'moe.aks.matter',
      },
      deviceInfo: const {
        'Model': 'Test phone',
        'Operating system': 'Android 16',
      },
      logs: const [
        DiagnosticLogEntry(
          timestamp: 0,
          level: 'error',
          tag: 'auth',
          message:
              'password=secret access_token: "abc" Authorization: Bearer token-value',
        ),
      ],
    );

    expect(report, contains('== Application =='));
    expect(report, contains('Model: Test phone'));
    expect(report, contains('== Logs (1) =='));
    expect(report, contains('[ERROR] [auth]'));
    expect(report, contains('password=[REDACTED]'));
    expect(report, contains('access_token:[REDACTED]'));
    expect(report, contains('Bearer [REDACTED]'));
    expect(report, isNot(contains('secret')));
    expect(report, isNot(contains('abc')));
    expect(report, isNot(contains('token-value')));
  });
}
