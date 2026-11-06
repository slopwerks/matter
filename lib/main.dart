import 'dart:async';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'features/app_update/app_update_service.dart';
import 'features/app_update/update_dialog.dart';
import 'features/auth/session_expiry_listener.dart';
import 'features/audio/audio_playback_provider.dart';
import 'features/storage/storage_image_cache.dart';
import 'features/storage/storage_providers.dart';
import 'features/push/push_runtime.dart';
import 'features/push/desktop_notification_listener.dart';
import 'features/push/push_notification_listener.dart';
import 'pages/login/login_page.dart';
import 'pages/chat/prepared_media_source.dart';
import 'pages/chat/chat_detail_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/chat_visual_settings_provider.dart';
import 'providers/material_color_provider.dart';
import 'providers/mutable_state.dart';
import 'providers/theme_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'src/rust/frb_generated.dart';
import 'theme/neu_colors.dart';
import 'theme/material_theme.dart';
import 'theme/neu_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  CachedNetworkImageProvider.defaultCacheManager = managedDefaultImageCache;
  MediaKit.ensureInitialized();
  await cleanupStaleMediaSources();
  await RustLib.init();
  _installDartErrorLogging();
  await initializePush();

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

  final startupDark =
      ui.PlatformDispatcher.instance.platformBrightness == Brightness.dark;
  SystemChrome.setSystemUIOverlayStyle(
    SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: startupDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: startupDark
          ? NeuColors.dark.base
          : NeuColors.light.base,
      systemNavigationBarIconBrightness: startupDark
          ? Brightness.light
          : Brightness.dark,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  // Keep phones in portrait; tablets follow the user's system rotation setting.
  final display = ui.PlatformDispatcher.instance.implicitView?.display;
  final displayWidth = display == null
      ? 0
      : display.size.shortestSide / display.devicePixelRatio;
  if (displayWidth < 600) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

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

class _AppRootState extends ConsumerState<_AppRoot>
    with WidgetsBindingObserver {
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _credentialCompatibilityDialogShown = false;
  CurrentUser? _reloginUser;
  bool _resumeSession = false;

  /// True only while the startup session-restore is in flight. Keeps the main
  /// app on screen during restore so the login page doesn't flash, then drops
  /// back to false so a later login can never be mistaken for a restore.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.hasSessions) {
      _restoring = true;
      _restoreSessionsInBackground();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _runStartupPrompts());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        ref.read(appThemeStyleProvider).isMaterial &&
        ref.read(materialColorSettingsProvider).followSystem) {
      ref.invalidate(systemMaterialColorsProvider);
    }
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
        ScaffoldMessenger.maybeOf(messageContext)
            ?.showSnackBar(const SnackBar(content: Text('兼容模式已启用')));
      }
    } catch (error) {
      _credentialCompatibilityDialogShown = false;
      if (!mounted) return;
      final messageContext = _navigatorKey.currentContext;
      if (messageContext != null && messageContext.mounted) {
        ScaffoldMessenger.maybeOf(messageContext)
            ?.showSnackBar(SnackBar(content: Text('启用兼容模式失败：$error')));
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
    if (isLoggedIn) _resumeSession = false;
    final themeStyle = ref.watch(appThemeStyleProvider);
    final materialColors = themeStyle.isMaterial
        ? ref.watch(materialColorSchemesProvider)
        : null;

    final theme = themeStyle.isMaterial
        ? buildMaterialTheme(
            Brightness.light,
            colorScheme: materialColors!.light,
          )
        : buildNeuTheme(NeuColors.light, Brightness.light);
    final darkTheme = themeStyle.isMaterial
        ? buildMaterialTheme(Brightness.dark, colorScheme: materialColors!.dark)
        : buildNeuTheme(NeuColors.dark, Brightness.dark);
    _syncSystemOverlayStyle(themeStyle, theme, darkTheme);
    final themeMode = themeStyle.themeMode;

    return MaterialApp(
      navigatorKey: _navigatorKey,
      navigatorObservers: [chatRouteObserver],
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      // pro_image_editor 14's own app bars, dialogs and bottom sheets are built
      // from the decoupled material_ui widgets, which look up MaterialLocalizations
      // from material_ui and throw "No MaterialLocalizations found" without these.
      localizationsDelegates: const [
        ...material_ui.GlobalMaterialLocalizations.delegates,
      ],
      theme: theme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      builder: (context, child) => ChatVisualSettingsRoot(
        child: DesktopNotificationListener(
          navigatorKey: _navigatorKey,
          child: PushNotificationListener(
            navigatorKey: _navigatorKey,
            child: SessionExpiryListener(
              navigatorKey: _navigatorKey,
              onRelogin: (canResume) {
                _resumeSession = canResume;
                _reloginUser = ref.read(currentUserProvider);
                clearActiveSessionState(ref, markSessionReady: true);
                _navigatorKey.currentState?.popUntil((route) => route.isFirst);
              },
              child: StorageMaintenanceRoot(
                child: AudioPlaybackRoot(child: child!),
              ),
            ),
          ),
        ),
      ),
      home: showMainApp
          ? const MatterApp()
          : LoginPage(
              initialHomeserver: _reloginUser?.homeserver,
              initialUserId: _reloginUser?.id,
              resumeSession: _resumeSession,
            ),
    );
  }

  (AppThemeStyle, Brightness, Color)? _lastOverlayStyle;

  /// 状态栏/导航栏图标亮度跟随主题明暗，底色跟随当前配色。
  void _syncSystemOverlayStyle(
    AppThemeStyle style,
    ThemeData theme,
    ThemeData darkTheme,
  ) {
    final platformBrightness = MediaQuery.platformBrightnessOf(context);
    final isDark = switch (style.themeMode) {
      ThemeMode.dark => true,
      ThemeMode.light => false,
      ThemeMode.system => platformBrightness == Brightness.dark,
    };
    final navColor = (isDark ? darkTheme : theme).scaffoldBackgroundColor;
    final overlayStyle = (style, platformBrightness, navColor);
    if (_lastOverlayStyle == overlayStyle) return;
    _lastOverlayStyle = overlayStyle;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      SystemChrome.setSystemUIOverlayStyle(
        SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: navColor,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarDividerColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
          systemStatusBarContrastEnforced: false,
        ),
      );
    });
  }
}
