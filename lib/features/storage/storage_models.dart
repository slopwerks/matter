export 'storage_identity.dart';

enum StorageKind {
  image('图片与缩略图'),
  video('视频'),
  audio('音频'),
  document('文件'),
  temporary('临时文件'),
  update('更新安装包'),
  database('聊天与加密数据库'),
  search('搜索索引'),
  settings('设置与账户数据'),
  other('其他应用数据');

  const StorageKind(this.label);
  final String label;
}

enum StorageChatType {
  direct('私聊'),
  group('群聊'),
  space('空间'),
  unknown('其他媒体');

  const StorageChatType(this.label);
  final String label;

  static StorageChatType fromRoomType(String type) => switch (type) {
    'dm' => direct,
    'group' => group,
    'space' => space,
    _ => unknown,
  };
}

class StorageOwner {
  final String account;
  final String roomId;
  const StorageOwner(this.account, this.roomId);
  String get key => '$account::$roomId';
  Map<String, dynamic> toJson() => {'account': account, 'room': roomId};
  factory StorageOwner.fromJson(Map<String, dynamic> json) =>
      StorageOwner(json['account'] as String, json['room'] as String);
}

class StorageRoom {
  final StorageOwner owner;
  final String name;
  final StorageChatType type;
  const StorageRoom(this.owner, this.name, this.type);
  Map<String, dynamic> toJson() => {
    ...owner.toJson(),
    'name': name,
    'type': type.name,
  };
  factory StorageRoom.fromJson(Map<String, dynamic> json) => StorageRoom(
    StorageOwner.fromJson(json),
    json['name'] as String,
    StorageChatType.values.byName(json['type'] as String),
  );
}

class StorageFile {
  final String path;
  final int bytes;
  final DateTime modified;
  final DateTime lastUsed;
  final StorageKind kind;
  final bool cleanable;
  final bool busy;
  final List<StorageOwner> owners;
  final String? displayName;
  final bool usageEstimated;
  const StorageFile({
    required this.path,
    required this.bytes,
    required this.modified,
    required this.lastUsed,
    required this.kind,
    required this.cleanable,
    this.busy = false,
    this.owners = const [],
    this.displayName,
    this.usageEstimated = false,
  });

  bool get applicationData =>
      owners.isEmpty &&
      !switch (kind) {
        StorageKind.image ||
        StorageKind.video ||
        StorageKind.audio ||
        StorageKind.document => true,
        _ => false,
      };

  String get name {
    if (displayName != null) return displayName!;
    final parts = path.replaceAll('\\', '/').split('/');
    final base = parts.last;
    if (base.startsWith('source.') || base.length > 48) {
      final id = parts.length > 1 ? parts[parts.length - 2] : base;
      return '${kind.label} · ${id.substring(0, id.length.clamp(0, 8))}';
    }
    return base;
  }
}

String? storageDisplayName(String? value) {
  if (value == null || value.contains('://')) return null;
  final name = value
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceAll(RegExp(r'[\x00-\x1f\x7f\u202a-\u202e\u2066-\u2069]'), '')
      .trim();
  return name.isEmpty ? null : name.substring(0, name.length.clamp(0, 200));
}

class StorageSnapshot {
  final List<StorageFile> files;
  final Map<String, StorageRoom> rooms;
  final List<String> warnings;
  final int? systemDataBytes;
  final int? systemCacheBytes;
  final int? appBytes;
  final int? freeBytes;
  final int? volumeBytes;
  final DateTime measuredAt;
  const StorageSnapshot({
    required this.files,
    required this.rooms,
    required this.measuredAt,
    this.warnings = const [],
    this.systemDataBytes,
    this.systemCacheBytes,
    this.appBytes,
    this.freeBytes,
    this.volumeBytes,
  });
  int get totalBytes => files.fold(0, (sum, file) => sum + file.bytes);
  int get cleanableBytes => files
      .where((f) => f.cleanable && !f.busy)
      .fold(0, (sum, file) => sum + file.bytes);
  int bytesFor(StorageKind kind) => files
      .where((f) => f.kind == kind)
      .fold(0, (sum, file) => sum + file.bytes);
}

class StorageSelection {
  final Set<StorageKind>? kinds;
  final Set<String>? rooms;
  final Set<StorageChatType>? chatTypes;
  final Set<String>? paths;
  const StorageSelection({this.kinds, this.rooms, this.chatTypes, this.paths});

  bool matches(
    StorageFile file,
    Map<String, StorageRoom> directory, {
    bool includeBusy = false,
  }) {
    if (!file.cleanable || (!includeBusy && file.busy)) return false;
    if (kinds != null && !kinds!.contains(file.kind)) return false;
    if (paths != null && !paths!.contains(file.path)) return false;
    // A shared file is removable only when all its owners are selected.
    if (rooms != null &&
        (file.owners.isEmpty ||
            !file.owners.every((owner) => rooms!.contains(owner.key)))) {
      return false;
    }
    if (chatTypes != null) {
      if (file.applicationData) return false;
      final types = file.owners.isEmpty
          ? [StorageChatType.unknown]
          : file.owners.map(
              (o) => directory[o.key]?.type ?? StorageChatType.unknown,
            );
      if (!types.every(chatTypes!.contains)) return false;
    }
    return true;
  }
}

class StorageCleanupResult {
  final int releasedBytes;
  final int removedFiles;
  final int skippedFiles;
  final List<String> errors;
  const StorageCleanupResult(
    this.releasedBytes,
    this.removedFiles,
    this.skippedFiles,
    this.errors,
  );
}

String formatStorageBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
