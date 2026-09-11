import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'action_failure_message.dart';
import 'chat_detail_page.dart';

/// Guard wording shown inside the space dialogs while a previous space
/// write is still in flight. Kept as a constant so the dialogs can render
/// it in a neutral color (it is a notice, not an error) and clear it once
/// the guard passes.
const _spaceBusyTip = '正在处理空间操作，请稍候';

class SpaceDetailPage extends ConsumerStatefulWidget {
  final Space space;

  const SpaceDetailPage({super.key, required this.space});

  @override
  ConsumerState<SpaceDetailPage> createState() => _SpaceDetailPageState();
}

class _SpaceDetailPageState extends ConsumerState<SpaceDetailPage> {
  /// The account this page was opened under. Switching away shows the
  /// neutral placeholder and drops the actions (same discipline as the
  /// room management and pinned pages): without it, the header (space
  /// details) would keep the old account's data while the child list
  /// refreshes under the new account, and actions would write to the new
  /// account.
  String? _openedUserId;
  bool _accountSwitched = false;

  /// Room currently being added to this space (double-tap guard: the sheet
  /// is a separate route, so its rows cannot be disabled by a page-level
  /// setState — the guard intercepts the second tap instead).
  String? _addingToSpaceRoomId;

  /// The add-room sheet's context while it is open (null once it closes):
  /// an account switch must dismiss the sheet through it, or the sheet
  /// would hover over the "account switched" placeholder and keep
  /// accepting taps for the previous account.
  BuildContext? _addRoomSheetContext;

  /// A space-level write (edit/remove/leave confirmations) is in flight:
  /// double-tap guard for the dialog confirm buttons (the dialogs are
  /// separate routes, so a page-level setState cannot disable their
  /// buttons — the guard intercepts the second tap instead).
  bool _spaceActionInProgress = false;

  bool _accountActive() =>
      mounted && ref.read(activeUserIdProvider) == _openedUserId;

  /// Map a failed write's error to the unified timeout/partial-success
  /// wording (same discipline as the room management page): a queue-wait
  /// timeout means the write may still be landing in its background tail,
  /// and a partially-succeeded outcome is not a plain failure.
  String _actionFailureMessage(Object error) => actionFailureMessage(error);

  @override
  void initState() {
    super.initState();
    _openedUserId = ref.read(activeUserIdProvider);
    ref.listenManual(activeUserIdProvider, (_, next) {
      if (!mounted) return;
      if (_openedUserId == null && next != null) {
        // Opened before login completed: adopt the first account instead
        // of showing the placeholder forever.
        _openedUserId = next;
        setState(() => _accountSwitched = false);
        return;
      }
      final switched = next != _openedUserId;
      if (switched) {
        // Dismiss an open add-room sheet: it must not hover over the
        // placeholder or accept writes for the previous account. `isCurrent`
        // guard: another modal may sit above the sheet — popping then would
        // dismiss that dialog instead.
        final sheetContext = _addRoomSheetContext;
        if (sheetContext != null &&
            sheetContext.mounted &&
            ModalRoute.of(sheetContext)?.isCurrent == true) {
          Navigator.of(sheetContext).pop();
        }
      }
      setState(() => _accountSwitched = switched);
    });
  }

  @override
  Widget build(BuildContext context) {
    final space = widget.space;
    if (_accountSwitched || !_accountActive()) {
      return Scaffold(
        backgroundColor: context.neu.base,
        appBar: AppBar(
          backgroundColor: context.neu.base,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: context.neu.text),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text('空间', style: Theme.of(context).textTheme.titleLarge),
        ),
        body: Center(
          child: Text('账号已切换', style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
    }
    final detailsAsync = ref.watch(spaceDetailsProvider(space.id));
    final membersAsync = ref.watch(roomMembersProvider(space.id));
    final childrenAsync = ref.watch(spaceChildrenProvider(space.id));
    final fallbackDetails = SpaceDetails(
      id: space.id,
      name: space.name,
      avatarUrl: space.avatarUrl,
      topic: null,
    );
    final details = detailsAsync.maybeWhen(
      data: (value) => value,
      orElse: () => fallbackDetails,
    );

    return Scaffold(
      backgroundColor: context.neu.base,
      appBar: AppBar(
        backgroundColor: context.neu.base,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.neu.text),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text('空间', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          NeuIconButton(
            icon: Icons.playlist_add_rounded,
            tooltip: '添加房间',
            onPressed: () => _showAddRoomDialog(context, ref),
          ),
          const SizedBox(width: NeuSpacing.xs),
          NeuIconButton(
            icon: Icons.more_horiz_rounded,
            tooltip: '更多',
            onPressed: () =>
                _showSpaceMenu(context, ref, details, detailsAsync.hasValue),
          ),
          const SizedBox(width: NeuSpacing.sm),
        ],
      ),
      body: MaxContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            NeuSpacing.lg,
            NeuSpacing.sm,
            NeuSpacing.lg,
            NeuSpacing.xl,
          ),
          children: [
            NeuSurface(
              color: context.neu.card,
              radius: NeuRadius.surface,
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppAvatar(
                        fallback: details.name,
                        size: 56,
                        radius: NeuRadius.content,
                        url: details.avatarUrl,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              details.name,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              details.id,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if ((details.topic ?? '').isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      details.topic!,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: NeuSpacing.md),
            _Section(
              title: '房间列表',
              child: childrenAsync.when(
                data: (rooms) {
                  if (rooms.isEmpty) {
                    return Text(
                      '这个空间下暂时没有可见房间',
                      style: Theme.of(context).textTheme.bodyMedium,
                    );
                  }
                  return Column(
                    children: [
                      for (final room in rooms)
                        _SpaceChildTile(
                          room: room,
                          onRemove: room.roomType == 'space'
                              ? null
                              : () => _confirmRemoveRoom(context, ref, room),
                        ),
                    ],
                  );
                },
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: context.neu.accent,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载房间失败: $err',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: NeuSpacing.md),
            _Section(
              title: '成员',
              child: membersAsync.when(
                data: (members) {
                  if (members.isEmpty) {
                    return Text(
                      '暂无成员信息',
                      style: Theme.of(context).textTheme.bodyMedium,
                    );
                  }
                  return Column(
                    children: [
                      for (final member in members.take(8))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              AppAvatar(
                                fallback: member.name,
                                size: 36,
                                radius: NeuRadius.content,
                                url: member.avatarUrl,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  member.name,
                                  style: Theme.of(context).textTheme.bodyLarge,
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (members.length > 8)
                        Text(
                          '还有 ${members.length - 8} 位成员',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  );
                },
                loading: () => Center(
                  child: CircularProgressIndicator(
                    color: context.neu.accent,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载成员失败: $err',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
            const SizedBox(height: NeuSpacing.md),
            _Section(
              title: '设置',
              child: Column(
                children: [
                  _ActionSettingRow(
                    icon: Icons.edit_rounded,
                    label: '编辑空间',
                    value: '修改名称与说明',
                    onTap: () => _showEditSpaceDialog(context, ref, details),
                  ),
                  const SizedBox(height: 10),
                  _ActionSettingRow(
                    icon: Icons.exit_to_app_rounded,
                    label: '退出空间',
                    value: '离开当前空间',
                    danger: true,
                    onTap: () => _confirmLeaveSpace(context, ref, details),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 空间操作菜单:编辑需要已加载的详情——用 fallback(加载中/失败)会
  /// 预填空说明,保存时会静默清掉服务端说明,所以未加载时不提供编辑。
  void _showSpaceMenu(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
    bool detailsLoaded,
  ) {
    showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (detailsLoaded)
              NeuSheetItem(
                icon: Icons.edit_outlined,
                label: '编辑空间',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showEditSpaceDialog(context, ref, details);
                },
              ),
            NeuSheetItem(
              icon: Icons.exit_to_app_rounded,
              label: '退出空间',
              color: sheetContext.neu.error,
              onTap: () {
                Navigator.of(sheetContext).pop();
                _confirmLeaveSpace(context, ref, details);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showEditSpaceDialog(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    final nameController = TextEditingController(text: details.name);
    final topicController = TextEditingController(text: details.topic ?? '');
    String? editError;
    var saving = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
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
                  Text(
                    '编辑空间',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  NeuTextField(controller: nameController, hint: '空间名称'),
                  const SizedBox(height: 12),
                  NeuTextField(
                    controller: topicController,
                    hint: '空间说明',
                    maxLines: 4,
                  ),
                  if (editError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        editError!,
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: editError == _spaceBusyTip
                                  ? dialogContext.neu.textSecondary
                                  : dialogContext.neu.error,
                            ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Center(child: Text('取消')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NeuButton(
                          accent: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () async {
                            // Entry guard: the dialog does not rebuild on a page-level
                            // setState, so a second tap would otherwise issue a duplicate
                            // write.
                            if (_spaceActionInProgress) {
                              // The previous request may still be in flight (its dialog
                              // was dismissed): say so instead of silently swallowing the
                              // tap (same discipline as the leave dialog). Render inside
                              // the dialog: a page snackbar would sit beneath the modal
                              // barrier and stay invisible.
                              setDialogState(() => editError = _spaceBusyTip);
                              return;
                            }
                            // The busy tip may linger from a previous dismissal: clear it
                            // once the guard passes.
                            if (editError == _spaceBusyTip) {
                              setDialogState(() => editError = null);
                            }
                            final name = nameController.text.trim();
                            final topic = topicController.text.trim();
                            // Validate BEFORE arming the guard: an early return here must
                            // not strand the flag (every later confirm would be blocked).
                            if (name.isEmpty) {
                              // Feedback instead of a silent no-op (same as the room
                              // management save path).
                              setDialogState(() => editError = '空间名称不能为空');
                              return;
                            }
                            _spaceActionInProgress = true;
                            if (dialogContext.mounted) {
                              setDialogState(() => saving = true);
                            }
                            try {
                              await updateSpaceDetails(
                                accountUserId: _openedUserId ?? '',
                                spaceId: details.id,
                                name: name,
                                topic: topic.isEmpty ? null : topic,
                              );
                              // The account may have switched while the request was in
                              // flight: the page shows the switched placeholder — skip
                              // the local bookkeeping (same discipline as the other
                              // pages).
                              if (!_accountActive()) {
                                // Close the dialog: it would otherwise hover over the
                                // switched placeholder (same as the catch branch).
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              ref.invalidate(spaceDetailsProvider(details.id));
                              ref.invalidate(spacesProvider);
                              ref.invalidate(chatRoomsProvider);
                              if (!context.mounted) return;
                              // `isCurrent` guard: the dialog may have been dismissed
                              // during its exit animation — popping then would pop the
                              // PAGE below it.
                              if (dialogContext.mounted &&
                                  ModalRoute.of(dialogContext)?.isCurrent ==
                                      true) {
                                Navigator.of(dialogContext).pop();
                              }
                              // The dialog may have been dismissed while the request was
                              // in flight: still report success.
                              neuToast(context, '空间已更新');
                            } catch (e) {
                              if (!context.mounted) return;
                              // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                              // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                              // Rust 账号守卫拒绝（无反馈）。
                              if (!_accountActive()) {
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              // The name write may have succeeded before a later topic
                              // write failed. Refresh the affected views even on errors
                              // so the UI reflects the server's partial result.
                              ref.invalidate(spaceDetailsProvider(details.id));
                              ref.invalidate(spacesProvider);
                              ref.invalidate(chatRoomsProvider);
                              if (dialogContext.mounted) {
                                // Render the failure inside the dialog: a page-level
                                // toast would sit beneath the modal barrier and stay
                                // invisible while the dialog stays open for retry.
                                setDialogState(
                                  () => editError = _actionFailureMessage(e),
                                );
                              } else {
                                neuToast(context, _actionFailureMessage(e));
                              }
                            } finally {
                              if (mounted) _spaceActionInProgress = false;
                              if (dialogContext.mounted) {
                                setDialogState(() => saving = false);
                              }
                            }
                          },
                          child: saving
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: dialogContext.neu.onAccent,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Center(child: Text('保存')),
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
    );
  }

  void _showAddRoomDialog(BuildContext context, WidgetRef ref) {
    // The Consumer below shadows [context] with the sheet's own context,
    // which is unmounted as soon as the sheet route is dismissed. Keep the
    // page context here: the write may outlive an early dismissal (barrier
    // tap / swipe while it is in flight), and its success/failure must
    // still be reported on the page.
    final pageContext = context;
    // Container-level invalidates: the sheet's own `ref` throws once the
    // sheet is dismissed (Riverpod asserts on disposed widgets), and the
    // write can outlive an early dismissal.
    final container = ProviderScope.containerOf(pageContext, listen: false);
    showNeuSheet<void>(
      context: context,
      // Watch the ungrouped list inside the sheet: a loading or error
      // state must not masquerade as "no rooms" (the previous read-once
      // snapshot did).
      child: Consumer(
        builder: (sheetContext, ref, _) {
          // Track the sheet's context (the Consumer's own): an account
          // switch dismisses the sheet through it (see the
          // activeUserIdProvider listener).
          _addRoomSheetContext = sheetContext;
          final ungroupedAsync = ref.watch(ungroupedRoomsProvider);
          return ungroupedAsync.when(
            loading: () => Padding(
              padding: const EdgeInsets.all(NeuSpacing.xl),
              child: Center(
                child: CircularProgressIndicator(
                  color: sheetContext.neu.accent,
                  strokeWidth: 2,
                ),
              ),
            ),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(NeuSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '加载可加入的房间失败',
                    style: Theme.of(sheetContext).textTheme.bodyMedium
                        ?.copyWith(color: sheetContext.neu.error),
                  ),
                  const SizedBox(height: NeuSpacing.md),
                  NeuButton(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    onPressed: () => ref.invalidate(ungroupedRoomsProvider),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
            data: (rooms) => rooms.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(NeuSpacing.xl),
                    child: Text(
                      '当前没有可加入这个空间的未归属群组。',
                      style: Theme.of(sheetContext).textTheme.bodyMedium,
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final room in rooms)
                        NeuSheetItem(
                          icon: Icons.forum_outlined,
                          label: room.name,
                          trailing: _addingToSpaceRoomId == room.id
                              ? SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    color: sheetContext.neu.accent,
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.add_link_rounded,
                                  size: 18,
                                  color: sheetContext.neu.accent,
                                ),
                          onTap: () async {
                            // Entry guard (not only the disabled row): the
                            // sheet does not rebuild on a page-level
                            // setState, so a second tap on the old row
                            // would otherwise issue a duplicate add.
                            if (!_accountActive()) return;
                            if (_addingToSpaceRoomId != null) {
                              // Say so instead of silently swallowing the
                              // tap (same discipline as the other guards).
                              // A toast on the sheet context would render
                              // beneath the sheet barrier, so close the
                              // sheet first and report on the page (same as
                              // the failure path). `isCurrent` guard: the
                              // account-switch listener may already be
                              // popping the sheet.
                              if (sheetContext.mounted &&
                                  ModalRoute.of(sheetContext)?.isCurrent ==
                                      true) {
                                Navigator.of(sheetContext).pop();
                              }
                              neuToast(pageContext, '正在添加房间，请稍候');
                              return;
                            }
                            _addingToSpaceRoomId = room.id;
                            try {
                              await addRoomToSpace(
                                accountUserId: _openedUserId ?? '',
                                spaceId: widget.space.id,
                                roomId: room.id,
                              );
                              // The account may have switched while the
                              // request was in flight: the page shows the
                              // switched placeholder — skip the local
                              // bookkeeping.
                              if (!_accountActive()) return;
                              // Container-level invalidates: the sheet's
                              // own `ref` would throw if the sheet was
                              // dismissed while the write was in flight.
                              container.invalidate(
                                spaceChildrenProvider(widget.space.id),
                              );
                              container.invalidate(ungroupedRoomsProvider);
                              if (!pageContext.mounted) return;
                              if (sheetContext.mounted &&
                                  ModalRoute.of(sheetContext)?.isCurrent ==
                                      true) {
                                Navigator.of(sheetContext).pop();
                              }
                              // The sheet may have been dismissed while
                              // the request was in flight: still report
                              // success on the page.
                              neuToast(pageContext, '已加入空间');
                            } catch (e) {
                              if (!pageContext.mounted) return;
                              // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
                              if (!_accountActive()) return;
                              if (sheetContext.mounted &&
                                  ModalRoute.of(sheetContext)?.isCurrent ==
                                      true) {
                                // Close the sheet first, then report: a
                                // page toast while the sheet is up would
                                // sit hidden behind its barrier.
                                Navigator.of(sheetContext).pop();
                              }
                              neuToast(pageContext, _actionFailureMessage(e));
                            } finally {
                              if (mounted) {
                                _addingToSpaceRoomId = null;
                              }
                            }
                          },
                        ),
                    ],
                  ),
          );
        },
      ),
    ).whenComplete(() {
      _addRoomSheetContext = null;
    });
  }

  void _confirmRemoveRoom(BuildContext context, WidgetRef ref, ChatRoom room) {
    String? removeError;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
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
                  Text(
                    '移出空间',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '要把“${room.name}”从这个空间移除吗？',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                  if (removeError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        removeError!,
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: removeError == _spaceBusyTip
                                  ? dialogContext.neu.textSecondary
                                  : dialogContext.neu.error,
                            ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Center(child: Text('取消')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () async {
                            // Entry guard: the dialog does not rebuild on a page-level
                            // setState, so a second tap would otherwise issue a duplicate
                            // removal.
                            if (_spaceActionInProgress) {
                              // The previous request may still be in flight (its dialog
                              // was dismissed): say so instead of silently swallowing the
                              // tap (same discipline as the leave dialog). Render inside
                              // the dialog: a page snackbar would sit beneath the modal
                              // barrier and stay invisible.
                              setDialogState(() => removeError = _spaceBusyTip);
                              return;
                            }
                            // The busy tip may linger from a previous dismissal: clear it
                            // once the guard passes.
                            if (removeError == _spaceBusyTip) {
                              setDialogState(() => removeError = null);
                            }
                            _spaceActionInProgress = true;
                            try {
                              await removeRoomFromSpace(
                                accountUserId: _openedUserId ?? '',
                                spaceId: widget.space.id,
                                roomId: room.id,
                              );
                              // The account may have switched while the request was in
                              // flight: the page shows the switched placeholder — skip
                              // the local bookkeeping and close the dialog (same as the
                              // catch branch).
                              if (!_accountActive()) {
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              // `context.mounted` first: `ref.invalidate` throws once
                              // the page is unmounted (the dialog may have been closed
                              // and the page popped while the write was in flight).
                              if (!context.mounted) return;
                              ref.invalidate(
                                spaceChildrenProvider(widget.space.id),
                              );
                              ref.invalidate(ungroupedRoomsProvider);
                              // `isCurrent` guard: the dialog may have been dismissed
                              // during its exit animation — popping then would pop the
                              // PAGE below it.
                              if (dialogContext.mounted &&
                                  ModalRoute.of(dialogContext)?.isCurrent ==
                                      true) {
                                Navigator.of(dialogContext).pop();
                              }
                              // The dialog may have been dismissed while the request was
                              // in flight: still report success.
                              neuToast(context, '已从空间移除');
                            } catch (e) {
                              if (!context.mounted) return;
                              // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                              // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                              // Rust 账号守卫拒绝（无反馈）。
                              if (!_accountActive()) {
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              if (dialogContext.mounted) {
                                // Render the failure inside the dialog: a page-level
                                // snackbar would sit beneath the modal barrier and stay
                                // invisible while the dialog stays open for retry.
                                setDialogState(
                                  () => removeError = _actionFailureMessage(e),
                                );
                              } else {
                                neuToast(context, _actionFailureMessage(e));
                              }
                            } finally {
                              if (mounted) _spaceActionInProgress = false;
                            }
                          },
                          child: Center(
                            child: Text(
                              '移除',
                              style: TextStyle(color: dialogContext.neu.error),
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
      ),
    );
  }

  void _confirmLeaveSpace(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    String? leaveSpaceError;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => Dialog(
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
                  Text(
                    '退出空间',
                    style: Theme.of(dialogContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '确认退出“${details.name}”吗？',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                  if (leaveSpaceError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        leaveSpaceError!,
                        style: Theme.of(dialogContext).textTheme.bodySmall
                            ?.copyWith(
                              color: leaveSpaceError == _spaceBusyTip
                                  ? dialogContext.neu.textSecondary
                                  : dialogContext.neu.error,
                            ),
                      ),
                    ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () => Navigator.of(dialogContext).pop(),
                          child: const Center(child: Text('取消')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: NeuButton(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          onPressed: () async {
                            // Entry guard: the dialog does not rebuild on a page-level
                            // setState, so a second tap would otherwise issue a duplicate
                            // leave.
                            if (_spaceActionInProgress) {
                              // The previous request may still be in flight (its dialog
                              // was dismissed): say so instead of silently swallowing the
                              // tap (same discipline as the leave dialog). Render inside
                              // the dialog: a page snackbar would sit beneath the modal
                              // barrier and stay invisible.
                              setDialogState(
                                () => leaveSpaceError = _spaceBusyTip,
                              );
                              return;
                            }
                            // The busy tip may linger from a previous dismissal: clear it
                            // once the guard passes.
                            if (leaveSpaceError == _spaceBusyTip) {
                              setDialogState(() => leaveSpaceError = null);
                            }
                            _spaceActionInProgress = true;
                            try {
                              await leaveSpace(
                                accountUserId: _openedUserId ?? '',
                                spaceId: details.id,
                              );
                              // The account may have switched while the request was in
                              // flight: the page shows the switched placeholder — skip
                              // the local bookkeeping and close the dialog (same as the
                              // catch branch).
                              if (!_accountActive()) {
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              // `context.mounted` first: `ref.invalidate` throws once
                              // the page is unmounted (the dialog may have been closed
                              // and the page popped while the write was in flight).
                              if (!context.mounted) return;
                              ref.invalidate(spacesProvider);
                              ref.invalidate(chatRoomsProvider);
                              ref.invalidate(ungroupedRoomsProvider);
                              // `isCurrent` guard: the dialog may have been dismissed
                              // during its exit animation — popping then would pop the
                              // PAGE below it.
                              if (dialogContext.mounted &&
                                  ModalRoute.of(dialogContext)?.isCurrent ==
                                      true) {
                                Navigator.of(dialogContext).pop();
                              }
                              // The dialog may have been dismissed while the request was
                              // in flight: still close the page and report success.
                              neuToast(context, '已退出空间');
                              if (mounted &&
                                  ModalRoute.of(context)?.isCurrent == true) {
                                Navigator.of(context).pop();
                              }
                            } catch (e) {
                              if (!context.mounted) return;
                              // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致），并
                              // 关闭对话框——它停留的旧账号内容已无意义，且重试只会再次被
                              // Rust 账号守卫拒绝（无反馈）。
                              if (!_accountActive()) {
                                if (dialogContext.mounted &&
                                    ModalRoute.of(dialogContext)?.isCurrent ==
                                        true) {
                                  Navigator.of(dialogContext).pop();
                                }
                                return;
                              }
                              if (dialogContext.mounted) {
                                // Render the failure inside the dialog: a page-level
                                // toast would sit beneath the modal barrier and stay
                                // invisible while the dialog stays open for retry.
                                setDialogState(
                                  () => leaveSpaceError = _actionFailureMessage(
                                    e,
                                  ),
                                );
                              } else {
                                neuToast(context, _actionFailureMessage(e));
                              }
                            } finally {
                              if (mounted) _spaceActionInProgress = false;
                            }
                          },
                          child: Center(
                            child: Text(
                              '退出',
                              style: TextStyle(color: dialogContext.neu.error),
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
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return NeuSurface(
      color: context.neu.surfaceStrong,
      radius: NeuRadius.surface,
      padding: const EdgeInsets.all(NeuSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: NeuSpacing.md),
          child,
        ],
      ),
    );
  }
}

class _SpaceChildTile extends ConsumerWidget {
  final ChatRoom room;
  final VoidCallback? onRemove;

  const _SpaceChildTile({required this.room, this.onRemove});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Match the main room list's unread display (override-aware), so a
    // marked-unread room never reads as "在线" inside a space, and pending
    // mark-read/unread writes show consistently during the echo window.
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(room.id));
    final syncedHasUnread = room.unreadCount > 0 || room.isMarkedUnread;
    final overrideApplies = unreadOverride?.appliesTo(room) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : syncedHasUnread;
    final unreadAccent = room.isMuted
        ? context.neu.textTertiary
        : context.neu.accent;
    // Same stale-override cleanup as the main room list: a room managed only
    // from the space view must not keep a dead override in memory. Only a
    // no-longer-applicable override is dropped.
    if (unreadOverride != null && !overrideApplies) {
      clearStaleRoomUnreadOverride(ref, context, room.id, unreadOverride);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpacing.sm),
      child: NeuAction(
        radius: NeuRadius.content,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => room.roomType == 'space'
                  ? SpaceDetailPage(
                      space: Space(
                        id: room.id,
                        name: room.name,
                        avatarUrl: room.avatarUrl,
                      ),
                    )
                  : ChatDetailPage(
                      roomId: room.id,
                      roomName: room.name,
                      avatarUrl: room.avatarUrl,
                      nameEventId: room.nameEventId,
                      avatarEventId: room.avatarEventId,
                      isDm: room.roomType == 'dm',
                      subtitle: hasUnread
                          ? (room.unreadCount > 0
                                ? '${room.unreadCount} 条未读消息'
                                : '已标记未读')
                          : '在线',
                    ),
            ),
          );
        },
        child: NeuSurface(
          color: context.neu.card,
          radius: NeuRadius.content,
          padding: const EdgeInsets.all(NeuSpacing.md),
          child: Row(
            children: [
              AppAvatar(
                fallback: room.name,
                size: 42,
                radius: NeuRadius.content,
                url: room.avatarUrl,
              ),
              const SizedBox(width: NeuSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      style: Theme.of(context).textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      room.lastMessage.isEmpty ? room.id : room.lastMessage,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (hasUnread) ...[
                const SizedBox(width: NeuSpacing.sm),
                if (room.unreadCount > 0)
                  NeuBadge(
                    key: ValueKey('space-child-unread-badge:${room.id}'),
                    count: room.unreadCount,
                    muted: room.isMuted,
                  )
                else
                  Container(
                    key: ValueKey('space-child-unread-dot:${room.id}'),
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: unreadAccent,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  icon: Icon(
                    Icons.remove_circle_outline_rounded,
                    color: context.neu.error,
                  ),
                  tooltip: '从空间移除',
                )
              else
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

class _ActionSettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool danger;
  final VoidCallback onTap;

  const _ActionSettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? context.neu.error : context.neu.text;
    return InkWell(
      borderRadius: BorderRadius.circular(NeuRadius.content),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              icon,
              color: danger ? context.neu.error : context.neu.textSecondary,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(value, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 6),
            Icon(
              Icons.chevron_right_rounded,
              color: context.neu.textTertiary,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
