import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'storage_appearance.dart';
import 'storage_models.dart';

const storageMiB = 1024 * 1024;
const storageSettingsKey = 'storage_management_v1';
const downloadKinds = [
  StorageKind.image,
  StorageKind.video,
  StorageKind.audio,
  StorageKind.document,
];

enum DownloadProfile {
  wifi('Wi-Fi / 有线'),
  mobile('移动数据');

  const DownloadProfile(this.label);
  final String label;
}

class DownloadRules {
  final bool enabled;
  final Map<StorageKind, int> limits;
  const DownloadRules({
    this.enabled = true,
    this.limits = const {
      StorageKind.image: 8 * storageMiB,
      StorageKind.video: 20 * storageMiB,
      StorageKind.audio: 0,
      StorageKind.document: 0,
    },
  });
  bool permits(StorageKind kind, int? bytes) =>
      enabled && bytes != null && bytes > 0 && bytes <= (limits[kind] ?? 0);
  DownloadRules copyWith({bool? enabled, Map<StorageKind, int>? limits}) =>
      DownloadRules(
        enabled: enabled ?? this.enabled,
        limits: limits ?? this.limits,
      );
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'limits': {for (final kind in downloadKinds) kind.name: limits[kind] ?? 0},
  };
  factory DownloadRules.fromJson(Map<String, dynamic> json) {
    final limits = json['limits'] as Map? ?? {};
    return DownloadRules(
      enabled: json['enabled'] != false,
      limits: {
        for (final kind in downloadKinds) kind: _positive(limits[kind.name]),
      },
    );
  }
}

class ChatStoragePolicy {
  final int keepDays;
  final int maxBytes;
  const ChatStoragePolicy({this.keepDays = 0, this.maxBytes = 0});
  Map<String, dynamic> toJson() => {'days': keepDays, 'bytes': maxBytes};
  factory ChatStoragePolicy.fromJson(Map<String, dynamic> json) =>
      ChatStoragePolicy(
        keepDays: _positive(json['days']),
        maxBytes: _positive(json['bytes']),
      );
}

class StorageSettings {
  final int maxCacheBytes;
  final Map<StorageChatType, ChatStoragePolicy> policies;
  final DownloadRules wifiDownloads;
  final DownloadRules mobileDownloads;
  final StoragePalette chartPalette;
  final String? downloadDirectory;
  final String? downloadDirectoryLabel;
  final bool askSaveLocation;

  const StorageSettings({
    this.maxCacheBytes = 1024 * storageMiB,
    this.policies = const {},
    this.wifiDownloads = const DownloadRules(),
    this.mobileDownloads = const DownloadRules(
      limits: {
        StorageKind.image: 2 * storageMiB,
        StorageKind.video: 5 * storageMiB,
        StorageKind.audio: 0,
        StorageKind.document: 0,
      },
    ),
    this.chartPalette = StoragePalette.theme,
    this.downloadDirectory,
    this.downloadDirectoryLabel,
    this.askSaveLocation = false,
  });

  ChatStoragePolicy policy(StorageChatType type) =>
      policies[type] ?? const ChatStoragePolicy();
  DownloadRules downloads(DownloadProfile profile) =>
      profile == DownloadProfile.wifi ? wifiDownloads : mobileDownloads;
  bool permits(StorageKind kind, int? bytes, {required bool unmetered}) =>
      (unmetered ? wifiDownloads : mobileDownloads).permits(kind, bytes);
  bool permitsUnknownNetwork(StorageKind kind, int? bytes) =>
      wifiDownloads.permits(kind, bytes) &&
      mobileDownloads.permits(kind, bytes);

  StorageSettings copyWith({
    int? maxCacheBytes,
    Map<StorageChatType, ChatStoragePolicy>? policies,
    DownloadRules? wifiDownloads,
    DownloadRules? mobileDownloads,
    StoragePalette? chartPalette,
    String? downloadDirectory,
    String? downloadDirectoryLabel,
    bool resetDirectory = false,
    bool? askSaveLocation,
  }) => StorageSettings(
    maxCacheBytes: maxCacheBytes ?? this.maxCacheBytes,
    policies: policies ?? this.policies,
    wifiDownloads: wifiDownloads ?? this.wifiDownloads,
    mobileDownloads: mobileDownloads ?? this.mobileDownloads,
    chartPalette: chartPalette ?? this.chartPalette,
    downloadDirectory: resetDirectory
        ? null
        : downloadDirectory ?? this.downloadDirectory,
    downloadDirectoryLabel: resetDirectory
        ? null
        : downloadDirectoryLabel ?? this.downloadDirectoryLabel,
    askSaveLocation: askSaveLocation ?? this.askSaveLocation,
  );

  Map<String, dynamic> toJson() => {
    'version': 2,
    'maxCacheBytes': maxCacheBytes,
    'policies': policies.map(
      (key, value) => MapEntry(key.name, value.toJson()),
    ),
    'downloads': {
      'wifi': wifiDownloads.toJson(),
      'mobile': mobileDownloads.toJson(),
    },
    'palette': chartPalette.name,
    'directory': downloadDirectory,
    'directoryLabel': downloadDirectoryLabel,
    'askSaveLocation': askSaveLocation,
  };
  factory StorageSettings.fromJson(Map<String, dynamic> json) {
    const defaults = StorageSettings();
    final policies = json['policies'] as Map? ?? {};
    final downloads = json['downloads'] as Map?;
    DownloadRules rules(DownloadProfile profile) {
      final raw = downloads?[profile.name];
      if (raw is Map) {
        return DownloadRules.fromJson(Map<String, dynamic>.from(raw));
      }
      if (json.containsKey('network') || json.containsKey('limits')) {
        // Preserve the previous global rule when upgrading: never enable a
        // network or raise a file limit merely because profiles were added.
        final limits = json['limits'] as Map?;
        return DownloadRules(
          enabled:
              json['network'] != 'never' &&
              (profile == DownloadProfile.wifi ||
                  json['network'] != 'unmetered'),
          limits: limits == null
              ? defaults.wifiDownloads.limits
              : {
                  for (final kind in downloadKinds)
                    kind: _positive(limits[kind.name]),
                },
        );
      }
      return defaults.downloads(profile);
    }

    return StorageSettings(
      maxCacheBytes: json.containsKey('maxCacheBytes')
          ? _positive(json['maxCacheBytes'])
          : defaults.maxCacheBytes,
      policies: {
        for (final type in StorageChatType.values)
          if (policies[type.name] is Map)
            type: ChatStoragePolicy.fromJson(
              Map<String, dynamic>.from(policies[type.name] as Map),
            ),
      },
      wifiDownloads: rules(DownloadProfile.wifi),
      mobileDownloads: rules(DownloadProfile.mobile),
      chartPalette:
          StoragePalette.values
              .where((p) => p.name == json['palette'])
              .firstOrNull ??
          StoragePalette.theme,
      downloadDirectory: json['directory'] as String?,
      downloadDirectoryLabel: json['directoryLabel'] as String?,
      askSaveLocation: json['askSaveLocation'] == true,
    );
  }
}

int _positive(dynamic value) => value is num && value >= 0 ? value.toInt() : 0;

Future<StorageSettings> loadStorageSettings() async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(storageSettingsKey);
  if (raw == null) return const StorageSettings();
  return StorageSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}

Future<void> saveStorageSettings(StorageSettings settings) async {
  final preferences = await SharedPreferences.getInstance();
  if (!await preferences.setString(
    storageSettingsKey,
    jsonEncode(settings.toJson()),
  )) {
    throw StateError('存储设置保存失败');
  }
}
