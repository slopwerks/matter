import 'dart:typed_data';

import '../../pages/chat/prepared_media_source.dart';
import 'storage_models.dart';

Future<void> clearManagedMediaAccount(String account) async {}

Future<PreparedMediaSource> prepareManagedMedia({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  StorageOwner? owner,
  required Future<PreparedMediaSource> Function() load,
}) => load();

Future<PreparedMediaSource?> cachedManagedMedia({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  StorageOwner? owner,
}) async => null;

Future<Uint8List?> readManagedMediaBytes({
  required String account,
  required String key,
  required String filename,
  required StorageKind kind,
  required int maxBytes,
  StorageOwner? owner,
}) async => null;
