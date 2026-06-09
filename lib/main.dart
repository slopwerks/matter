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
    const ProviderScope(
      child: _AppRoot(),
    ),
  );
}

class _AppRoot extends ConsumerStatefulWidget {
  const _AppRoot();

  @override
  ConsumerState<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends ConsumerState<_AppRoot> {
  bool _isRestoring = true;

  @override
  void initState() {
    super.initState();
    _tryRestoreSession();
  }

  Future<void> _tryRestoreSession() async {
    try {
      final session = await loadPersistedSession();
      if (session != null) {
        final dataDir = (await getApplicationSupportDirectory()).path;
        await rust.restoreSession(session: session, dataDir: dataDir);
        final displayName = await loadPersistedDisplayName() ?? session.userId.split(':').first.replaceFirst('@', '');

        ref.read(isLoggedInProvider.notifier).state = true;
        ref.read(currentUserProvider.notifier).state = CurrentUser(
          id: session.userId,
          displayName: displayName,
          homeserver: session.homeserverUrl,
        );
        ref.read(homeserverProvider.notifier).state = session.homeserverUrl;

        // Sync + start background sync
        await rust.syncOnce();
        ref.invalidate(chatRoomsProvider);
        await rust.startSync();
        // Connected now
        if (mounted) {
          ref.read(connectionProvider.notifier).state = AppConnectionState.connected;
        }
      }
    } catch (e) {
      debugPrint('Session restore failed: $e');
      // Clear corrupted session
      await clearPersistedSession();
    } finally {
      if (mounted) {
        setState(() => _isRestoring = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRestoring) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(
          backgroundColor: AppColors.background,
          body: Center(
            child: CircularProgressIndicator(color: AppColors.primary),
          ),
        ),
      );
    }

    final isLoggedIn = ref.watch(isLoggedInProvider);

    return MaterialApp(
      title: 'Matter',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: isLoggedIn ? const MatterApp() : const LoginPage(),
    );
  }
}
