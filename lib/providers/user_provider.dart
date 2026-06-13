import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mutable_state.dart';

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

final currentUserProvider =
    NotifierProvider<MutableState<CurrentUser?>, CurrentUser?>(
      () => MutableState(null),
    );
