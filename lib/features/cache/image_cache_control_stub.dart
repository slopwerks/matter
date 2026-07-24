/// Web has no on-disk image cache (the browser manages it), so there is
/// nothing to measure or clear.
Future<int> imageCacheSizeBytes() async => 0;

Future<void> clearImageCacheFiles() async {}
