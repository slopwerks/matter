import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../src/rust/api/matrix.dart' as rust;

import 'mutable_state.dart';

final navigationIndexProvider = NotifierProvider<MutableState<int>, int>(
  () => MutableState(0),
);

/// Routes opened above the app shell (search and contact profiles) can still
/// select its desktop pane. A missing handler preserves standalone/mobile routes.
typedef OpenDesktopRoom = bool Function(
  rust.ChatRoom room, {
  String? messageId,
});

class DesktopRoomNavigation {
  OpenDesktopRoom? open;
}

final desktopRoomNavigationProvider = Provider<DesktopRoomNavigation>(
  (ref) => DesktopRoomNavigation(),
);
