import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/chat/chat_page.dart';
import 'pages/chat/space_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/settings/encryption_page.dart';
import 'pages/settings/settings_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/navigation_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'theme/app_theme.dart';
import 'widgets/liquid_glass.dart';

class MatterApp extends ConsumerStatefulWidget {
  const MatterApp({super.key});

  @override
  ConsumerState<MatterApp> createState() => _MatterAppState();
}

class _MatterAppState extends ConsumerState<MatterApp> {
  final _pageController = PageController();
  Timer? _verificationTimer;
  bool _checkingVerification = false;
  bool _verificationDialogOpen = false;
  final Set<String> _handledVerificationFlows = {};

  static const _pages = [
    ChatPage(),
    SpacePage(),
    ContactsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _verificationTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkIncomingVerification(),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkIncomingVerification(),
    );
  }

  @override
  void dispose() {
    _verificationTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _checkIncomingVerification() async {
    if (_checkingVerification ||
        _verificationDialogOpen ||
        !mounted ||
        !ref.read(sessionReadyProvider)) {
      return;
    }

    _checkingVerification = true;
    try {
      final status = await rust.getDeviceVerificationStatus();
      if (!mounted ||
          status == null ||
          !status.incoming ||
          status.phase != 'requested' ||
          _handledVerificationFlows.contains(status.flowId)) {
        return;
      }
      _handledVerificationFlows.add(status.flowId);
      await _showVerificationRequest(status);
    } catch (_) {
      // The active client can be temporarily unavailable during account changes.
    } finally {
      _checkingVerification = false;
    }
  }

  Future<void> _showVerificationRequest(
    rust.DeviceVerificationStatus status,
  ) async {
    _verificationDialogOpen = true;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设备验证请求'),
        content: Text('设备 ${status.deviceId} 正在请求验证当前设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('接受'),
          ),
        ],
      ),
    );
    _verificationDialogOpen = false;
    if (!mounted) return;

    try {
      if (accepted == true) {
        await rust.acceptDeviceVerification();
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const EncryptionPage()));
      } else {
        await rust.cancelDeviceVerification(mismatch: false);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('处理设备验证失败：$error')));
    }
  }

  void _onItemTapped(int index) {
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keep the sync stream listener alive for the app's lifetime.
    // Without watch(), the provider auto-disposes and stops receiving events.
    ref.watch(syncStreamProvider);

    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _pageController,
        children: _pages,
        onPageChanged: (index) {
          if (ref.read(navigationIndexProvider) != index) {
            ref.read(navigationIndexProvider.notifier).value = index;
          }
        },
      ),
      bottomNavigationBar: LiquidGlassContainer(
        borderRadius: AppRadii.nav,
        blurSigma: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _NavItem(
                icon: Icons.chat_bubble_outline_rounded,
                activeIcon: Icons.chat_bubble_rounded,
                label: '聊天',
                isActive: ref.watch(navigationIndexProvider) == 0,
                onTap: () => _onItemTapped(0),
              ),
              _NavItem(
                icon: Icons.account_tree_outlined,
                activeIcon: Icons.account_tree_rounded,
                label: '空间',
                isActive: ref.watch(navigationIndexProvider) == 1,
                onTap: () => _onItemTapped(1),
              ),
              _NavItem(
                icon: Icons.people_outline_rounded,
                activeIcon: Icons.people_rounded,
                label: '通讯录',
                isActive: ref.watch(navigationIndexProvider) == 2,
                onTap: () => _onItemTapped(2),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: '设置',
                isActive: ref.watch(navigationIndexProvider) == 3,
                onTap: () => _onItemTapped(3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? AppColors.primary : AppColors.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(isActive ? activeIcon : icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
