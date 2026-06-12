import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'pages/login/login_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/connection_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();

  var hasSessions = false;
  try {
    await migrateLegacySession();
    hasSessions = (await loadAllSessions()).isNotEmpty;
  } catch (e) {
    debugPrint('Bootstrap check failed: $e');
  }

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(ProviderScope(child: _AppRoot(hasSessions: hasSessions)));
}

class _AppRoot extends ConsumerStatefulWidget {
  final bool hasSessions;

  const _AppRoot({required this.hasSessions});

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  late bool _hasSessions;

  @override
  void initState() {
    super.initState();
    _hasSessions = widget.hasSessions;
    if (_hasSessions) {
      _restoreSessionsInBackground();
    } else {
      ref.read(sessionReadyProvider.notifier).state = true;
    }
  }

  Future<void> _restoreSessionsInBackground() async {
    String? restoredActiveId;

    try {
      final sessions = await loadAllSessions();
      final activeId = await loadActiveUserId();

      if (sessions.isEmpty) {
        ref.read(sessionReadyProvider.notifier).state = true;
        if (mounted) {
          setState(() {
            _hasSessions = false;
          });
        }
        return;
      }

      final dataDir = (await getApplicationSupportDirectory()).path;
      String? restoredDisplayName;
      String? restoredHomeserver;

      final orderedSessions = List<rust.StoredSession>.from(sessions);
      if (activeId != null) {
        final activeIdx = orderedSessions.indexWhere(
          (s) => s.userId == activeId,
        );
        if (activeIdx > 0) {
          final active = orderedSessions.removeAt(activeIdx);
          orderedSessions.insert(0, active);
        }
      }

      for (final session in orderedSessions) {
        try {
          await rust.restoreSession(session: session, dataDir: dataDir);
          debugPrint('Restored session for ${session.userId}');

          if (restoredActiveId == null || session.userId == activeId) {
            restoredActiveId = session.userId;
            restoredHomeserver = session.homeserverUrl;
            restoredDisplayName = await loadDisplayName(session.userId);
          }
        } catch (e) {
          debugPrint('Failed to restore session for ${session.userId}: $e');
          await removeSession(session.userId);
        }
      }

      if (restoredActiveId != null) {
        await rust.switchAccount(userId: restoredActiveId);

        ref.read(isLoggedInProvider.notifier).state = true;
        ref.read(currentUserProvider.notifier).state = CurrentUser(
          id: restoredActiveId,
          displayName:
              restoredDisplayName ??
              restoredActiveId.split(':').first.replaceFirst('@', ''),
          homeserver: restoredHomeserver ?? '',
        );
        ref.read(homeserverProvider.notifier).state = restoredHomeserver ?? '';
        ref.read(activeUserIdProvider.notifier).state = restoredActiveId;
        ref.read(sessionsProvider.notifier).state = await loadAllSessions();
        ref.read(connectionProvider.notifier).state =
            AppConnectionState.connecting;

        ref.read(syncStreamProvider);
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
      restoredActiveId = null;
    }

    if (restoredActiveId == null) {
      ref.read(isLoggedInProvider.notifier).state = false;
      ref.read(currentUserProvider.notifier).state = null;
      ref.read(activeUserIdProvider.notifier).state = null;
      ref.read(sessionReadyProvider.notifier).state = true;
      if (mounted) {
        setState(() {
          _hasSessions = false;
        });
      }
      return;
    }

    // Run the potentially slow sync in the background.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await rust.syncOnce();
        ref.invalidate(chatRoomsProvider);
        ref.read(connectionProvider.notifier).state =
            AppConnectionState.connected;
        break;
      } catch (e) {
        debugPrint('Restore sync attempt ${attempt + 1} failed: $e');
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        }
      }
    }
    try {
      await rust.startSync();
    } catch (e) {
      debugPrint('startSync after restore failed: $e');
    }
    ref.invalidate(chatRoomsProvider);

    // Signal that Rust APIs are safe to call.
    ref.read(sessionReadyProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = ref.watch(isLoggedInProvider);
    final sessionReady = ref.watch(sessionReadyProvider);
    final showMainApp = isLoggedIn || (_hasSessions && !sessionReady);

    return MaterialApp(
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: showMainApp ? const MatterApp() : const LoginPage(),
    );
  }
}
