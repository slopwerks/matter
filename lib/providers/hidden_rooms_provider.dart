import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_provider.dart';
import '../src/rust/api/matrix.dart' as rust;

@immutable
class HiddenRoomsState {
  final Set<String> manuallyHiddenRoomIds;

  const HiddenRoomsState({
    this.manuallyHiddenRoomIds = const <String>{},
  });

  HiddenRoomsState copyWith({
    Set<String>? manuallyHiddenRoomIds,
  }) {
    return HiddenRoomsState(
      manuallyHiddenRoomIds:
      manuallyHiddenRoomIds ?? this.manuallyHiddenRoomIds,
    );
  }
}

class HiddenRoomsNotifier extends Notifier<HiddenRoomsState> {
  static const _manualPrefix = 'hidden_room_ids_';

  String? _userId;

  @override
  HiddenRoomsState build() {
    final userId = ref.watch(activeUserIdProvider);
    _userId = userId;
    if (userId != null && userId.isNotEmpty) {
      _restore(userId);
    }
    return const HiddenRoomsState();
  }

  Future<void> _restore(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _userId != userId) return;
      state = HiddenRoomsState(
        manuallyHiddenRoomIds:
        (prefs.getStringList('$_manualPrefix$userId') ?? const [])
        .toSet(),
      );
    } catch (error) {
      debugPrint('restore hidden rooms failed: $error');
    }
  }

  Future<void> _persist(HiddenRoomsState next) async {
    final userId = _userId;
    if (userId == null || userId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        '$_manualPrefix$userId',
        next.manuallyHiddenRoomIds.toList()..sort(),
      );
    } catch (error) {
      debugPrint('persist hidden rooms failed: $error');
    }
  }

  Future<void> hideRooms(Iterable<String> roomIds) async {
    final next = state.copyWith(
      manuallyHiddenRoomIds: {
        ...state.manuallyHiddenRoomIds,
        ...roomIds,
      },
    );
    state = next;
    await _persist(next);
  }

  Future<void> unhideRooms(Iterable<String> roomIds) async {
    final ids = roomIds.toSet();
    final next = state.copyWith(
      manuallyHiddenRoomIds:
      state.manuallyHiddenRoomIds.difference(ids),
    );
    state = next;
    await _persist(next);
  }

  bool isHidden(rust.ChatRoom room) =>
  state.manuallyHiddenRoomIds.contains(room.id);
}

final hiddenRoomsProvider =
NotifierProvider<HiddenRoomsNotifier, HiddenRoomsState>(
  HiddenRoomsNotifier.new,
);
