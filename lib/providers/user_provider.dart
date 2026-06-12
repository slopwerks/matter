import 'package:flutter_riverpod/legacy.dart';

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

final currentUserProvider = StateProvider<CurrentUser?>((ref) => null);