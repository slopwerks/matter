import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'apk_installer.dart';
import 'update_exception.dart';

const _latestReleaseApi =
    'https://api.github.com/repos/slopwerks/matter/releases/latest';
const _androidAssetName = 'matter-android-arm64.apk';
const _lastUpdateCheckKey = 'app_update_last_check_ms';

final appUpdateService = AppUpdateService();

enum UpdateCheckStatus { unsupported, skipped, upToDate, available }

class InstalledAppVersion {
  final String version;

  const InstalledAppVersion({required this.version});

  String get displayName => 'v$version';
}

class ReleaseUpdate {
  final String version;
  final String notes;
  final Uri releasePage;
  final Uri downloadUrl;
  final int assetSize;
  final String? digest;

  const ReleaseUpdate({
    required this.version,
    required this.notes,
    required this.releasePage,
    required this.downloadUrl,
    required this.assetSize,
    required this.digest,
  });
}

class UpdateCheckResult {
  final UpdateCheckStatus status;
  final InstalledAppVersion current;
  final ReleaseUpdate? update;

  const UpdateCheckResult({
    required this.status,
    required this.current,
    this.update,
  });
}

class AppUpdateService {
  static const automaticCheckInterval = Duration(days: 1);

  final http.Client _client;
  final Future<PackageInfo> Function() _packageInfoLoader;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;

  AppUpdateService({
    http.Client? client,
    Future<PackageInfo> Function()? packageInfoLoader,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? now,
  }) : _client = client ?? http.Client(),
       _packageInfoLoader = packageInfoLoader ?? PackageInfo.fromPlatform,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now;

  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<InstalledAppVersion> getCurrentVersion() async {
    final packageInfo = await _packageInfoLoader();
    return InstalledAppVersion(version: packageInfo.version);
  }

  Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
    final current = await getCurrentVersion();
    if (!isSupported) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.unsupported,
        current: current,
      );
    }

    final preferences = await _preferencesLoader();
    final now = _now();
    final lastCheckMilliseconds = preferences.getInt(_lastUpdateCheckKey);
    if (!force && lastCheckMilliseconds != null) {
      final lastCheck = DateTime.fromMillisecondsSinceEpoch(
        lastCheckMilliseconds,
      );
      final elapsed = now.difference(lastCheck);
      if (!elapsed.isNegative && elapsed < automaticCheckInterval) {
        return UpdateCheckResult(
          status: UpdateCheckStatus.skipped,
          current: current,
        );
      }
    }

    await preferences.setInt(_lastUpdateCheckKey, now.millisecondsSinceEpoch);
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse(_latestReleaseApi),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Matter-Android-Updater',
            },
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () =>
                throw const AppUpdateException('连接 GitHub 超时，请稍后重试'),
          );
    } on AppUpdateException {
      rethrow;
    } on http.ClientException {
      throw const AppUpdateException('无法连接 GitHub，请检查网络后重试');
    }
    if (response.statusCode != 200) {
      throw AppUpdateException('检查更新失败（GitHub HTTP ${response.statusCode}）');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const AppUpdateException('GitHub 返回了无法识别的更新信息');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AppUpdateException('GitHub 返回了无法识别的更新信息');
    }

    final tagName = decoded['tag_name'] as String?;
    final latestVersion = SemanticVersion.tryParse(tagName);
    final installedVersion = SemanticVersion.tryParse(current.version);
    if (tagName == null || latestVersion == null || installedVersion == null) {
      throw const AppUpdateException('版本号格式无效，无法比较更新');
    }
    if (latestVersion.compareTo(installedVersion) <= 0) {
      return UpdateCheckResult(
        status: UpdateCheckStatus.upToDate,
        current: current,
      );
    }

    final asset = _findAndroidAsset(decoded['assets']);
    if (asset == null) {
      throw const AppUpdateException('新版本没有可用的 Android arm64 安装包');
    }
    final downloadUrl = Uri.tryParse(
      asset['browser_download_url'] as String? ?? '',
    );
    final releasePage = Uri.tryParse(decoded['html_url'] as String? ?? '');
    if (downloadUrl == null ||
        releasePage == null ||
        downloadUrl.scheme != 'https' ||
        downloadUrl.host != 'github.com' ||
        downloadUrl.path.isEmpty ||
        releasePage.scheme != 'https' ||
        releasePage.host != 'github.com' ||
        releasePage.path.isEmpty) {
      throw const AppUpdateException('GitHub Release 地址无效');
    }

    return UpdateCheckResult(
      status: UpdateCheckStatus.available,
      current: current,
      update: ReleaseUpdate(
        version: latestVersion.normalized,
        notes: (decoded['body'] as String?)?.trim() ?? '',
        releasePage: releasePage,
        downloadUrl: downloadUrl,
        assetSize: (asset['size'] as num?)?.toInt() ?? 0,
        digest: asset['digest'] as String?,
      ),
    );
  }

  Future<String> downloadUpdate(
    ReleaseUpdate update, {
    required void Function(int received, int total) onProgress,
    Future<void>? cancel,
  }) {
    if (!isSupported) {
      throw const AppUpdateException('当前平台暂不支持应用内更新');
    }
    return downloadAndroidApk(
      uri: update.downloadUrl,
      fileName: _androidAssetName,
      expectedSize: update.assetSize,
      digest: update.digest,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  Future<void> installUpdate(String path) {
    if (!isSupported) {
      throw const AppUpdateException('当前平台暂不支持应用内更新');
    }
    return installAndroidApk(path);
  }

  Map<String, dynamic>? _findAndroidAsset(Object? assets) {
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map<String, dynamic> && asset['name'] == _androidAssetName) {
        return asset;
      }
    }
    return null;
  }
}

class SemanticVersion implements Comparable<SemanticVersion> {
  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  const SemanticVersion({
    required this.major,
    required this.minor,
    required this.patch,
    this.prerelease = const [],
  });

  static SemanticVersion? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^[vV]?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    return SemanticVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      prerelease: match.group(4)?.split('.') ?? const [],
    );
  }

  String get normalized {
    final stable = '$major.$minor.$patch';
    return prerelease.isEmpty ? stable : '$stable-${prerelease.join('.')}';
  }

  @override
  int compareTo(SemanticVersion other) {
    for (final comparison in [
      major.compareTo(other.major),
      minor.compareTo(other.minor),
      patch.compareTo(other.patch),
    ]) {
      if (comparison != 0) return comparison;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    final sharedLength = prerelease.length < other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < sharedLength; index++) {
      final comparison = _comparePrereleasePart(
        prerelease[index],
        other.prerelease[index],
      );
      if (comparison != 0) return comparison;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  int _comparePrereleasePart(String left, String right) {
    final leftNumber = int.tryParse(left);
    final rightNumber = int.tryParse(right);
    if (leftNumber != null && rightNumber != null) {
      return leftNumber.compareTo(rightNumber);
    }
    if (leftNumber != null) return -1;
    if (rightNumber != null) return 1;
    return left.compareTo(right);
  }
}
