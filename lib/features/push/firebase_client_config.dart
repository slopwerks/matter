import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'push_build_config.dart';

const firebaseClientConfigKey = 'fcm_firebase_options';

class FirebaseClientConfig {
  const FirebaseClientConfig({
    required this.apiKey,
    required this.appId,
    required this.senderId,
    required this.projectId,
  });
  final String apiKey;
  final String appId;
  final String senderId;
  final String projectId;

  factory FirebaseClientConfig.fromGoogleServices(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw const FormatException('文件不是有效的 JSON');
    }
    try {
      final json = decoded as Map<String, dynamic>;
      final project = json['project_info'] as Map<String, dynamic>;
      final clients = (json['client'] as List).cast<Map<String, dynamic>>();
      final client = clients
          .where(
            (entry) =>
                entry['client_info']['android_client_info']['package_name'] ==
                'moe.aks.matter',
          )
          .firstOrNull;
      if (client == null) {
        throw const FormatException(
          '文件中没有 moe.aks.matter 的 Android 客户端，请在 Firebase 项目中添加此包名',
        );
      }
      final config = FirebaseClientConfig(
        apiKey: (client['api_key'] as List).first['current_key'] as String,
        appId: client['client_info']['mobilesdk_app_id'] as String,
        senderId: project['project_number'] as String,
        projectId: project['project_id'] as String,
      );
      if ([
            config.apiKey,
            config.appId,
            config.senderId,
            config.projectId,
          ].any((value) => value.trim().isEmpty) ||
          !config.appId.startsWith('1:${config.senderId}:android:')) {
        throw const FormatException('Firebase 客户端参数缺失或 App ID 与项目编号不一致');
      }
      return config;
    } on FormatException {
      rethrow;
    } on TypeError {
      throw const FormatException('不是有效的 Android google-services.json');
    } on StateError {
      throw const FormatException('google-services.json 缺少客户端 API Key');
    } on NoSuchMethodError {
      throw const FormatException('不是有效的 Android google-services.json');
    }
  }

  factory FirebaseClientConfig.fromJson(Map<String, dynamic> json) =>
      FirebaseClientConfig(
        apiKey: json['api_key'] as String,
        appId: json['app_id'] as String,
        senderId: json['sender_id'] as String,
        projectId: json['project_id'] as String,
      );
  Map<String, String> toJson() => {
    'api_key': apiKey,
    'app_id': appId,
    'sender_id': senderId,
    'project_id': projectId,
  };
  FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
  );
  bool matches(FirebaseClientConfig other) =>
      apiKey == other.apiKey &&
      appId == other.appId &&
      senderId == other.senderId &&
      projectId == other.projectId;
}

class FirebaseClientConfigStore {
  Future<FirebaseClientConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final raw = prefs.getString(firebaseClientConfigKey);
    if (raw != null) {
      return FirebaseClientConfig.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    }
    final options = PushBuildConfig.firebaseOptions;
    return options == null
        ? null
        : FirebaseClientConfig(
            apiKey: options.apiKey,
            appId: options.appId,
            senderId: options.messagingSenderId,
            projectId: options.projectId,
          );
  }

  Future<void> save(FirebaseClientConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(
      firebaseClientConfigKey,
      jsonEncode(config.toJson()),
    )) {
      throw StateError('无法保存 Firebase 客户端配置');
    }
  }
}
