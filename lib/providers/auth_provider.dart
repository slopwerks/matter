import 'package:flutter_riverpod/flutter_riverpod.dart';

class CurrentUser {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String homeserver;

  const CurrentUser({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    required this.homeserver,
  });
}

final isLoggedInProvider = StateProvider<bool>((ref) => false);

final currentUserProvider = StateProvider<CurrentUser?>((ref) => null);

/// Provider for the homeserver URL, persisted in memory
final homeserverProvider = StateProvider<String>(
  (ref) => 'http://10.0.2.2:8008',
);

/// Auth error message provider
final authErrorProvider = StateProvider<String?>((ref) => null);
