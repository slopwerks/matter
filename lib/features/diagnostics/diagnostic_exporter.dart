import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../pages/chat/file_download_saver.dart';
import '../../src/rust/api/matrix.dart' as rust;

class DiagnosticLogEntry {
  const DiagnosticLogEntry({
    required this.timestamp,
    required this.level,
    required this.tag,
    required this.message,
  });

  factory DiagnosticLogEntry.fromRust(rust.AppLogEntry entry) {
    return DiagnosticLogEntry(
      timestamp: entry.timestamp.toInt(),
      level: entry.level,
      tag: entry.tag,
      message: entry.message,
    );
  }

  final int timestamp;
  final String level;
  final String tag;
  final String message;
}

class DiagnosticExporter {
  const DiagnosticExporter();

  Future<bool> export() async {
    final generatedAt = DateTime.now();
    final packageInfo = await PackageInfo.fromPlatform();
    final deviceInfo = await _collectDeviceInfo();
    final report = buildDiagnosticReport(
      generatedAt: generatedAt,
      appInfo: {
        'Name': packageInfo.appName,
        'Version': '${packageInfo.version} (${packageInfo.buildNumber})',
        'Package': packageInfo.packageName,
      },
      deviceInfo: deviceInfo,
      logs: rust.getRecentLogs().map(DiagnosticLogEntry.fromRust),
    );

    return saveDownloadedFile(
      filename: _diagnosticFilename(generatedAt),
      bytes: Uint8List.fromList(utf8.encode(report)),
    );
  }

  /// Export the full persisted logs as a zip bundle. Unlike [export], this is
  /// not limited to the 5,000-entry in-memory buffer. Log contents are
  /// redacted before packing.
  Future<bool> exportLogsZip() async {
    final generatedAt = DateTime.now();
    final packageInfo = await PackageInfo.fromPlatform();
    final deviceInfo = await _collectDeviceInfo();

    final archive = Archive();
    final info = StringBuffer()
      ..writeln('Matter log bundle')
      ..writeln('Generated at (UTC): ${generatedAt.toUtc().toIso8601String()}')
      ..writeln()
      ..writeln('== Application ==');
    _writeSection(info, {
      'Name': packageInfo.appName,
      'Version': '${packageInfo.version} (${packageInfo.buildNumber})',
      'Package': packageInfo.packageName,
    });
    info
      ..writeln()
      ..writeln('== Device ==');
    _writeSection(info, deviceInfo);
    _addZipTextEntry(archive, 'device-info.txt', info.toString());

    for (final file in await rust.readLogFiles()) {
      _addZipTextEntry(archive, file.name, _redactLogMessage(file.content));
    }

    final zipBytes = ZipEncoder().encodeBytes(archive);
    return saveDownloadedFile(
      filename: _logBundleFilename(generatedAt),
      bytes: zipBytes,
    );
  }
}

String buildDiagnosticReport({
  required DateTime generatedAt,
  required Map<String, String> appInfo,
  required Map<String, String> deviceInfo,
  required Iterable<DiagnosticLogEntry> logs,
}) {
  final entries = logs.toList(growable: false);
  final report = StringBuffer()
    ..writeln('Matter diagnostic report')
    ..writeln('Generated at (UTC): ${generatedAt.toUtc().toIso8601String()}')
    ..writeln()
    ..writeln('This report includes diagnostic logs and device information.')
    ..writeln(
      'Access tokens, refresh tokens, passwords, registration tokens, and Bearer values are redacted on export.',
    )
    ..writeln('Chat message bodies and attachment contents are not collected.')
    ..writeln()
    ..writeln('== Application ==');

  _writeSection(report, appInfo);
  report
    ..writeln()
    ..writeln('== Device ==');
  _writeSection(report, deviceInfo);
  report
    ..writeln()
    ..writeln('== Logs (${entries.length}) ==');

  for (final entry in entries) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(
      entry.timestamp,
    ).toUtc();
    final message = _redactLogMessage(entry.message).replaceAll('\n', '\n    ');
    report.writeln(
      '${timestamp.toIso8601String()} [${entry.level.toUpperCase()}] [${entry.tag}] $message',
    );
  }

  return report.toString();
}

Future<Map<String, String>> _collectDeviceInfo() async {
  final details = <String, String>{
    'Target platform': defaultTargetPlatform.name,
    'Locale': PlatformDispatcher.instance.locale.toLanguageTag(),
    'Time zone': DateTime.now().timeZoneName,
  };
  final deviceInfo = DeviceInfoPlugin();

  try {
    if (kIsWeb) {
      final info = await deviceInfo.webBrowserInfo;
      details.addAll({
        'Browser': info.browserName.name,
        'Browser version': _unknownIfNull(info.appVersion),
        'Platform': _unknownIfNull(info.platform),
        'Logical processors': _unknownIfNull(info.hardwareConcurrency),
        'Device memory': _unknownIfNull(info.deviceMemory, suffix: ' GB'),
      });
      return details;
    }

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final info = await deviceInfo.androidInfo;
        details.addAll({
          'Model': '${info.manufacturer} ${info.model}'.trim(),
          'Operating system':
              'Android ${info.version.release} (API ${info.version.sdkInt})',
          'Architecture': info.supportedAbis.join(', '),
          'Physical device': _yesNo(info.isPhysicalDevice),
          'Memory': '${info.physicalRamSize} MB',
          'Free storage': _formatBytes(info.freeDiskSize),
        });
      case TargetPlatform.iOS:
        final info = await deviceInfo.iosInfo;
        details.addAll({
          'Model': info.modelName,
          'Hardware': info.utsname.machine,
          'Operating system': '${info.systemName} ${info.systemVersion}',
          'Physical device': _yesNo(info.isPhysicalDevice),
          'Memory': '${info.physicalRamSize} MB',
          'Free storage': _formatBytes(info.freeDiskSize),
        });
      case TargetPlatform.linux:
        final info = await deviceInfo.linuxInfo;
        details.addAll({
          'Operating system': info.prettyName,
          'Version': _unknownIfNull(info.version),
        });
      case TargetPlatform.macOS:
        final info = await deviceInfo.macOsInfo;
        details.addAll({
          'Model': info.modelName,
          'Hardware': info.model,
          'Operating system': 'macOS ${info.osRelease}',
          'Architecture': info.arch,
          'Logical processors': '${info.activeCPUs}',
          'Memory': _formatBytes(info.memorySize),
        });
      case TargetPlatform.windows:
        final info = await deviceInfo.windowsInfo;
        details.addAll({
          'Operating system': '${info.productName} ${info.displayVersion}',
          'Build': '${info.buildNumber}',
          'Logical processors': '${info.numberOfCores}',
          'Memory': '${info.systemMemoryInMegabytes} MB',
        });
      case TargetPlatform.fuchsia:
        details['Operating system'] = 'Fuchsia';
    }
  } catch (error) {
    details['Collection error'] = error.runtimeType.toString();
  }

  return details;
}

void _writeSection(StringBuffer report, Map<String, String> values) {
  for (final entry in values.entries) {
    report.writeln('${entry.key}: ${entry.value}');
  }
}

String _diagnosticFilename(DateTime generatedAt) =>
    _exportFilename('matter-diagnostics', 'txt', generatedAt);

String _logBundleFilename(DateTime generatedAt) =>
    _exportFilename('matter-logs', 'zip', generatedAt);

String _exportFilename(String prefix, String extension, DateTime generatedAt) {
  final timestamp = generatedAt.toUtc();
  final date =
      '${timestamp.year}${_twoDigits(timestamp.month)}${_twoDigits(timestamp.day)}';
  final time =
      '${_twoDigits(timestamp.hour)}${_twoDigits(timestamp.minute)}${_twoDigits(timestamp.second)}';
  return '$prefix-$date-$time.$extension';
}

void _addZipTextEntry(Archive archive, String name, String text) {
  final bytes = utf8.encode(text);
  archive.addFile(ArchiveFile(name, bytes.length, bytes));
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _yesNo(bool value) => value ? 'Yes' : 'No';

String _unknownIfNull(Object? value, {String suffix = ''}) =>
    value == null ? 'Unknown' : '$value$suffix';

String _formatBytes(int bytes) {
  const megabyte = 1024 * 1024;
  const gigabyte = megabyte * 1024;
  if (bytes >= gigabyte) return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
  return '${(bytes / megabyte).toStringAsFixed(1)} MB';
}

final _sensitiveValuePattern = RegExp(
  r'''\b(access[_-]?token|refresh[_-]?token|password|registration[_-]?token)\b\s*([=:])\s*("[^"]*"|'[^']*'|[^,\s}\]]+)''',
  caseSensitive: false,
);
final _bearerValuePattern = RegExp(r'(Bearer\s+)\S+', caseSensitive: false);

String _redactLogMessage(String message) {
  return message
      .replaceAllMapped(
        _sensitiveValuePattern,
        (match) => '${match.group(1)}${match.group(2)}[REDACTED]',
      )
      .replaceAllMapped(
        _bearerValuePattern,
        (match) => '${match.group(1)}[REDACTED]',
      );
}
