import 'package:material_ui/material_ui.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_surface.dart';

/// The four attachment modes offered by the floating frosted-glass bar.
enum AttachmentTab { media, file, poll, location }

const attachmentDockHeight = 72.0;
const attachmentDockGap = 8.0;
const attachmentSendButtonHeight = 44.0;
const attachmentDockClearance = attachmentDockHeight + attachmentDockGap;
const attachmentSendBarClearance =
    attachmentDockClearance + attachmentSendButtonHeight + attachmentDockGap;

class AttachmentTabBar extends StatelessWidget {
  final AttachmentTab tab;
  final bool isFileBusy;
  final ValueChanged<AttachmentTab>? onTabChanged;

  const AttachmentTabBar({
    super.key,
    required this.tab,
    required this.isFileBusy,
    required this.onTabChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = const [
      _TabItem(AttachmentTab.media, Icons.photo_library_rounded, '图片'),
      _TabItem(AttachmentTab.file, Icons.folder_rounded, '文件'),
      _TabItem(AttachmentTab.poll, Icons.poll_rounded, '投票'),
      _TabItem(AttachmentTab.location, Icons.location_on_rounded, '地址'),
    ];
    if (context.isMaterial) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: SizedBox(
          key: const ValueKey('attachment-tab-bar'),
          height: attachmentDockHeight - attachmentDockGap,
          child: NavigationBar(
            height: attachmentDockHeight - attachmentDockGap,
            selectedIndex: tab.index,
            onDestinationSelected: onTabChanged == null
                ? null
                : (index) => onTabChanged!(AttachmentTab.values[index]),
            destinations: [
              for (final item in items)
                NavigationDestination(
                  enabled: onTabChanged != null,
                  icon: item.tab == AttachmentTab.file && isFileBusy
                      ? const SizedBox.square(
                          dimension: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(item.icon),
                  label: item.label,
                ),
            ],
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SizedBox(
        key: const ValueKey('attachment-tab-bar'),
        height: attachmentDockHeight - attachmentDockGap,
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (final item in items)
                _TabButton(
                  item: item,
                  selected: tab == item.tab,
                  busy: item.tab == AttachmentTab.file && isFileBusy,
                  onTap: onTabChanged == null
                      ? null
                      : () => onTabChanged!(item.tab),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final AttachmentTab tab;
  final IconData icon;
  final String label;
  const _TabItem(this.tab, this.icon, this.label);
}

class _TabButton extends StatelessWidget {
  final _TabItem item;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;

  const _TabButton({
    required this.item,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final color = selected ? colors.accent : colors.textTertiary;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.accent,
                ),
              )
            else
              Icon(item.icon, color: color, size: 24),
            const SizedBox(height: 2),
            Text(
              item.label,
              style: Theme.of(context).textTheme.labelSmall
                  ?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class AttachmentSendBar extends StatelessWidget {
  final String label;
  final bool isSending;
  final bool enabled;
  final VoidCallback onSend;

  const AttachmentSendBar({
    super.key,
    required this.label,
    required this.isSending,
    required this.onSend,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final active = enabled && !isSending;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, attachmentDockClearance),
        child: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            height: attachmentSendButtonHeight,
            child: context.isMaterial
                ? FilledButton.icon(
                    key: const ValueKey('attachment-send-button'),
                    onPressed: active ? onSend : null,
                    icon: isSending
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onAccent,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                    label: Text(label),
                  )
                : NeuButton(
                    key: const ValueKey('attachment-send-button'),
                    accent: true,
                    radius: NeuRadius.nav,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    onPressed: active ? onSend : null,
                    icon: isSending
                        ? SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: colors.onAccent,
                            ),
                          )
                        : const Icon(Icons.send_rounded),
                    child: Text(label),
                  ),
          ),
        ),
      ),
    );
  }
}
