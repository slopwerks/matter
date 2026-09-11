import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

class CreateChatPage extends ConsumerStatefulWidget {
  const CreateChatPage({super.key});

  @override
  ConsumerState<CreateChatPage> createState() => _CreateChatPageState();
}

class _CreateChatPageState extends ConsumerState<CreateChatPage> {
  final _searchController = TextEditingController();
  bool _isCreating = false;

  /// Map a failed write's error to the unified timeout wording (same
  /// discipline as the room management page): a queue-wait timeout means
  /// the write may still be landing in its background tail.
  String _actionFailureMessage(Object error) => actionFailureMessage(error);

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createDm(String userId) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    // Account snapshot: a switch while the request is in flight must not
    // redirect the write (and suppresses the feedback below).
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      await rust.createDm(accountUserId: accountUserId, userId: userId);
      // The account may have switched while the request was in flight:
      // skip ALL local feedback (same discipline as the other pages).
      // `mounted` first: `ref.read` throws after unmount (Riverpod
      // asserts on disposed widgets).
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      // Refresh all room sources like every other write path: the new
      // room must appear in the ungrouped/space lists too (the sync echo
      // would eventually cover it, but not while sync is stalled).
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spacesProvider);
      ref.invalidate(searchRoomsProvider);
      if (mounted) {
        neuToast(context, '私聊已创建');
        // `isCurrent` guard: another modal (e.g. the device-verification
        // dialog) may sit above this page — popping then would dismiss
        // that dialog instead.
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      if (mounted) {
        neuToast(context, _actionFailureMessage(e));
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  Future<void> _createGroup(String name) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    // Account snapshot: a switch while the request is in flight must not
    // redirect the write (and suppresses the feedback below).
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      await rust.createGroupRoom(
        accountUserId: accountUserId,
        name: name,
        topic: null,
      );
      // The account may have switched while the request was in flight:
      // skip ALL local feedback (same discipline as the other pages).
      // `mounted` first: `ref.read` throws after unmount (Riverpod
      // asserts on disposed widgets).
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      // Refresh all room sources like every other write path: the new
      // room must appear in the ungrouped/space lists too (the sync echo
      // would eventually cover it, but not while sync is stalled).
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spacesProvider);
      ref.invalidate(searchRoomsProvider);
      if (mounted) {
        neuToast(context, '群组已创建');
        // `isCurrent` guard: another modal may sit above this page.
        if (ModalRoute.of(context)?.isCurrent == true) {
          Navigator.of(context).pop();
        }
      }
    } catch (e) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) return;
      if (mounted) {
        neuToast(context, _actionFailureMessage(e));
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  void _showCreateGroupDialog() {
    var groupName = '';
    String? groupNameError;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => _NeuDialog(
          title: '创建群组',
          actions: [
            NeuButton(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Center(child: Text('取消')),
            ),
            NeuButton(
              accent: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: () {
                final name = groupName.trim();
                if (name.isEmpty) {
                  // Feedback instead of silently closing the dialog (same
                  // discipline as the space dialogs).
                  setDialogState(() => groupNameError = '群组名称不能为空');
                  return;
                }
                Navigator.of(ctx).pop();
                _createGroup(name);
              },
              child: const Center(child: Text('创建')),
            ),
          ],
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuTextField(
                hint: '群组名称',
                onChanged: (value) => groupName = value,
              ),
              if (groupNameError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    groupNameError!,
                    style: Theme.of(
                      ctx,
                    ).textTheme.bodyMedium?.copyWith(color: ctx.neu.error),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showJoinRoomDialog() {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account.
    final dialogAccountUserId = ref.read(activeUserIdProvider) ?? '';
    var roomIdentifier = '';
    var joining = false;
    String? joinError;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => _NeuDialog(
          title: '加入房间',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NeuTextField(
                hint: '!room_id:matrix.akass.cn',
                onChanged: (value) => roomIdentifier = value,
              ),
              if (joinError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    joinError!,
                    style: Theme.of(
                      ctx,
                    ).textTheme.bodyMedium?.copyWith(color: ctx.neu.error),
                  ),
                ),
            ],
          ),
          actions: [
            NeuButton(
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: joining ? null : () => Navigator.of(ctx).pop(),
              child: const Center(child: Text('取消')),
            ),
            NeuButton(
              accent: true,
              padding: const EdgeInsets.symmetric(vertical: 12),
              onPressed: joining
                  ? null
                  : () async {
                      // Entry guard (not only the disabled button): the
                      // rebuild lags a frame, so a second tap on the old
                      // widget could otherwise issue a duplicate join.
                      if (joining) return;
                      final value = roomIdentifier.trim();
                      if (value.isEmpty) {
                        // Feedback instead of a silent no-op (same
                        // discipline as the create-group dialog).
                        setDialogState(() => joinError = '请输入房间 ID 或别名');
                        return;
                      }
                      setDialogState(() {
                        joining = true;
                        joinError = null;
                      });
                      try {
                        await rust.joinRoom(
                          // Account snapshot captured when the dialog
                          // OPENED (see above), not read at tap time.
                          accountUserId: dialogAccountUserId,
                          identifier: value,
                        );
                        // The account may have switched while the request
                        // was in flight: skip ALL local feedback (same
                        // discipline as the other pages) and close the
                        // dialog — it would otherwise stay stuck in its
                        // in-flight state. `mounted` first: `ref.read`
                        // throws after unmount.
                        if (!mounted) return;
                        if (ref.read(activeUserIdProvider) !=
                            dialogAccountUserId) {
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          return;
                        }
                        ref.invalidate(chatRoomsProvider);
                        ref.invalidate(ungroupedRoomsProvider);
                        ref.invalidate(spacesProvider);
                        ref.invalidate(searchRoomsProvider);
                        if (!mounted) return;
                        // `isCurrent` guard: the dialog may already be in
                        // its exit animation — popping then would pop the
                        // page below it.
                        if (ctx.mounted &&
                            ModalRoute.of(ctx)?.isCurrent == true) {
                          Navigator.of(ctx).pop();
                        }
                        // The dialog may have been dismissed while the
                        // request was in flight: still report success.
                        neuToast(context, '已加入房间');
                      } catch (e) {
                        if (!mounted) return;
                        // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                        if (ref.read(activeUserIdProvider) !=
                            dialogAccountUserId) {
                          if (ctx.mounted &&
                              ModalRoute.of(ctx)?.isCurrent == true) {
                            Navigator.of(ctx).pop();
                          }
                          return;
                        }
                        if (ctx.mounted) {
                          setDialogState(() {
                            joining = false;
                            // Render the failure inside the dialog: a
                            // page-level snackbar would sit beneath the
                            // modal barrier while the dialog stays open
                            // for retry.
                            joinError = _actionFailureMessage(e);
                          });
                        } else {
                          neuToast(context, _actionFailureMessage(e));
                        }
                      }
                    },
              child: joining
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: context.neu.onAccent,
                        strokeWidth: 2,
                      ),
                    )
                  : const Center(child: Text('加入')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Scaffold(
      backgroundColor: colors.base,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.sm,
                NeuSpacing.sm,
                NeuSpacing.lg,
                NeuSpacing.xs,
              ),
              child: Row(
                children: [
                  NeuIconButton(
                    icon: Icons.arrow_back_ios_new_rounded,
                    size: 40,
                    tooltip: '返回',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: NeuSpacing.sm),
                  Text('新建聊天', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
            Expanded(
              child: MaxContentWidth(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    NeuSpacing.lg,
                    NeuSpacing.sm,
                    NeuSpacing.lg,
                    NeuSpacing.xl,
                  ),
                  children: [
                    NeuTextField(
                      controller: _searchController,
                      hint: '输入 @用户 ID 发起私聊',
                      leading: const Icon(Icons.search_rounded),
                      textInputAction: TextInputAction.go,
                      onSubmitted: (value) {
                        final trimmed = value.trim();
                        if (trimmed.isNotEmpty) _createDm(trimmed);
                      },
                    ),
                    const SizedBox(height: NeuSpacing.md),
                    NeuButton(
                      accent: true,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      onPressed: _isCreating
                          ? null
                          : () {
                              final trimmed = _searchController.text.trim();
                              if (trimmed.isNotEmpty) _createDm(trimmed);
                            },
                      child: _isCreating
                          ? SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: colors.onAccent,
                                strokeWidth: 2,
                              ),
                            )
                          : const Text('发起私聊'),
                    ),
                    const SizedBox(height: NeuSpacing.xl),
                    _ActionCard(
                      icon: Icons.group_add_rounded,
                      iconColor: colors.accent,
                      title: '创建群组',
                      subtitle: '创建一个新的群聊房间',
                      onTap: _showCreateGroupDialog,
                    ),
                    const SizedBox(height: NeuSpacing.md),
                    _ActionCard(
                      icon: Icons.meeting_room_rounded,
                      iconColor: colors.warning,
                      title: '加入房间',
                      subtitle: '通过房间 ID 加入已有房间',
                      onTap: _showJoinRoomDialog,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return NeuAction(
      radius: NeuRadius.content,
      label: title,
      onTap: onTap,
      child: NeuSurface(
        color: colors.card,
        radius: NeuRadius.content,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            NeuSurface(
              depth: NeuDepth.flat,
              color: iconColor.withValues(alpha: 0.14),
              radius: NeuRadius.button,
              width: 44,
              height: 44,
              child: Center(child: Icon(icon, color: iconColor, size: 20)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: colors.textTertiary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// 新拟物玻璃对话框容器:标题 + 内容 + 等宽按钮行。
class _NeuDialog extends StatelessWidget {
  const _NeuDialog({
    required this.title,
    required this.content,
    required this.actions,
  });

  final String title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
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
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              content,
              const SizedBox(height: 18),
              Row(
                children: [
                  for (var index = 0; index < actions.length; index++) ...[
                    if (index > 0) const SizedBox(width: 12),
                    Expanded(child: actions[index]),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
