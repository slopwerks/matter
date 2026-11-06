import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'storage_models.dart';
import 'storage_settings.dart';

enum StorageConnection {
  wifi('Wi-Fi / 有线网络'),
  mobile('移动数据'),
  offline('离线'),
  unknown('网络类型未知');

  const StorageConnection(this.label);
  final String label;
}

StorageConnection classifyStorageConnection(
  List<ConnectivityResult> connections,
) {
  if (connections.isEmpty ||
      connections.every((c) => c == ConnectivityResult.none)) {
    return StorageConnection.offline;
  }
  // If the platform reports both transports, prefer the metered policy.
  if (connections.contains(ConnectivityResult.mobile)) {
    return StorageConnection.mobile;
  }
  if (connections.contains(ConnectivityResult.wifi) ||
      connections.contains(ConnectivityResult.ethernet)) {
    return StorageConnection.wifi;
  }
  return StorageConnection.unknown;
}

final storageConnectionProvider = StreamProvider<StorageConnection>((
  ref,
) async* {
  try {
    final connectivity = Connectivity();
    yield classifyStorageConnection(await connectivity.checkConnectivity());
    yield* connectivity.onConnectivityChanged
        .map(classifyStorageConnection)
        .distinct();
  } on MissingPluginException {
    yield StorageConnection.unknown;
  } on PlatformException {
    yield StorageConnection.unknown;
  }
});

bool permitsOnConnection(
  StorageSettings settings,
  StorageConnection connection,
  StorageKind kind,
  int? bytes,
) => switch (connection) {
  StorageConnection.wifi => settings.wifiDownloads.permits(kind, bytes),
  StorageConnection.mobile => settings.mobileDownloads.permits(kind, bytes),
  StorageConnection.offline => false,
  StorageConnection.unknown => settings.permitsUnknownNetwork(kind, bytes),
};

Future<bool> mayAutoDownload(StorageKind kind, int? bytes) async {
  final settings = await loadStorageSettings();
  if (bytes == null || bytes <= 0) return false;
  try {
    final connection = classifyStorageConnection(
      await Connectivity().checkConnectivity(),
    );
    return permitsOnConnection(settings, connection, kind, bytes);
  } on MissingPluginException {
    return settings.permitsUnknownNetwork(kind, bytes);
  } on PlatformException {
    return false;
  }
}
