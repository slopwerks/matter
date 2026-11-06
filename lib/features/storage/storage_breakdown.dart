import 'storage_models.dart';

class StorageBucket {
  final String key;
  final String label;
  final int bytes;
  final int colorIndex;
  final StorageKind? kind;
  final StorageChatType? chatType;
  final bool crossTypeShared;
  final bool applicationData;
  const StorageBucket({
    required this.key,
    required this.label,
    required this.bytes,
    required this.colorIndex,
    this.kind,
    this.chatType,
    this.crossTypeShared = false,
    this.applicationData = false,
  });
}

/// Every physical file belongs to exactly one bucket. Shared owners of the
/// same chat type count once; files spanning types get their own bucket.
List<StorageBucket> storageBreakdown(
  StorageSnapshot snapshot, {
  bool byChat = false,
}) {
  final counts = <String, int>{};
  for (final file in snapshot.files) {
    final types = file.owners.isEmpty
        ? {StorageChatType.unknown}
        : file.owners
              .map(
                (owner) =>
                    snapshot.rooms[owner.key]?.type ?? StorageChatType.unknown,
              )
              .toSet();
    final key = byChat
        ? (file.applicationData
              ? 'application'
              : types.length == 1
              ? types.single.name
              : 'shared')
        : file.kind.name;
    counts.update(
      key,
      (value) => value + file.bytes,
      ifAbsent: () => file.bytes,
    );
  }
  final buckets = byChat
      ? [
          for (final type in StorageChatType.values)
            StorageBucket(
              key: type.name,
              label: type == StorageChatType.unknown ? '其他媒体' : type.label,
              bytes: counts[type.name] ?? 0,
              colorIndex: type.index,
              chatType: type,
            ),
          StorageBucket(
            key: 'application',
            label: '公共应用数据',
            bytes: counts['application'] ?? 0,
            colorIndex: 5,
            applicationData: true,
          ),
          StorageBucket(
            key: 'shared',
            label: '跨类型共用',
            bytes: counts['shared'] ?? 0,
            colorIndex: 4,
            crossTypeShared: true,
          ),
        ]
      : [
          for (final kind in StorageKind.values)
            StorageBucket(
              key: kind.name,
              label: kind.label,
              bytes: counts[kind.name] ?? 0,
              colorIndex: kind.index,
              kind: kind,
            ),
        ];
  return buckets.where((bucket) => bucket.bytes > 0).toList()
    ..sort((a, b) => b.bytes.compareTo(a.bytes));
}
