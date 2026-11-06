import 'storage_models.dart';
import 'storage_settings.dart';

/// Select once, then delete oldest unused files. Busy files count toward the
/// budget but are deferred until their lease ends. Zero means unlimited.
Set<String> selectPolicyEvictions(
  StorageSnapshot snapshot,
  StorageSettings settings, {
  DateTime? now,
}) {
  final clock = now ?? DateTime.now();
  final files = snapshot.files.where((f) => f.cleanable).toList()
    ..sort((a, b) => a.lastUsed.compareTo(b.lastUsed));
  final selected = <String>{};
  Set<StorageChatType> types(StorageFile file) => file.owners.isEmpty
      ? {StorageChatType.unknown}
      : file.owners
            .map((o) => snapshot.rooms[o.key]?.type ?? StorageChatType.unknown)
            .toSet();
  for (final file in files) {
    if (file.busy || file.applicationData) continue;
    final expired = types(file).every((type) {
      final days = settings.policy(type).keepDays;
      return days > 0 &&
          clock.difference(file.lastUsed) >= Duration(days: days);
    });
    if (expired) selected.add(file.path);
  }
  void cap(Iterable<StorageFile> group, int limit) {
    if (limit <= 0) return;
    final remaining = group.where((f) => !selected.contains(f.path)).toList();
    var bytes = remaining.fold<int>(0, (sum, f) => sum + f.bytes);
    for (final file in remaining) {
      if (bytes <= limit) break;
      if (file.busy) continue;
      selected.add(file.path);
      bytes -= file.bytes;
    }
  }

  for (final type in StorageChatType.values) {
    // Cross-type shared media stays under the global limit rather than being
    // removed by the quota of just one of its owners.
    cap(
      files.where(
        (f) =>
            !f.applicationData &&
            types(f).length == 1 &&
            types(f).contains(type),
      ),
      settings.policy(type).maxBytes,
    );
  }
  cap(files, settings.maxCacheBytes);
  return selected;
}
