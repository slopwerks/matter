import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../theme/tokens/app_typography.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

/// Both encryption dialogs share one scrollable overlay in each skin.
class EncryptionDialogSurface extends StatelessWidget {
  const EncryptionDialogSurface({
    super.key,
    required this.child,
    this.wideOnLandscape = false,
  });

  final Widget child;
  final bool wideOnLandscape;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: child,
          ),
        ),
      );
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: GlassPanel(
        radius: NeuRadius.nav,
        padding: const EdgeInsets.all(22),
        width:
            wideOnLandscape &&
                MediaQuery.widthOf(context) > MediaQuery.heightOf(context)
            ? MediaQuery.widthOf(context) * .5
            : null,
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}

class EncryptionDialogValueSurface extends StatelessWidget {
  const EncryptionDialogValueSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.neuColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? neuColor;

  @override
  Widget build(BuildContext context) => context.isMaterial
      ? Card(
          color: materialEncryptionValueStyle(Theme.of(context)).fill,
          child: Padding(padding: padding, child: child),
        )
      : NeuSurface(
          depth: NeuDepth.pressed,
          color: neuColor,
          radius: NeuRadius.button,
          padding: padding,
          child: child,
        );
}

class EncryptionRecoveryKeyDialog extends StatelessWidget {
  const EncryptionRecoveryKeyDialog({super.key, required this.recoveryKey});

  final String recoveryKey;

  @override
  Widget build(BuildContext dialogContext) => EncryptionDialogSurface(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '保存恢复密钥',
          style: dialogContext.isMaterial
              ? Theme.of(dialogContext).textTheme.headlineSmall
              : Theme.of(dialogContext).textTheme.titleMedium,
        ),
        const SizedBox(height: 6),
        Text(
          '这是恢复历史加密消息的最后保障。请保存到安全的位置，关闭后不会再次显示。',
          style: Theme.of(dialogContext).textTheme.bodyMedium,
        ),
        const SizedBox(height: 14),
        EncryptionDialogValueSurface(
          padding: const EdgeInsets.all(12),
          child: SelectableText(
            recoveryKey,
            style: dialogContext.isMaterial
                ? materialEncryptionValueStyle(Theme.of(dialogContext)).text
                : AppTypography.monospaceOf(
                    dialogContext,
                    base: Theme.of(dialogContext).textTheme.bodySmall,
                    height: 1.6,
                  ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: NeuButton(
                padding: const EdgeInsets.symmetric(vertical: 12),
                icon: const Icon(Icons.copy_rounded, size: 16),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: recoveryKey));
                  if (dialogContext.mounted) {
                    neuToast(dialogContext, '恢复密钥已复制');
                  }
                },
                child: const Center(child: Text('复制')),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: NeuButton(
                accent: true,
                padding: const EdgeInsets.symmetric(vertical: 12),
                onPressed: () => Navigator.pop(dialogContext),
                child: const Center(child: Text('我已保存')),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}
