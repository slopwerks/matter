import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'mutable_state.dart';

enum AppConnectionState { connected, connecting, updating, disconnected }

final connectionProvider =
    NotifierProvider<MutableState<AppConnectionState>, AppConnectionState>(
      () => MutableState(AppConnectionState.connecting),
    );

final connectionLabelProvider = Provider<String>((ref) {
  final state = ref.watch(connectionProvider);
  return switch (state) {
    AppConnectionState.connected => '',
    AppConnectionState.connecting => '连接中…',
    AppConnectionState.updating => '同步中…',
    AppConnectionState.disconnected => '已断开',
  };
});

final connectionColorProvider = Provider<Color?>((ref) {
  // All states use default color (white/light) — no special colors
  return null;
});

// Call Rust to get status
Future<void> pollConnectionStatus(Ref ref) async {
  try {
    final status = rust.getConnectionStatus();
    final mapped = switch (status) {
      rust.ConnectionStatus.connected => AppConnectionState.connected,
      rust.ConnectionStatus.connecting => AppConnectionState.connecting,
      rust.ConnectionStatus.updating => AppConnectionState.updating,
      rust.ConnectionStatus.disconnected => AppConnectionState.disconnected,
    };
    ref.read(connectionProvider.notifier).value = mapped;
  } catch (_) {
    // ignore
  }
}
