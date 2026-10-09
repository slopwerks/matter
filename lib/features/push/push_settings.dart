import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'push_build_config.dart';
import 'web_push_runtime_stub.dart'
    if (dart.library.js_interop) 'web_push_runtime_web.dart'
    as web_push;

enum PushBackend { web, android }

String pushSettingsKey(String userId) =>
    'fcm_push_${base64Url.encode(utf8.encode(userId))}';

String? validatePushGateway(String value) {
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !uri.path.endsWith('/_matrix/push/v1/notify')) {
    return '请输入 HTTPS 地址，路径以 /_matrix/push/v1/notify 结尾';
  }
  return null;
}

String? validatePushAppId(String value) {
  final id = value.trim();
  if (id.isEmpty || id.length > 64 || !RegExp(r'^[\x21-\x7e]+$').hasMatch(id)) {
    return '请输入网关中配置的应用 ID（最多 64 个 ASCII 字符）';
  }
  return null;
}

String? validateVapidPublicKey(String value) {
  try {
    final bytes = base64Url.decode(base64Url.normalize(value.trim()));
    if (bytes.length == 65 && bytes.first == 4) return null;
  } on FormatException {
    // Not a base64url encoded P-256 public key.
  }
  return '请输入网关的 VAPID 公钥（不是私钥）';
}

class PushRegistration {
  const PushRegistration({required this.token, required this.appId});
  final String token;
  final String appId;

  factory PushRegistration.fromJson(Map<String, dynamic> json) =>
      PushRegistration(
        token: json['token'] as String,
        appId: json['app_id'] as String,
      );
  Map<String, dynamic> toJson() => {'token': token, 'app_id': appId};

  bool matches(PushRegistration other) =>
      token == other.token && appId == other.appId;
}

class PushSettings {
  const PushSettings({
    this.enabled = false,
    this.gatewayUrl = '',
    this.appId = '',
    this.backend = PushBackend.android,
    this.vapidPublicKey = '',
    this.registrationId = '',
    this.registrations = const [],
  });

  final bool enabled;
  final String gatewayUrl;
  final String appId;
  final PushBackend backend;
  final String vapidPublicKey;
  final String registrationId;
  // Journal both confirmed and possibly sent registrations. A failed or
  // interrupted request may already have taken effect on the homeserver.
  final List<PushRegistration> registrations;

  factory PushSettings.fromJson(Map<String, dynamic> json) => PushSettings(
    enabled: json['enabled'] as bool,
    gatewayUrl: json['gateway_url'] as String,
    appId: json['app_id'] as String,
    backend: json['backend'] == 'web' ? PushBackend.web : PushBackend.android,
    vapidPublicKey: json['vapid_public_key'] as String? ?? '',
    registrationId: json['registration_id'] as String,
    registrations: (json['registrations'] as List)
        .map(
          (value) => PushRegistration.fromJson(value as Map<String, dynamic>),
        )
        .toList(),
  );

  PushSettings copyWith({
    bool? enabled,
    String? gatewayUrl,
    String? appId,
    PushBackend? backend,
    String? vapidPublicKey,
    String? registrationId,
    List<PushRegistration>? registrations,
  }) => PushSettings(
    enabled: enabled ?? this.enabled,
    gatewayUrl: gatewayUrl ?? this.gatewayUrl,
    appId: appId ?? this.appId,
    backend: backend ?? this.backend,
    vapidPublicKey: vapidPublicKey ?? this.vapidPublicKey,
    registrationId: registrationId ?? this.registrationId,
    registrations: registrations ?? this.registrations,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'gateway_url': gatewayUrl,
    'app_id': appId,
    'backend': backend.name,
    'vapid_public_key': vapidPublicKey,
    'registration_id': registrationId,
    'registrations': registrations.map((value) => value.toJson()).toList(),
  };
}

class PushSettingsStore {
  Future<PushSettings> load(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    // FCM's background isolate must see changes made by the main isolate.
    await prefs.reload();
    final raw = prefs.getString(pushSettingsKey(userId));
    if (raw == null) {
      return PushSettings(
        backend: web_push.webPushSupported
            ? PushBackend.web
            : PushBackend.android,
        gatewayUrl: PushBuildConfig.gatewayUrl,
        appId: web_push.webPushSupported
            ? PushBuildConfig.webAppId
            : PushBuildConfig.androidAppId,
        vapidPublicKey: PushBuildConfig.vapidPublicKey,
      );
    }
    final saved = PushSettings.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    // A blank saved field must not permanently shadow the build prefill: a
    // save made before the build carried a default would otherwise pin the
    // gateway to an empty string for every account on this install.
    return saved.copyWith(
      gatewayUrl: saved.gatewayUrl.isNotEmpty
          ? saved.gatewayUrl
          : PushBuildConfig.gatewayUrl,
      appId: saved.appId.isNotEmpty
          ? saved.appId
          : (saved.backend == PushBackend.web
                ? PushBuildConfig.webAppId
                : PushBuildConfig.androidAppId),
      vapidPublicKey: saved.vapidPublicKey.isNotEmpty
          ? saved.vapidPublicKey
          : PushBuildConfig.vapidPublicKey,
    );
  }

  Future<bool> isAccountRemoved(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.containsKey(
      'matrix_session_removed_${base64Url.encode(utf8.encode(userId))}',
    );
  }

  Future<List<String>> storedUserIds() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs
        .getKeys()
        .where((key) => key.startsWith('fcm_push_'))
        .map(
          (key) =>
              utf8.decode(base64Url.decode(key.substring('fcm_push_'.length))),
        )
        .toList();
  }

  Future<void> blockDelivery(String userId) => web_push.blockAccount(userId);

  Future<void> resumeDelivery(String userId) async =>
      web_push.updateAccount(userId, await load(userId));

  Future<void> save(String userId, PushSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      pushSettingsKey(userId),
      jsonEncode(settings.toJson()),
    )) {
      throw StateError('无法保存推送设置');
    }
  }
}

String newPushRegistrationId() {
  final random = Random.secure();
  return base64Url.encode(List.generate(24, (_) => random.nextInt(256)));
}

class PushTarget {
  const PushTarget({
    required this.userId,
    required this.roomId,
    required this.eventId,
    required this.registrationId,
  });
  final String userId;
  final String roomId;
  final String eventId;
  final String registrationId;

  static PushTarget? fromData(Map<String, dynamic> data) {
    final userId = data['user_id'];
    final roomId = data['room_id'];
    final eventId = data['event_id'];
    final registrationId = data['registration_id'];
    if (userId is! String ||
        !userId.startsWith('@') ||
        roomId is! String ||
        !roomId.startsWith('!') ||
        eventId is! String ||
        !eventId.startsWith(r'$') ||
        registrationId is! String ||
        registrationId.isEmpty) {
      return null;
    }
    return PushTarget(
      userId: userId,
      roomId: roomId,
      eventId: eventId,
      registrationId: registrationId,
    );
  }

  Map<String, String> toData() => {
    'user_id': userId,
    'room_id': roomId,
    'event_id': eventId,
    'registration_id': registrationId,
  };

  bool acceptedBy(PushSettings settings) =>
      settings.enabled && registrationId == settings.registrationId;
}
