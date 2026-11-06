// Cache attribution uses local filesystem indexes on native platforms.
export 'storage_attribution_stub.dart'
    if (dart.library.io) 'storage_attribution_io.dart';
