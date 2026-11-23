import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';

/// Layout and branding only; the host retains authentication and form state.
class LoginLayout extends StatelessWidget {
  const LoginLayout({
    super.key,
    required this.addingAccount,
    required this.resumeSession,
    required this.modeSelector,
    required this.form,
  });

  final bool addingAccount;
  final bool resumeSession;
  final Widget modeSelector;
  final Widget form;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(context),
                        const SizedBox(height: 24),
                        Center(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: modeSelector,
                          ),
                        ),
                        const SizedBox(height: 20),
                        form,
                        const SizedBox(height: 24),
                        _footer(context),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SafeArea(
      top: !addingAccount,
      child: CustomScrollView(
        slivers: [
          if (addingAccount)
            SliverToBoxAdapter(
              child: SizedBox(
                height: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
              ),
            ),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    children: [
                      const SizedBox(height: 40),
                      _header(context),
                      const SizedBox(height: 32),
                      modeSelector,
                      const SizedBox(height: 20),
                      form,
                      const Spacer(),
                      _footer(context),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    if (context.isMaterial) {
      final style = materialAuthStyle(theme);
      return Column(
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: style.brandFill,
            foregroundColor: style.brandForeground,
            child: const Icon(Icons.chat_bubble_rounded, size: 32),
          ),
          const SizedBox(height: 16),
          Text(
            addingAccount
                ? '添加另一个账号'
                : resumeSession
                ? '重新登录'
                : 'Matter',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            addingAccount
                ? '登录或创建另一个账号，已有账号将继续保留。'
                : resumeSession
                ? '登录以继续使用此账号。'
                : '使用 Matrix 账号，让对话自然发生。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      );
    }
    return Center(
      child: Column(
        children: [
          NeuSurface(
            accent: true,
            width: 88,
            height: 88,
            radius: NeuRadius.nav,
            child: Icon(
              Icons.chat_bubble_rounded,
              size: 40,
              color: context.neu.onAccent,
            ),
          ),
          const SizedBox(height: 22),
          Text(
            'Matter',
            style: theme.textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
            ),
          ),
          const SizedBox(height: NeuSpacing.sm),
          Text('Matrix 客户端', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _footer(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Text(
        'Made with AI by Matter Team',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}
