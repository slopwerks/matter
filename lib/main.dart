import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'features/app_update/app_update_service.dart';
import 'features/app_update/update_dialog.dart';
import 'pages/login/login_page.dart';
import 'pages/chat/decrypted_video_source.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await cleanupStaleDecryptedVideoSources();
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
  final _navigatorKey = GlobalKey<NavigatorState>();
  late bool _hasSessions;

  @override
  void initState() {
    super.initState();
    _hasSessions = widget.hasSessions;
    if (_hasSessions) {
      _restoreSessionsInBackground();
    } else {
      ref.read(sessionReadyProvider.notifier).value = true;
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkForUpdatesAtStartup(),
    );
  }

  Future<void> _checkForUpdatesAtStartup() async {
    if (!appUpdateService.isSupported) return;
    try {
      final result = await appUpdateService.checkForUpdate();
      final update = result.update;
      final updateContext = _navigatorKey.currentContext;
      if (!mounted ||
          result.status != UpdateCheckStatus.available ||
          update == null ||
          updateContext == null ||
          !updateContext.mounted) {
        return;
      }
      await showAvailableUpdateDialog(
        updateContext,
        service: appUpdateService,
        current: result.current,
        update: update,
      );
    } catch (error) {
      // Automatic checks stay silent; users can retry from Settings.
      debugPrint('Automatic update check failed: $error');
    }
  }

  Future<void> _restoreSessionsInBackground() async {
    String? restoredActiveId;

    try {
      final sessions = await loadAllSessions();
      final activeId = await loadActiveUserId();

      if (sessions.isEmpty) {
        ref.read(sessionReadyProvider.notifier).value = true;
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
        }
      }

      if (restoredActiveId != null) {
        await rust.switchAccount(userId: restoredActiveId);

        await applyActiveSessionState(
          ref,
          userId: restoredActiveId,
          displayName:
              restoredDisplayName ??
              restoredActiveId.split(':').first.replaceFirst('@', ''),
          homeserver: restoredHomeserver ?? '',
          refreshStoredSessions: true,
        );
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
      restoredActiveId = null;
    }

    if (restoredActiveId == null) {
      clearActiveSessionState(ref, markSessionReady: true);
      if (mounted) {
        setState(() {
          _hasSessions = false;
        });
      }
      return;
    }

    await bootstrapActiveSessionSync(
      ref,
      attemptLabel: 'Restore sync attempt',
      startSyncLabel: 'startSync after restore failed',
    );

    // Signal that Rust APIs are safe to call.
    ref.read(sessionReadyProvider.notifier).value = true;
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = ref.watch(isLoggedInProvider);
    final sessionReady = ref.watch(sessionReadyProvider);
    final showMainApp = isLoggedIn || (_hasSessions && !sessionReady);

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: showMainApp ? const MatterApp() : const LoginPage(),
    );
  }
}
