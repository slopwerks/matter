import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'action_failure_message.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/cascade_title.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'chat_list_item.dart';
import 'space_detail_page.dart';

class SpacePage extends ConsumerWidget {
  const SpacePage({super.key});

  /// Map a failed write's error to the unified timeout wording (same
  /// discipline as the room management page): a queue-wait timeout means
  /// the write may still be landing in its background tail.
  static String _actionFailureMessage(Object error) =>
      actionFailureMessage(error);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(spacesProvider);
    final ungroupedAsync = ref.watch(ungroupedRoomsProvider);
    final connectionLabel = ref.watch(connectionLabelProvider);
    final titleText = connectionLabel.isNotEmpty ? connectionLabel : '空间';

    return Scaffold(
      backgroundColor: context.neu.base,
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                pinned: true,
                expandedHeight: 56,
                collapsedHeight: 56,
                toolbarHeight: 56,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.only(left: 16, bottom: 12),
                  title: CascadeTitle(
                    text: titleText,
                    style: Theme.of(context).textTheme.titleLarge!,
                  ),
                ),
                backgroundColor: context.neu.base,
                scrolledUnderElevation: 0,
              ),
              const SliverToBoxAdapter(child: SizedBox(height: NeuSpacing.md)),
              spacesAsync.when(
                data: (spaces) {
                  if (spaces.isEmpty) {
                    return const SliverToBoxAdapter(
                      child: _SectionCard(
                        title: '空间',
                        subtitle: '暂无已加入空间',
                        child: _HintText('当前账号还没有可浏览的空间。'),
                      ),
                    );
                  }

                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '空间',
                      subtitle: '用于组织房间和成员，不直接作为聊天入口',
                      child: Column(
                        children: [
                          for (final space in spaces)
                            _SpaceRoomTile(
                              space: space,
                              key: ValueKey(space.id),
                            ),
                        ],
                      ),
                    ),
                  );
                },
                loading: () => SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(NeuSpacing.xl),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: context.neu.accent,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
                error: (err, _) => SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(NeuSpacing.lg),
                    child: Text(
                      '加载空间失败: $err',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: NeuSpacing.md)),
              ungroupedAsync.when(
                data: (rooms) {
                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '未归属群组',
                      subtitle: '这些房间当前不属于任何已加入空间',
                      child: rooms.isEmpty
                          ? const _HintText('暂无普通房间')
                          : Column(
                              children: [
                                for (final room in rooms)
                                  ChatListItem(
                                    room: room,
                                    dense: true,
                                    showRoomTypeIcon: true,
                                  ),
                              ],
                            ),
                    ),
                  );
                },
                loading: () =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
                error: (_, _) =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: NeuIconButton(
              icon: Icons.add_rounded,
              size: 56,
              accent: true,
              tooltip: '新建空间',
              onPressed: () => _showSpaceActions(context),
            ),
          ),
        ],
      ),
    );
  }

  void _showSpaceActions(BuildContext context) {
    // The Builder below provides the sheet's own context, which is unmounted
    // once the sheet is dismissed. The create/join dialogs opened from here
    // keep the PAGE context for their async completion paths (their writes
    // can outlive the sheet's exit animation — feedback must not vanish
    // with it).
    final pageContext = context;
    showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '空间',
                  style: Theme.of(sheetContext).textTheme.titleSmall,
                ),
              ),
            ),
            NeuSheetItem(
              icon: Icons.create_new_folder_rounded,
              label: '创建空间',
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showCreateSpaceDialog(pageContext);
              },
            ),
            NeuSheetItem(
              icon: Icons.travel_explore_rounded,
              label: '加入空间',
              onTap: () {
                Navigator.of(sheetContext).pop();
                _showJoinSpaceDialog(pageContext);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showCreateSpaceDialog(BuildContext context) {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account (same
    // discipline as every other P0 write path).
    final container = ProviderScope.containerOf(context, listen: false);
    final dialogAccountUserId = container.read(activeUserIdProvider) ?? '';
    var spaceName = '';
    var spaceTopic = '';
    var creating = false;
    String? createError;
    // (The page-scoped container is captured at the top of this method.)
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (_, ref, _) => StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
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
                    Text('创建空间', style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    NeuTextField(
                      hint: '空间名称',
                      onChanged: (value) => spaceName = value,
                    ),
                    const SizedBox(height: 12),
                    NeuTextField(
                      hint: '空间说明（可选）',
                      onChanged: (value) => spaceTopic = value,
                    ),
                    if (createError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          createError!,
                          style: Theme.of(
                            ctx,
                          ).textTheme.bodySmall?.copyWith(color: ctx.neu.error),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: NeuButton(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: creating
                                ? null
                                : () => Navigator.of(ctx).pop(),
                            child: const Center(child: Text('取消')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NeuButton(
                            accent: true,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: creating
                                ? null
                                : () async {
                                    // Entry guard (not only the disabled
                                    // button): the rebuild lags a frame, so a
                                    // second tap on the old widget could
                                    // otherwise create two spaces.
                                    if (creating) return;
                                    final name = spaceName.trim();
                                    final topic = spaceTopic.trim();
                                    if (name.isEmpty) {
                                      // Feedback instead of a silent no-op
                                      // (same as the room management save
                                      // path).
                                      setDialogState(
                                        () => createError = '空间名称不能为空',
                                      );
                                      return;
                                    }
                                    setDialogState(() {
                                      creating = true;
                                      createError = null;
                                    });
                                    try {
                                      await createSpace(
                                        // Account snapshot captured when the
                                        // dialog OPENED (see above), not read
                                        // at tap time.
                                        accountUserId: dialogAccountUserId,
                                        name: name,
                                        topic: topic.isEmpty ? null : topic,
                                      );
                                      // The account may have switched while
                                      // the request was in flight: skip ALL
                                      // local feedback (same discipline as
                                      // the other pages) and close the
                                      // dialog — it would otherwise stay
                                      // stuck in its in-flight state above
                                      // the new account's page.
                                      if (container.read(
                                            activeUserIdProvider,
                                          ) !=
                                          dialogAccountUserId) {
                                        if (ctx.mounted &&
                                            ModalRoute.of(ctx)?.isCurrent ==
                                                true) {
                                          Navigator.of(ctx).pop();
                                        }
                                        return;
                                      }
                                      container.invalidate(spacesProvider);
                                      container.invalidate(chatRoomsProvider);
                                      if (!context.mounted) return;
                                      // `isCurrent` guards against popping
                                      // the page when the dialog was
                                      // dismissed during its exit transition
                                      // (mounted stays true through it).
                                      if (ctx.mounted &&
                                          ModalRoute.of(ctx)?.isCurrent ==
                                              true) {
                                        Navigator.of(ctx).pop();
                                      }
                                      // The dialog may have been dismissed
                                      // while the request was in flight:
                                      // still report success.
                                      neuToast(context, '空间已创建');
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），
                                      // 并关闭卡在 in-flight 态的对话框。
                                      if (container.read(
                                            activeUserIdProvider,
                                          ) !=
                                          dialogAccountUserId) {
                                        if (ctx.mounted &&
                                            ModalRoute.of(ctx)?.isCurrent ==
                                                true) {
                                          Navigator.of(ctx).pop();
                                        }
                                        return;
                                      }
                                      if (ctx.mounted) {
                                        setDialogState(() {
                                          creating = false;
                                          // Render the failure inside the
                                          // dialog: a page-level toast would
                                          // sit beneath the modal barrier
                                          // while the dialog stays open.
                                          createError = _actionFailureMessage(
                                            e,
                                          );
                                        });
                                      } else {
                                        neuToast(
                                          context,
                                          _actionFailureMessage(e),
                                        );
                                      }
                                    }
                                  },
                            child: creating
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: ctx.neu.onAccent,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Center(child: Text('创建')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showJoinSpaceDialog(BuildContext context) {
    // Account snapshot captured when the dialog OPENS: a switch while the
    // dialog is up must not redirect the write to the new account.
    final container = ProviderScope.containerOf(context, listen: false);
    final dialogAccountUserId = container.read(activeUserIdProvider) ?? '';
    var spaceIdentifier = '';
    var joining = false;
    String? joinError;
    // (The page-scoped container is captured at the top of this method.)
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        // `_` for the dialog-scoped context: the async closures below must
        // use the PAGE context (method parameter) so feedback still lands
        // after the dialog was dismissed mid-request.
        builder: (_, ref, _) => StatefulBuilder(
          builder: (ctx, setDialogState) => Dialog(
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
                    Text('加入空间', style: Theme.of(ctx).textTheme.titleMedium),
                    const SizedBox(height: 16),
                    NeuTextField(
                      hint: '!space_id:server 或 #alias:server',
                      onChanged: (value) => spaceIdentifier = value,
                    ),
                    if (joinError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          joinError!,
                          style: Theme.of(
                            ctx,
                          ).textTheme.bodySmall?.copyWith(color: ctx.neu.error),
                        ),
                      ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: NeuButton(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: joining
                                ? null
                                : () => Navigator.of(ctx).pop(),
                            child: const Center(child: Text('取消')),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: NeuButton(
                            accent: true,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            onPressed: joining
                                ? null
                                : () async {
                                    // Entry guard (not only the disabled
                                    // button): the rebuild lags a frame, so a
                                    // second tap on the old widget could
                                    // otherwise issue a duplicate join.
                                    if (joining) return;
                                    final value = spaceIdentifier.trim();
                                    if (value.isEmpty) {
                                      // Feedback instead of a silent no-op
                                      // (same discipline as the create-space
                                      // dialog).
                                      setDialogState(
                                        () => joinError = '请输入空间 ID 或别名',
                                      );
                                      return;
                                    }
                                    setDialogState(() {
                                      joining = true;
                                      joinError = null;
                                    });
                                    try {
                                      await joinRoom(
                                        // Account snapshot captured when the
                                        // dialog OPENED (see above), not read
                                        // at tap time.
                                        accountUserId: dialogAccountUserId,
                                        identifier: value,
                                      );
                                      // The account may have switched while
                                      // the request was in flight: skip ALL
                                      // local feedback (same discipline as
                                      // the other pages) and close the
                                      // dialog — it would otherwise stay
                                      // stuck in its in-flight state above
                                      // the new account's page.
                                      if (container.read(
                                            activeUserIdProvider,
                                          ) !=
                                          dialogAccountUserId) {
                                        if (ctx.mounted &&
                                            ModalRoute.of(ctx)?.isCurrent ==
                                                true) {
                                          Navigator.of(ctx).pop();
                                        }
                                        return;
                                      }
                                      // Page-scoped container: the
                                      // dialog-scoped ref is disposed (and
                                      // would throw) once the dialog was
                                      // dismissed mid-request.
                                      container.invalidate(spacesProvider);
                                      container.invalidate(chatRoomsProvider);
                                      container.invalidate(
                                        ungroupedRoomsProvider,
                                      );
                                      if (!context.mounted) return;
                                      // `isCurrent` guards against popping
                                      // the page when the dialog was
                                      // dismissed during its exit transition
                                      // (mounted stays true through it).
                                      if (ctx.mounted &&
                                          ModalRoute.of(ctx)?.isCurrent ==
                                              true) {
                                        Navigator.of(ctx).pop();
                                      }
                                      // The dialog may have been dismissed
                                      // while the request was in flight:
                                      // still report success.
                                      neuToast(context, '已加入空间');
                                    } catch (e) {
                                      if (!context.mounted) return;
                                      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），
                                      // 并关闭卡在 in-flight 态的对话框。
                                      if (container.read(
                                            activeUserIdProvider,
                                          ) !=
                                          dialogAccountUserId) {
                                        if (ctx.mounted &&
                                            ModalRoute.of(ctx)?.isCurrent ==
                                                true) {
                                          Navigator.of(ctx).pop();
                                        }
                                        return;
                                      }
                                      if (ctx.mounted) {
                                        setDialogState(() {
                                          joining = false;
                                          // Render the failure inside the
                                          // dialog: a page-level toast would
                                          // sit beneath the modal barrier
                                          // while the dialog stays open.
                                          joinError = _actionFailureMessage(e);
                                        });
                                      } else {
                                        neuToast(
                                          context,
                                          _actionFailureMessage(e),
                                        );
                                      }
                                    }
                                  },
                            child: joining
                                ? SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      color: ctx.neu.onAccent,
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Center(child: Text('加入')),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SpaceRoomTile extends StatelessWidget {
  final Space space;

  const _SpaceRoomTile({super.key, required this.space});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpacing.sm),
      child: NeuAction(
        radius: NeuRadius.content,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SpaceDetailPage(space: space)),
          );
        },
        child: NeuSurface(
          color: context.neu.card,
          radius: NeuRadius.content,
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              AppAvatar(
                fallback: space.name,
                size: 48,
                radius: NeuRadius.content,
                url: space.avatarUrl,
              ),
              const SizedBox(width: NeuSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      space.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '查看房间、成员和空间设置',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: context.neu.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: NeuSpacing.lg),
      child: NeuSurface(
        color: context.neu.surfaceStrong,
        radius: NeuRadius.surface,
        padding: const EdgeInsets.all(NeuSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: NeuSpacing.xs),
            Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _HintText extends StatelessWidget {
  final String text;

  const _HintText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: Theme.of(context).textTheme.bodyMedium);
  }
}
