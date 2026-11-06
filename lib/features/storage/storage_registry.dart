import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'storage_models.dart';
import 'storage_path_stub.dart' if (dart.library.io) 'storage_path_io.dart';

final storageRegistry = StorageRegistry();
const _indexKey = 'storage_file_index_v1';

class StorageFileMetadata {
  final StorageKind kind;
  final DateTime used;
  final Map<String, StorageOwner> owners;
  final String? displayName;
  final bool usageEstimated;
  StorageFileMetadata(
    this.kind,
    this.used,
    Iterable<StorageOwner> owners, {
    this.displayName,
    this.usageEstimated = false,
  }) : owners = {for (final owner in owners) owner.key: owner};
  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'used': used.millisecondsSinceEpoch,
    'owners': owners.values.map((o) => o.toJson()).toList(),
    if (displayName != null) 'name': displayName,
    if (usageEstimated) 'estimated': true,
  };
  factory StorageFileMetadata.fromJson(Map<String, dynamic> json) =>
      StorageFileMetadata(
        StorageKind.values.byName(json['kind'] as String),
        DateTime.fromMillisecondsSinceEpoch(json['used'] as int),
        (json['owners'] as List).map(
          (o) => StorageOwner.fromJson(Map<String, dynamic>.from(o as Map)),
        ),
        displayName: storageDisplayName(json['name'] as String?),
        usageEstimated: json['estimated'] == true,
      );
}

/// One physical file has one record, even when several rooms use it. No URLs,
/// access tokens or encryption source JSON are persisted in this index.
class StorageRegistry {
  final files = <String, StorageFileMetadata>{};
  final rooms = <String, StorageRoom>{};
  final _sources = <String, Map<String, StorageOwner>>{};
  final _sourceNames = <String, String>{};
  final _pins = <String, int>{};
  Future<void>? _loading;
  Future<void> _writing = Future.value();
  Timer? _saveTimer;
  void Function()? onFileCompleted;

  Future<void> load() => _loading ??= _load();
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_indexKey);
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in (json['files'] as Map).entries) {
        files[storagePathKey(
          entry.key as String,
        )] = StorageFileMetadata.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
      for (final entry in (json['rooms'] as List)) {
        final room = StorageRoom.fromJson(
          Map<String, dynamic>.from(entry as Map),
        );
        rooms[room.owner.key] = room;
      }
    } on FormatException {
      // The filesystem remains authoritative; an index can be rebuilt.
      files.clear();
      rooms.clear();
    } on TypeError {
      files.clear();
      rooms.clear();
    } on ArgumentError {
      files.clear();
      rooms.clear();
    }
  }

  void rememberSource(String url, StorageOwner owner, {String? filename}) {
    final name = storageDisplayName(filename);
    if (name != null) _sourceNames[url] = name;
    final owners = _sources.putIfAbsent(url, () => {});
    owners[owner.key] = owner;
    // URLs live only for the running session; bound this lookup independently
    // from the persistent file index.
    if (_sources.length > 10000) {
      final oldest = _sources.keys.first;
      _sources.remove(oldest);
      _sourceNames.remove(oldest);
    }
  }

  Future<void> recordSource(String url, String path, StorageKind kind) async {
    await record(
      path,
      kind,
      owners: _sources[url]?.values ?? const [],
      displayName: _sourceNames[url],
    );
  }

  Future<void> record(
    String path,
    StorageKind kind, {
    Iterable<StorageOwner> owners = const [],
    String? displayName,
  }) async {
    await load();
    path = storagePathKey(path);
    files[path] = StorageFileMetadata(
      kind,
      DateTime.now(),
      [...?files[path]?.owners.values, ...owners],
      displayName: storageDisplayName(displayName) ?? files[path]?.displayName,
    );
    _scheduleSave();
    onFileCompleted?.call();
  }

  /// Recover ownership without treating an old cache file as newly used.
  Future<void> attribute(
    String path,
    StorageKind kind,
    DateTime modified,
    Iterable<StorageOwner> owners, {
    String? displayName,
  }) async {
    await load();
    path = storagePathKey(path);
    final old = files[path];
    final combined = {
      for (final owner in [...?old?.owners.values, ...owners]) owner.key: owner,
    };
    final name = old?.displayName ?? storageDisplayName(displayName);
    if (old != null &&
        old.kind == kind &&
        old.displayName == name &&
        combined.length == old.owners.length) {
      return;
    }
    files[path] = StorageFileMetadata(
      kind,
      old?.used ?? modified,
      combined.values,
      displayName: name,
      usageEstimated: old?.usageEstimated ?? true,
    );
    _scheduleSave();
  }

  Future<void> updateRooms(Iterable<StorageRoom> values) async {
    await load();
    var changed = false;
    for (final room in values) {
      final old = rooms[room.owner.key];
      if (old?.name != room.name || old?.type != room.type) {
        rooms[room.owner.key] = room;
        changed = true;
      }
    }
    if (changed) _scheduleSave();
  }

  /// Active playback and in-flight transfers must survive manual/automatic cleanup.
  void Function() pin(String path) {
    path = storagePathKey(path);
    _pins.update(path, (count) => count + 1, ifAbsent: () => 1);
    var released = false;
    return () {
      if (released) return;
      released = true;
      final count = (_pins[path] ?? 1) - 1;
      if (count == 0) {
        _pins.remove(path);
        onFileCompleted?.call();
      } else {
        _pins[path] = count;
      }
    };
  }

  bool isBusy(String path) {
    if (_pins.isEmpty) return false;
    final key = storagePathKey(path);
    return _pins.keys.any(
      (pin) =>
          key == pin || key.startsWith('$pin/') || key.startsWith('$pin\\'),
    );
  }

  void forget(String path) {
    if (files.remove(storagePathKey(path)) != null) _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(flush().catchError((Object _) {}));
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    await load();
    final payload = jsonEncode({
      'files': files.map((path, data) => MapEntry(path, data.toJson())),
      'rooms': rooms.values.map((room) => room.toJson()).toList(),
    });
    final next = _writing.catchError((Object _) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_indexKey, payload)) {
        throw StateError('存储索引保存失败');
      }
    });
    _writing = next;
    return next;
  }
}
