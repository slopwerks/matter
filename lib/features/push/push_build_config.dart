import 'package:firebase_core/firebase_core.dart';

/// Public client options injected by the builder. No project or gateway is
/// bundled in an unconfigured open-source build.
class PushBuildConfig {
  static const gatewayUrl = String.fromEnvironment('MATTER_PUSH_GATEWAY');
  static const androidAppId = String.fromEnvironment(
    'MATTER_PUSH_ANDROID_APP_ID',
  );
  static const webAppId = String.fromEnvironment('MATTER_PUSH_WEB_APP_ID');
  static const vapidPublicKey = String.fromEnvironment(
    'MATTER_PUSH_VAPID_PUBLIC_KEY',
  );
  static const _apiKey = String.fromEnvironment('MATTER_FIREBASE_API_KEY');
  static const _appId = String.fromEnvironment('MATTER_FIREBASE_APP_ID');
  static const _senderId = String.fromEnvironment('MATTER_FIREBASE_SENDER_ID');
  static const _projectId = String.fromEnvironment(
    'MATTER_FIREBASE_PROJECT_ID',
  );

  static bool get fcmConfigured => [
    _apiKey,
    _appId,
    _senderId,
    _projectId,
  ].every((value) => value.isNotEmpty);

  static FirebaseOptions? get firebaseOptions => fcmConfigured
      ? const FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
        )
      : null;
}
