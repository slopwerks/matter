import 'package:flutter/material.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/material_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/material_press.dart';

/// Presentation only: membership and ignore actions stay with the room host.
class MaterialRoomMemberRow extends StatelessWidget {
  const MaterialRoomMemberRow({
    super.key,
    required this.member,
    required this.isCurrentUser,
    required this.ignored,
    required this.tooltip,
    required this.onToggleIgnored,
  });

  final rust.Contact member;
  final bool isCurrentUser;
  final bool ignored;
  final String tooltip;
  final VoidCallback? onToggleIgnored;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: _MemberIdentity(
      name: member.name,
      userId: member.id,
      avatarUrl: member.avatarUrl,
      trailing: isCurrentUser
          ? null
          : IconButton(
              tooltip: tooltip,
              isSelected: ignored,
              icon: const Icon(Icons.block_rounded),
              selectedIcon: const Icon(Icons.person_add_alt_rounded),
              onPressed: onToggleIgnored,
            ),
    ),
  );
}

class MaterialRoomKnockRow extends StatelessWidget {
  const MaterialRoomKnockRow({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  final rust.KnockRequest request;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MemberIdentity(
          name: request.displayName,
          userId: request.userId,
          avatarUrl: request.avatarUrl,
          reason: request.reason,
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            Tooltip(
              message: '拒绝',
              child: OutlinedButton.icon(
                onPressed: onReject,
                icon: const Icon(Icons.close_rounded, size: 18),
                label: const Text('拒绝'),
              ),
            ),
            Tooltip(
              message: '批准',
              child: MaterialPress(
                builder: (states) => FilledButton.tonalIcon(
                  statesController: states,
                  style: MaterialPress.feedbackStyle,
                  onPressed: onApprove,
                  icon: const Icon(Icons.check_rounded, size: 18),
                  label: const Text('批准'),
                ),
              ),
            ),
          ],
        ),
      ],
    ),
  );
}

class _MemberIdentity extends StatelessWidget {
  const _MemberIdentity({
    required this.name,
    required this.userId,
    this.avatarUrl,
    this.reason,
    this.trailing,
  });

  final String name;
  final String userId;
  final String? avatarUrl;
  final String? reason;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppAvatar(fallback: name, url: avatarUrl, size: materialListAvatarSize),
        const SizedBox(width: materialListContentGap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: materialListTitleStyle(theme)),
              const SizedBox(height: 2),
              Text(userId, style: theme.textTheme.bodySmall),
              if (reason?.isNotEmpty == true) ...[
                const SizedBox(height: 8),
                Text(reason!, style: theme.textTheme.bodyMedium),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 4), trailing!],
      ],
    );
  }
}
