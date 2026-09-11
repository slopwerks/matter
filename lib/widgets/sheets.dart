import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'glass.dart';
import 'neu_field.dart';
import 'neu_surface.dart';

/// 统一的磨砂玻璃底部弹层容器。
Future<T?> showNeuSheet<T>({
  required BuildContext context,
  required Widget child,
  double maxWidth = 420,
}) {
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black26,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight:
                    (MediaQuery.sizeOf(sheetContext).height * .85 -
                            MediaQuery.viewInsetsOf(sheetContext).bottom)
                        .clamp(0.0, double.infinity),
              ),
              child: GlassPanel(
                radius: NeuRadius.nav,
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SingleChildScrollView(child: child),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 弹层里的菜单条目(图标 + 文案)。
class NeuSheetItem extends StatelessWidget {
  const NeuSheetItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return InkWell(
      borderRadius: BorderRadius.circular(NeuRadius.button),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
        child: Row(
          children: [
            Icon(icon, size: 18, color: color ?? colors.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// 弹层条目之间的细分隔线。
class NeuSheetDivider extends StatelessWidget {
  const NeuSheetDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 16),
      color: context.neu.hairline,
    );
  }
}

/// 玻璃确认对话框。
Future<bool> showNeuConfirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  String cancelLabel = '取消',
  bool danger = false,
  bool barrierDismissible = true,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      child: GlassPanel(
        radius: NeuRadius.nav,
        padding: const EdgeInsets.all(22),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message, style: Theme.of(ctx).textTheme.bodyMedium),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: NeuButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: Center(child: Text(cancelLabel)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: NeuButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: Center(
                        child: Text(
                          confirmLabel,
                          style: TextStyle(
                            color: danger ? ctx.neu.error : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return confirmed == true;
}

/// 单行输入对话框,返回输入内容(取消返回 null)。
Future<String?> showNeuPrompt(
  BuildContext context, {
  required String title,
  String? message,
  String hint = '',
  String initial = '',
  String confirmLabel = '确定',
  int maxLines = 1,
  bool multiline = false,
  bool obscureText = false,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 32),
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                if (message != null) ...[
                  const SizedBox(height: 6),
                  Text(message, style: Theme.of(ctx).textTheme.bodyMedium),
                ],
                const SizedBox(height: 16),
                NeuTextField(
                  controller: controller,
                  hint: hint,
                  maxLines: multiline ? 3 : maxLines,
                  obscureText: obscureText,
                  autofocus: true,
                  onSubmitted: (v) => Navigator.of(ctx).pop(v),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: NeuButton(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Center(child: Text('取消')),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: NeuButton(
                        accent: true,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: () => Navigator.of(ctx).pop(controller.text),
                        child: Center(child: Text(confirmLabel)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 统一的原型提示:超椭圆浮层 SnackBar,新拟物配色。
void neuToast(BuildContext context, String message) {
  final colors = context.neu;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors.text),
        ),
        backgroundColor: colors.surfaceStrong,
        elevation: 0,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        duration: const Duration(milliseconds: 1500),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(NeuRadius.surface),
          side: BorderSide(color: colors.hairline),
        ),
      ),
    );
}
