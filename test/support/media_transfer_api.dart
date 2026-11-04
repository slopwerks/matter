import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:matter/src/rust/api/media_transfer.dart';
import 'package:matter/src/rust/frb_generated.dart';

class FakeMediaTransfer implements MediaTransfer {
  bool cancelled = false;
  final cancellation = Completer<void>();

  @override
  void cancel() {
    cancelled = true;
    if (!cancellation.isCompleted) cancellation.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MediaFileRequest {
  final FakeMediaTransfer transfer;
  final String source;
  final String destination;
  final String expectedUserId;
  final completion = Completer<void>();

  MediaFileRequest(
    this.transfer,
    this.source,
    this.destination,
    this.expectedUserId,
  );

  Future<void> succeed([Uint8List? bytes]) async {
    await File(destination)
        .writeAsBytes(bytes ?? Uint8List.fromList([1, 2, 3]));
    completion.complete();
  }

  void fail() => completion.completeError(StateError('Offline'));
}

class MediaTransferApi implements RustLibApi {
  final requests = <MediaFileRequest>[];
  final transfers = <FakeMediaTransfer>[];
  Completer<void> _changed = Completer<void>();

  Future<void> waitForRequests(int count) async {
    while (requests.length < count) {
      await _changed.future.timeout(const Duration(seconds: 5));
    }
  }

  @override
  MediaTransfer crateApiMediaTransferMediaTransferNew() {
    final transfer = FakeMediaTransfer();
    transfers.add(transfer);
    return transfer;
  }

  @override
  Future<void> crateApiMediaTransferDownloadMediaSourceToFile({
    required MediaTransfer transfer,
    required String mediaSourceJson,
    required String expectedUserId,
    required String destination,
  }) {
    final handle = transfer as FakeMediaTransfer;
    final request = MediaFileRequest(
      handle,
      mediaSourceJson,
      destination,
      expectedUserId,
    );
    requests.add(request);
    final changed = _changed;
    _changed = Completer<void>();
    changed.complete();
    return Future.any([
      request.completion.future,
      handle.cancellation.future.then((_) => throw StateError('Cancelled')),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
