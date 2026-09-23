import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_provider.dart';
import '../src/rust/api/matrix.dart' as rust;

@immutable
class HiddenRoomsState {
  final Set<String> manuallyHiddenRoomIds;
  final Set<String> shownAutomaticRoomIds;

  const HiddenRoomsState({
    this.manuallyHiddenRoomIds = const <String>{},
    this.shownAutomaticRoomIds = const <String>{},
  });

  HiddenRoomsState copyWith({
    Set<String>? manuallyHiddenRoomIds,
    Set<String>? shownAutomaticRoomIds,
  }) {
    return HiddenRoomsState(
      manuallyHiddenRoomIds:
          manuallyHiddenRoomIds ?? this.manuallyHiddenRoomIds,
      shownAutomaticRoomIds:
          shownAutomaticRoomIds ?? this.shownAutomaticRoomIds,
    );
  }
}

class HiddenRoomsNotifier extends Notifier<HiddenRoomsState> {
  static const _manualPrefix = 'hidden_room_ids_';
  static const _shownAutomaticPrefix = 'shown_automatic_room_ids_';

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
        shownAutomaticRoomIds:
            (prefs.getStringList('$_shownAutomaticPrefix$userId') ?? const [])
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
      await prefs.setStringList(
        '$_shownAutomaticPrefix$userId',
        next.shownAutomaticRoomIds.toList()..sort(),
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
      shownAutomaticRoomIds: {
        ...state.shownAutomaticRoomIds,
        ...ids,
      },
    );
    state = next;
    await _persist(next);
  }

  Future<void> hideAutomaticRoom(String roomId) async {
    await hideRooms([roomId]);
  }

  bool isAutomaticallyHidden(rust.ChatRoom room) {
    final normalized = room.name.trim().toLowerCase();
    return normalized.contains('stickers') &&
        !state.shownAutomaticRoomIds.contains(room.id);
  }

  bool isHidden(rust.ChatRoom room) =>
      state.manuallyHiddenRoomIds.contains(room.id) ||
      isAutomaticallyHidden(room);
}

final hiddenRoomsProvider =
    NotifierProvider<HiddenRoomsNotifier, HiddenRoomsState>(
      HiddenRoomsNotifier.new,
    );
