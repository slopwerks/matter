import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'features/app_update/app_update_service.dart';
import 'features/app_update/update_dialog.dart';
import 'pages/login/login_page.dart';
import 'pages/chat/decrypted_video_source.dart';
import 'pages/chat/chat_detail_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/mutable_state.dart';
import 'providers/theme_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/app_theme.dart';
import 'theme/neu_colors.dart';
import 'theme/neu_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await cleanupStaleDecryptedVideoSources();
  await RustLib.init();
  _installDartErrorLogging();

  String? dataDir;
  try {
    dataDir = (await getApplicationSupportDirectory()).path;
    rust.initializeLogStore(dataDir: dataDir);
    rust.logAppMessage(
      level: 'info',
      tag: 'startup',
      message: 'Persistent log store initialized before session discovery',
    );
  } catch (e) {
    _logDartError('startup', 'Persistent log initialization failed: $e');
  }

  var hasSessions = false;
  try {
    await migrateLegacySession();
    try {
      final cleanupDataDir =
          dataDir ?? (await getApplicationSupportDirectory()).path;
      await completePendingSessionRemovals(dataDir: cleanupDataDir);
    } catch (e) {
      _logDartError('startup', 'Pending account cleanup failed: $e');
    }
    final sessions = await loadAllSessions();
    hasSessions = sessions.isNotEmpty;
    rust.logAppMessage(
      level: 'info',
      tag: 'startup',
      message: 'Session discovery found ${sessions.length} usable session(s)',
    );
  } catch (e) {
    _logDartError('startup', 'Bootstrap check failed: $e');
  }
  final credentialStoreFailure = startupSessionCredentialStoreFailure;

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

  runApp(
    ProviderScope(
      overrides: [
        if (!hasSessions)
          sessionReadyProvider.overrideWith(() => MutableState(true)),
        if (credentialStoreFailure != null)
          sessionCredentialStoreFailureProvider.overrideWith(
            () => MutableState(credentialStoreFailure),
          ),
      ],
      child: _AppRoot(hasSessions: hasSessions),
    ),
  );
}

/// Record a Dart-side error in the app-wide log (the same ring buffer,
/// persisted file, and live stream the Rust side writes to), and keep it
/// visible in debug consoles.
void _logDartError(String tag, String message) {
  debugPrint(message);
  rust.logAppMessage(level: 'error', tag: tag, message: message);
}

/// Forward uncaught Dart errors — framework errors and unhandled async
/// errors — into the app-wide log. These are otherwise invisible in release
/// builds, where `debugPrint` output is dropped.
void _installDartErrorLogging() {
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _logDartError(
      'flutter',
      '${details.exceptionAsString()}\n${details.stack}',
    );
  };
  ui.PlatformDispatcher.instance.onError = (error, stack) {
    _logDartError('dart', '$error\n$stack');
    return true;
  };
}

class _AppRoot extends ConsumerStatefulWidget {
  final bool hasSessions;

  const _AppRoot({required this.hasSessions});

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _credentialCompatibilityDialogShown = false;

  /// True only while the startup session-restore is in flight. Keeps the main
  /// app on screen during restore so the login page doesn't flash, then drops
  /// back to false so a later login can never be mistaken for a restore.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    if (widget.hasSessions) {
      _restoring = true;
      _restoreSessionsInBackground();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _runStartupPrompts());
  }

  Future<void> _runStartupPrompts() async {
    await _offerCredentialCompatibilityMode();
    await _checkForUpdatesAtStartup();
  }

  Future<void> _offerCredentialCompatibilityMode() async {
    if (_credentialCompatibilityDialogShown || !mounted) return;
    final failure = ref.read(sessionCredentialStoreFailureProvider);
    final dialogContext = _navigatorKey.currentContext;
    if (failure == null || dialogContext == null) return;
    _credentialCompatibilityDialogShown = true;

    final enabled = await showSessionCredentialCompatibilityDialog(
      dialogContext,
      loginAlreadyCompleted: false,
    );
    if (!mounted || !enabled) return;

    try {
      await enableSessionCredentialCompatibilityModeAfterFailure();
      ref.read(sessionCredentialStoreFailureProvider.notifier).value = null;
      ref.read(sessionsProvider.notifier).value = await loadAllSessions();
      if (!mounted) return;
      final messageContext = _navigatorKey.currentContext;
      if (messageContext != null && messageContext.mounted) {
        ScaffoldMessenger.maybeOf(
          messageContext,
        )?.showSnackBar(const SnackBar(content: Text('兼容模式已启用')));
      }
    } catch (error) {
      _credentialCompatibilityDialogShown = false;
      if (!mounted) return;
      final messageContext = _navigatorKey.currentContext;
      if (messageContext != null && messageContext.mounted) {
        ScaffoldMessenger.maybeOf(
          messageContext,
        )?.showSnackBar(SnackBar(content: Text('启用兼容模式失败：$error')));
      }
    }
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
      _logDartError('startup', 'Automatic update check failed: $error');
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
          setState(() => _restoring = false);
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
          final searchIndexKey = await loadOrCreateSearchIndexKey(
            session.userId,
          );
          final useInMemorySearchIndex = searchIndexKey.key.isEmpty;
          await rust.restoreSession(
            session: session,
            dataDir: dataDir,
            searchIndexKey: searchIndexKey.key,
            useInMemorySearchIndex: useInMemorySearchIndex,
            resetSearchIndex: useInMemorySearchIndex
                ? false
                : searchIndexKey.created,
          );
          debugPrint('Restored session for ${session.userId}');

          if (restoredActiveId == null || session.userId == activeId) {
            restoredActiveId = session.userId;
            restoredHomeserver = session.homeserverUrl;
            restoredDisplayName = await loadDisplayName(session.userId);
          }
        } catch (e) {
          _logDartError(
            'startup',
            'Failed to restore session for ${session.userId}: $e',
          );
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
      _logDartError('startup', 'Session restore failed: $e');
      restoredActiveId = null;
    }

    if (restoredActiveId == null) {
      clearActiveSessionState(ref, markSessionReady: true);
      if (mounted) {
        setState(() => _restoring = false);
      }
      return;
    }

    // The restored Matrix store already contains the previous room list. Let
    // it render while the network refresh runs, rather than holding the UI
    // behind a potentially slow initial sync.
    ref.read(sessionReadyProvider.notifier).value = true;
    if (mounted) {
      setState(() => _restoring = false);
    }
    unawaited(
      bootstrapActiveSessionSync(
        ref,
        attemptLabel: 'Restore sync attempt',
        startSyncLabel: 'startSync after restore failed',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sessionTokenPersistenceProvider);
    final isLoggedIn = ref.watch(isLoggedInProvider);
    final showMainApp = isLoggedIn || _restoring;
    final themeStyle = ref.watch(appThemeStyleProvider);
    _syncSystemOverlayStyle(themeStyle);

    final neuLight = buildNeuTheme(NeuColors.light, Brightness.light);
    final neuDark = buildNeuTheme(NeuColors.dark, Brightness.dark);
    final (theme, darkTheme, themeMode) = switch (themeStyle) {
      AppThemeStyle.classic => (
        buildClassicTheme(),
        buildClassicTheme(),
        ThemeMode.dark,
      ),
      AppThemeStyle.neuLight => (neuLight, neuDark, ThemeMode.light),
      AppThemeStyle.neuDark => (neuLight, neuDark, ThemeMode.dark),
      AppThemeStyle.neuSystem => (neuLight, neuDark, ThemeMode.system),
    };

    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [chatRouteObserver],
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      home: showMainApp ? const MatterApp() : const LoginPage(),
    );
  }

  AppThemeStyle? _lastOverlayStyle;

  /// 状态栏/导航栏图标亮度跟随主题明暗（启动时 main() 里设的是深色默认值）。
  void _syncSystemOverlayStyle(AppThemeStyle style) {
    if (_lastOverlayStyle == style) return;
    _lastOverlayStyle = style;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final platformDark =
          MediaQuery.platformBrightnessOf(context) == Brightness.dark;
      final isDark = switch (style) {
        AppThemeStyle.classic || AppThemeStyle.neuDark => true,
        AppThemeStyle.neuLight => false,
        AppThemeStyle.neuSystem => platformDark,
      };
      final navColor = switch (style) {
        AppThemeStyle.classic => AppColors.background,
        AppThemeStyle.neuLight => NeuColors.light.base,
        AppThemeStyle.neuDark => NeuColors.dark.base,
        AppThemeStyle.neuSystem =>
          platformDark ? NeuColors.dark.base : NeuColors.light.base,
      };
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: navColor,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
        ),
      );
    });
  }
}
