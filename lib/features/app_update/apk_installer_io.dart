import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'update_exception.dart';

const _installerChannel = MethodChannel('moe.aks.matter/app_update');

Future<String> downloadAndroidApk({
  required Uri uri,
  required String fileName,
  required int expectedSize,
  required String? digest,
  required void Function(int received, int total) onProgress,
  Future<void>? cancel,
}) async {
  final client = http.Client();
  IOSink? fileSink;
  File? partialFile;

  try {
    final tempDirectory = await getTemporaryDirectory();
    final updateDirectory = Directory('${tempDirectory.path}/updates');
    await updateDirectory.create(recursive: true);
    final targetFile = File('${updateDirectory.path}/$fileName');
    if (await _isValidCachedApk(targetFile, expectedSize, digest)) {
      return targetFile.path;
    }
    if (await targetFile.exists()) await targetFile.delete();

    final request = http.AbortableRequest('GET', uri, abortTrigger: cancel)
      ..headers['Accept'] = 'application/octet-stream'
      ..headers['User-Agent'] = 'Matter-Android-Updater';
    final response = await client
        .send(request)
        .timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw const AppUpdateException('连接 GitHub 超时'),
        );
    if (response.statusCode != HttpStatus.ok) {
      throw AppUpdateException('下载失败（HTTP ${response.statusCode}）');
    }

    partialFile = File('${targetFile.path}.download');
    if (await partialFile.exists()) await partialFile.delete();
    fileSink = partialFile.openWrite();

    final hashOutput = _DigestSink();
    final hashInput = sha256.startChunkedConversion(hashOutput);
    final total = response.contentLength ?? expectedSize;
    var received = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 15),
    )) {
      fileSink.add(chunk);
      hashInput.add(chunk);
      received += chunk.length;
      onProgress(received, total);
    }
    await fileSink.flush();
    await fileSink.close();
    fileSink = null;
    hashInput.close();

    if (expectedSize > 0 && received != expectedSize) {
      throw const AppUpdateException('安装包大小校验失败，请重试');
    }
    final expectedDigest = _parseSha256Digest(digest);
    if (expectedDigest != null &&
        hashOutput.value.toString() != expectedDigest) {
      throw const AppUpdateException('安装包完整性校验失败，请重试');
    }

    return (await partialFile.rename(targetFile.path)).path;
  } on AppUpdateException {
    rethrow;
  } on http.RequestAbortedException {
    throw const AppUpdateException('下载已取消');
  } on TimeoutException {
    throw const AppUpdateException('下载超时，请检查网络后重试');
  } on SocketException {
    throw const AppUpdateException('无法连接 GitHub，请检查网络后重试');
  } on PlatformException catch (error) {
    throw AppUpdateException(error.message ?? '无法保存安装包');
  } catch (error) {
    throw AppUpdateException('下载安装包失败：$error');
  } finally {
    client.close();
    await fileSink?.close();
    if (partialFile != null && await partialFile.exists()) {
      await partialFile.delete();
    }
  }
}

Future<bool> _isValidCachedApk(
  File file,
  int expectedSize,
  String? digest,
) async {
  final expectedDigest = _parseSha256Digest(digest);
  if (expectedSize <= 0 && expectedDigest == null) return false;

  try {
    if (!await file.exists()) return false;
    if (expectedSize > 0 && await file.length() != expectedSize) return false;
    if (expectedDigest == null) return true;

    final actualDigest = await sha256.bind(file.openRead()).first;
    return actualDigest.toString() == expectedDigest;
  } on FileSystemException {
    return false;
  }
}

Future<void> installAndroidApk(String path) async {
  try {
    await _installerChannel.invokeMethod<void>('installApk', {'path': path});
  } on PlatformException catch (error) {
    throw AppUpdateException(error.message ?? '无法打开系统安装器');
  } on MissingPluginException {
    throw const AppUpdateException('当前平台暂不支持安装 Android 更新');
  }
}

String? _parseSha256Digest(String? digest) {
  if (digest == null || !digest.startsWith('sha256:')) return null;
  final value = digest.substring('sha256:'.length).toLowerCase();
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value) ? value : null;
}

class _DigestSink implements Sink<Digest> {
  Digest? _value;

  Digest get value {
    final digest = _value;
    if (digest == null) {
      throw StateError('SHA-256 digest was not finalized');
    }
    return digest;
  }

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {}
}
