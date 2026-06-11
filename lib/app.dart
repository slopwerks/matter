import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/chat/chat_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/settings/settings_page.dart';
import 'providers/chat_provider.dart';
import 'providers/navigation_provider.dart';
import 'theme/app_theme.dart';
import 'widgets/liquid_glass.dart';

class MatterApp extends ConsumerStatefulWidget {
  const MatterApp({super.key});

  @override
  ConsumerState<MatterApp> createState() => _MatterAppState();
}

class _MatterAppState extends ConsumerState<MatterApp> {
  final _pageController = PageController();

  static const _pages = [
    ChatPage(),
    ContactsPage(),
    SettingsPage(),
  ];

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
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
            ref.read(navigationIndexProvider.notifier).state = index;
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
                icon: Icons.people_outline_rounded,
                activeIcon: Icons.people_rounded,
                label: '通讯录',
                isActive: ref.watch(navigationIndexProvider) == 1,
                onTap: () => _onItemTapped(1),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: '设置',
                isActive: ref.watch(navigationIndexProvider) == 2,
                onTap: () => _onItemTapped(2),
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
            Icon(
              isActive ? activeIcon : icon,
              color: color,
              size: 22,
            ),
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
