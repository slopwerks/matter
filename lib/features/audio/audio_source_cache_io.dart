import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../pages/chat/media_preparation.dart';
import '../../pages/chat/prepared_media_source.dart';
import 'audio_spool_server_io.dart';

/// Completed, verified account-scoped files survive track changes and stop.
/// Leases pin active files against eviction; unfinished files are never hits.
class AudioSourceCache {
  final int maxBytes;
  final _entries = <String, _Entry>{};
  final _retired = <_Entry>{};
  final _server = AudioSpoolServer();
  Future<Directory>? _root;
  Future<void> _maintenance = Future.value();
  String? _account;
  int _epoch = 0;
  bool _closed = false;

  AudioSourceCache({this.maxBytes = 256 * 1024 * 1024}) {
    if (maxBytes < 1) throw ArgumentError.value(maxBytes);
  }

  void selectAccount(String? userId, String? homeserver) {
    final next = userId == null || homeserver == null
        ? null
        : sha256
              .convert(utf8.encode(jsonEncode([userId, homeserver])))
              .toString();
    if (_account == next) return;
    final previous = _account;
    final initialising = _root;
    _account = next;
    _epoch++;
    for (final entry in _entries.values.toList()) {
      _retire(entry);
    }
    _entries.clear();
    if (previous != null) {
      _maintenance = _maintenance.then((_) async {
        try {
          await initialising;
        } catch (_) {
          // A superseded account may have cancelled its cache initialisation.
        }
        await _purgeDormant(previous);
      });
    }
  }

  Future<void> get released => Future.wait([
    _maintenance,
    ..._retired.map((entry) => entry.disposed.future),
  ]);

  Future<PreparedMediaSource> prepare({
    required String key,
    required String filename,
    required MediaPreparation preparation,
    Uri? url,
    Map<String, String> headers = const {},
    Future<PreparedMediaSource> Function(MediaPreparation)? verifiedLoader,
  }) async {
    preparation.throwIfCancelled();
    final epoch = _epoch;
    final account = _account;
    if (_closed || account == null) {
      throw StateError('No active audio cache account');
    }
    await _maintenance;
    preparation.throwIfCancelled();
    if (_closed || epoch != _epoch) throw StateError('Audio account changed');
    final directory = await (_root ??= _initialise(account, epoch));
    preparation.throwIfCancelled();
    if (_closed || epoch != _epoch) throw StateError('Audio account changed');
    final digest = sha256.convert(utf8.encode(key)).toString();
    var entry = _entries[digest];
    if (entry == null || entry.invalidated || entry.failed) {
      final accountDirectory = Directory('${directory.path}/$account');
      await accountDirectory.create(recursive: true);
      if (_closed || epoch != _epoch || preparation.isCancelled) {
        throw StateError('Audio preparation cancelled');
      }
      // Recheck after async directory work: concurrent leases share one transfer.
      entry = _entries[digest];
      if (entry == null || entry.invalidated || entry.failed) {
        final sourceDirectory = await accountDirectory.createTemp('source-');
        if (_closed || epoch != _epoch || preparation.isCancelled) {
          await sourceDirectory.delete(recursive: true);
          throw StateError('Audio preparation cancelled');
        }
        final existing = _entries[digest];
        if (existing != null && !existing.invalidated && !existing.failed) {
          await sourceDirectory.delete(recursive: true);
          entry = existing;
        } else {
          entry = _Entry(digest, sourceDirectory);
          _entries[digest] = entry;
          unawaited(_fill(entry, url, headers, verifiedLoader));
        }
      }
    }
    final selected = entry;
    selected.references++;
    selected.used = DateTime.now();
    String? localUrl;
    Future<void>? routeClosing;
    void revoke() {
      if (localUrl != null) routeClosing ??= _server.unregister(localUrl);
      if (selected.references <= 1 && !selected.complete) selected.cancel();
    }

    final detach = preparation.onCancel(revoke);
    Future<void>? releasing;
    Future<void> finishRelease() async {
      detach();
      if (localUrl != null) {
        await (routeClosing ??= _server.unregister(localUrl));
      }
      selected.references--;
      if (selected.failed ||
          selected.invalidated ||
          (!selected.complete && selected.references == 0)) {
        _retire(selected);
      }
      await _evict();
    }

    Future<void> release() => releasing ??= finishRelease();
    void checkAccount() {
      preparation.throwIfCancelled();
      if (_closed || epoch != _epoch || account != _account) {
        throw StateError('Audio account changed');
      }
    }

    try {
      if (selected.complete && !await _validate(selected)) {
        checkAccount();
        selected.failed = true;
        _retire(selected);
        await release();
        checkAccount();
        return await prepare(
          key: key,
          filename: filename,
          preparation: preparation,
          url: url,
          headers: headers,
          verifiedLoader: verifiedLoader,
        );
      }
      if (verifiedLoader != null || selected.complete) {
        await _ready(selected, preparation);
        checkAccount();
        if (selected.failed || selected.invalidated) {
          throw StateError('Audio download or verification failed');
        }
        return PreparedMediaSource(
          media: Media(selected.file.uri.toString()),
          cleanup: release,
          waveformFile: () => _readyPath(selected, preparation),
        );
      }
      localUrl = await _server.register(selected);
      checkAccount();
      return PreparedMediaSource(
        media: Media(localUrl),
        cleanup: release,
        waveformFile: () => _readyPath(selected, preparation),
      );
    } catch (_) {
      await release();
      rethrow;
    }
  }

  Future<bool> _validate(_Entry entry) async {
    try {
      if (await entry.file.length() != entry.received) return false;
      if (!entry.checked) {
        if ((await sha256.bind(entry.file.openRead()).first).toString() !=
            entry.digest) {
          return false;
        }
        entry.checked = true;
      }
      return !entry.invalidated;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ready(_Entry entry, MediaPreparation preparation) async {
    final cancelled = Completer<void>();
    final detach = preparation.onCancel(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      await Future.any([entry.finished.future, cancelled.future]);
    } finally {
      detach();
    }
  }

  Future<String?> _readyPath(_Entry entry, MediaPreparation preparation) async {
    await _ready(entry, preparation);
    return preparation.isCancelled ||
            entry.failed ||
            entry.invalidated ||
            !entry.complete
        ? null
        : entry.file.path;
  }

  Future<void> _fill(
    _Entry entry,
    Uri? url,
    Map<String, String> headers,
    Future<PreparedMediaSource> Function(MediaPreparation)? verifiedLoader,
  ) async {
    try {
      if (verifiedLoader != null) {
        final source = await verifiedLoader(entry.preparation);
        try {
          entry.preparation.throwIfCancelled();
          await File(source.media.uri).rename(entry.file.path);
          entry.received = await entry.file.length();
          entry.expectedLength = entry.received;
        } finally {
          await source.cleanup();
        }
      } else {
        if (url == null) throw StateError('Missing audio URL');
        await _download(entry, url, headers);
      }
      entry.preparation.throwIfCancelled();
      if (entry.received <= 0) throw StateError('Empty audio file');
      final digest = await sha256.bind(entry.file.openRead()).first;
      entry.preparation.throwIfCancelled();
      await entry.marker.writeAsString(
        jsonEncode({
          'key': entry.key,
          'bytes': entry.received,
          'sha256': digest.toString(),
          'mime': entry.mimeType,
        }),
        flush: true,
      );
      entry.digest = digest.toString();
      entry.checked = true;
      entry.complete = true;
    } catch (_) {
      entry.failed = true;
      try {
        if (await entry.marker.exists()) await entry.marker.delete();
      } catch (_) {}
    } finally {
      entry.headers.completeIfPending();
      entry.finished.completeIfPending();
      entry.signal();
      if (entry.references == 0 && (!entry.complete || entry.invalidated)) {
        _retire(entry);
      }
      unawaited(_evict());
    }
  }

  Future<void> _download(
    _Entry entry,
    Uri original,
    Map<String, String> headers,
  ) async {
    final client = http.Client();
    final detach = entry.preparation.onCancel(client.close);
    final timer = Timer(const Duration(minutes: 30), entry.cancel);
    RandomAccessFile? output;
    try {
      var url = original;
      http.StreamedResponse? response;
      for (var attempt = 0; attempt < 4; attempt++) {
        entry.preparation.throwIfCancelled();
        final request = http.Request('GET', url)..followRedirects = false;
        request.headers.addAll(headers);
        final credentialTarget =
            url.scheme == original.scheme &&
            url.host == original.host &&
            url.port == original.port &&
            url.path.startsWith('/_matrix/client/') &&
            url.path.contains('/media/');
        if (!credentialTarget) {
          request.headers.removeWhere(
            (key, value) =>
                key.toLowerCase() == 'authorization' ||
                key.toLowerCase() == 'cookie',
          );
        }
        request.headers[HttpHeaders.acceptEncodingHeader] = 'identity';
        response = await client.send(request);
        if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
        final location = response.headers[HttpHeaders.locationHeader];
        final next = location == null ? null : url.resolve(location);
        if (next == null ||
            (next.scheme != 'http' && next.scheme != 'https') ||
            next.userInfo.isNotEmpty ||
            (original.scheme == 'https' && next.scheme != 'https')) {
          throw StateError('Refusing unsafe audio redirect');
        }
        await response.stream.drain<void>();
        url = next;
      }
      if (response == null || response.statusCode != 200) {
        throw StateError('Audio download failed');
      }
      entry.mimeType =
          response.headers[HttpHeaders.contentTypeHeader] ??
          'application/octet-stream';
      entry.expectedLength =
          response.headers[HttpHeaders.contentEncodingHeader] == null
          ? response.contentLength
          : null;
      output = await entry.file.open(mode: FileMode.write);
      entry.headers.completeIfPending();
      await for (final chunk in response.stream) {
        entry.preparation.throwIfCancelled();
        await output.writeFrom(chunk);
        // Publish only bytes that are readable by independent player requests.
        entry.received += chunk.length;
        entry.signal();
      }
      await output.flush();
      if (entry.expectedLength != null &&
          entry.received != entry.expectedLength) {
        throw StateError('Incomplete audio');
      }
    } finally {
      await output?.close();
      timer.cancel();
      detach();
      client.close();
    }
  }

  Future<void> _purgeDormant(String account) async {
    final temporary = await getTemporaryDirectory();
    final directory = Directory(
      '${temporary.path}/matter_audio_cache/$account',
    );
    if (!await directory.exists()) return;
    final protected = _retired.map((entry) => entry.directory.path).toSet();
    await for (final entity in directory.list()) {
      if (entity is Directory && !protected.contains(entity.path)) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<Directory> _initialise(String account, int epoch) async {
    final temporary = await getTemporaryDirectory();
    final root = Directory('${temporary.path}/matter_audio_cache');
    await root.create(recursive: true);
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      if (entity.path.split(Platform.pathSeparator).last != account ||
          _account != account ||
          _epoch != epoch ||
          _closed) {
        await _purgeDormant(entity.path.split(Platform.pathSeparator).last);
        continue;
      }
      await for (final child in entity.list()) {
        if (child is! Directory ||
            _retired.any((entry) => entry.directory.path == child.path)) {
          continue;
        }
        try {
          final marker = File('${child.path}/ready.json');
          final metadata =
              jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
          final entry = _Entry(metadata['key'] as String, child);
          final length = await entry.file.length();
          if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.key) ||
              length <= 0 ||
              length != metadata['bytes'] ||
              metadata['sha256'] is! String ||
              !RegExp(r'^[a-f0-9]{64}$')
                  .hasMatch(metadata['sha256'] as String)) {
            throw StateError('Invalid cache');
          }
          if (_account != account || _epoch != epoch || _closed) {
            throw StateError('Account changed');
          }
          entry.received = length;
          entry.expectedLength = length;
          entry.mimeType = metadata['mime'] as String;
          entry.digest = metadata['sha256'] as String;
          entry.complete = true;
          entry.used = (await marker.stat()).modified;
          if (_account != account || _epoch != epoch || _closed) {
            throw StateError('Account changed');
          }
          entry.headers.complete();
          entry.finished.complete();
          _entries[entry.key] = entry;
        } catch (_) {
          await child.delete(recursive: true);
        }
      }
    }
    return root;
  }

  void _retire(_Entry entry) {
    entry.invalidated = true;
    entry.cancel();
    if (identical(_entries[entry.key], entry)) _entries.remove(entry.key);
    _retired.add(entry);
    if (entry.references == 0 && !entry.deleting) {
      entry.deleting = true;
      unawaited(() async {
        await entry.finished.future;
        try {
          if (await entry.directory.exists()) {
            await entry.directory.delete(recursive: true);
          }
        } catch (_) {
          try {
            if (await entry.marker.exists()) await entry.marker.delete();
          } catch (_) {}
        }
        _retired.remove(entry);
        entry.disposed.completeIfPending();
      }());
    }
  }

  Future<void> _evict() async {
    var bytes = _entries.values
        .where((entry) => entry.complete)
        .fold<int>(0, (sum, entry) => sum + entry.received);
    final candidates =
        _entries.values
            .where((entry) => entry.complete && entry.references == 0)
            .toList()
          ..sort((a, b) => a.used.compareTo(b.used));
    for (final entry in candidates) {
      if (bytes <= maxBytes) break;
      bytes -= entry.received;
      _retire(entry);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final entry in _entries.values.toList()) {
      if (entry.complete && entry.references == 0) {
        continue; // Persist only complete reusable files.
      }
      _retire(entry);
    }
    await released;
    await _server.close();
    _entries.clear();
  }
}

class _Entry implements AudioSpool {
  final String key;
  final Directory directory;
  final preparation = MediaPreparation();
  final headers = Completer<void>();
  final finished = Completer<void>();
  final disposed = Completer<void>();
  Completer<void> _change = Completer<void>();
  int references = 0;
  DateTime used = DateTime.now();
  bool deleting = false;
  @override
  int received = 0;
  @override
  int? expectedLength;
  @override
  String mimeType = 'application/octet-stream';
  @override
  bool complete = false;
  @override
  bool failed = false;
  @override
  bool invalidated = false;
  _Entry(this.key, this.directory);
  @override
  File get file => File('${directory.path}/data.bin');
  File get marker => File('${directory.path}/ready.json');
  @override
  Future<void> get headersReady => headers.future;
  @override
  Future<void> waitForChange() => _change.future;
  @override
  void wakeReaders() => signal();
  String? digest;
  bool checked = false;
  void signal() {
    final old = _change;
    _change = Completer<void>();
    old.completeIfPending();
  }

  void cancel() {
    preparation.cancel();
    signal();
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}
