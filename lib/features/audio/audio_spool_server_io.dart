import 'dart:async';
import 'dart:io';
import 'dart:math';

/// Only a random loopback capability reaches the player. The upstream URL and
/// account authentication never cross this boundary.
abstract class AudioSpool {
  File get file;
  int get received;
  int? get expectedLength;
  String get mimeType;
  bool get complete;
  bool get failed;
  bool get invalidated;
  Future<void> get headersReady;
  Future<void> waitForChange();
  void wakeReaders();
}

class AudioSpoolServer {
  HttpServer? _server;
  Future<void>? _opening;
  final _routes = <String, _Route>{};
  final _random = Random.secure();

  Future<String> register(AudioSpool entry) async {
    await (_opening ??= _open());
    final token = List.generate(
      24,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _routes[token] = _Route(entry);
    return 'http://127.0.0.1:${_server!.port}/$token';
  }

  Future<void> _open() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) => unawaited(_serve(request)));
  }

  Future<void> unregister(String url) async {
    final token = Uri.parse(url).pathSegments.last;
    final route = _routes.remove(token);
    if (route == null) return;
    route.closed = true;
    route.cancelled.complete();
    route.entry.wakeReaders();
    // A blocked socket write must not keep an obsolete playback source alive.
    for (final response in route.responses.toList()) {
      unawaited(
        response.done.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      response.deadline = Duration.zero;
    }
    await Future.wait(route.requests.toList());
  }

  Future<void> close() async {
    await Future.wait(
      _routes.keys.toList().map(
        (token) => unregister('http://localhost/$token'),
      ),
    );
    await _server?.close(force: true);
    _server = null;
    _opening = null;
  }

  Future<void> _serve(HttpRequest request) async {
    final route = _routes[request.uri.pathSegments.firstOrNull];
    if (route == null || route.closed) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final completion = Completer<void>();
    route.requests.add(completion.future);
    route.responses.add(request.response);
    RandomAccessFile? file;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final entry = route.entry;
      await Future.any([entry.headersReady, route.cancelled.future]);
      if (route.closed || entry.invalidated || entry.failed) {
        request.response.statusCode = HttpStatus.badGateway;
        return;
      }
      var start = 0;
      int? end;
      final range = request.headers.value(HttpHeaders.rangeHeader);
      if (range != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range);
        final total =
            entry.expectedLength ?? (entry.complete ? entry.received : null);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        if (match[1]!.isEmpty) {
          if (total != null) {
            start = max(0, total - (int.tryParse(match[2]!) ?? 0));
            end = total - 1;
          }
        } else {
          start = int.tryParse(match[1]!) ?? -1;
          end = match[2]!.isEmpty
              ? (total == null ? null : total - 1)
              : int.tryParse(match[2]!);
        }
        if (start < 0 ||
            (total != null && start >= total) ||
            (end != null && end < start)) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          if (total != null) {
            request.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes */$total',
            );
          }
          return;
        }
        if (total != null && end != null) end = min(end, total - 1);
        // Do not claim a byte range with an invented total for chunked origins.
        if (total != null) {
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-${end ?? total - 1}/$total',
          );
        } else {
          start = 0;
          end = null;
        }
      }
      final total =
          entry.expectedLength ?? (entry.complete ? entry.received : null);
      final stop = end == null ? total : end + 1;
      request.response.bufferOutput = false;
      request.response.headers.set(
        HttpHeaders.contentTypeHeader,
        entry.mimeType,
      );
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (stop != null) request.response.contentLength = stop - start;
      if (request.method == 'HEAD') return;
      file = await entry.file.open();
      var position = start;
      while (!route.closed && !entry.invalidated) {
        if (entry.failed) throw StateError('Audio download failed');
        final available = min(entry.received, stop ?? entry.received);
        if (position < available) {
          await file.setPosition(position);
          final bytes = await file.read(min(64 * 1024, available - position));
          if (bytes.isEmpty) throw StateError('Audio spool is unavailable');
          request.response.add(bytes);
          await Future.any([request.response.flush(), route.cancelled.future]);
          position += bytes.length;
        } else if ((stop != null && position >= stop) || entry.complete) {
          break;
        } else {
          await Future.any([entry.waitForChange(), route.cancelled.future]);
        }
      }
    } catch (_) {
      // A player closing a read is normal; an upstream failure stays visible
      // as an incomplete/error HTTP response and never publishes a cache hit.
    } finally {
      await file?.close();
      try {
        // A disconnected peer can leave the sink Future pending. Revocation
        // ends only the network wait; the file is already closed above.
        await Future.any([request.response.close(), route.cancelled.future]);
      } catch (_) {}
      route.responses.remove(request.response);
      route.requests.remove(completion.future);
      completion.complete();
    }
  }
}

class _Route {
  final AudioSpool entry;
  final requests = <Future<void>>{};
  final responses = <HttpResponse>{};
  final cancelled = Completer<void>();
  bool closed = false;
  _Route(this.entry);
}
