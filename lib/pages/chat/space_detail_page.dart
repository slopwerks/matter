import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/push/push_runtime.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/hidden_rooms_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/material_root_header.dart';
import '../../widgets/material_header_transition.dart';
import '../../widgets/material_adaptive_shell.dart';
import '../../widgets/material_identity_id.dart';
import '../../widgets/material_press.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'action_failure_message.dart';
import 'chat_detail_page.dart';
import 'material_room_member_rows.dart';
import 'room_directory_page.dart';
import 'room_sticker_packs_page.dart';

part 'material_space_detail.dart';
part 'material_space_info.dart';
part 'material_space_editor.dart';

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
  int _materialSpaceTab = 0;
  bool _headerCollapsed = false;

  void _syncHeader(ScrollMetrics metrics, double extent) {
    final next = MaterialHeaderTransition.shouldCollapse(
      metrics,
      _headerCollapsed,
      extent,
    );
    if (next != _headerCollapsed) setState(() => _headerCollapsed = next);
  }

  bool _markingSpaceRead = false;
  bool _creatingRoom = false;
  bool _inviting = false;

  void _selectMaterialSpaceTab(int tab) =>
      setState(() => _materialSpaceTab = tab);

  Future<void> _copySpaceLink() async {
    final account = _openedUserId;
    if (account == null || !_accountActive()) return;
    try {
      final link = await spaceShareLink(
        accountUserId: account,
        spaceId: widget.space.id,
      );
      if (!_accountActive()) return;
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted && _accountActive()) neuToast(context, '已复制空间链接');
    } catch (error) {
      if (mounted && _accountActive()) {
        neuToast(context, _actionFailureMessage(error));
      }
    }
  }

  Future<void> _inviteSpaceMember() async {
    final account = _openedUserId;
    if (account == null || !_accountActive() || _inviting) return;
    setState(() => _inviting = true);
    try {
      var draft = '';
      final user = await showDialog<String>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, update) => AlertDialog(
            title: const Text('邀请成员'),
            content: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Matrix 用户 ID',
                hintText: '@用户:服务器',
              ),
              onChanged: (value) => update(() => draft = value.trim()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: draft.isEmpty
                    ? null
                    : () => Navigator.pop(dialog, draft),
                child: const Text('发送邀请'),
              ),
            ],
          ),
        ),
      );
      if (user == null || !_accountActive()) return;
      await inviteUserToRoom(
        accountUserId: account,
        roomId: widget.space.id,
        userId: user,
      );
      if (mounted && _accountActive()) neuToast(context, '邀请已发送');
    } catch (error) {
      if (mounted && _accountActive()) {
        neuToast(context, _actionFailureMessage(error));
      }
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _createSpaceRoom() async {
    final account = _openedUserId;
    if (_creatingRoom || account == null || !_accountActive()) return;
    var draft = '';
    final name = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, update) => AlertDialog(
          title: const Text('新建房间'),
          content: TextField(
            autofocus: true,
            decoration: const InputDecoration(labelText: '房间名称'),
            onChanged: (v) => update(() => draft = v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: draft.isEmpty
                  ? null
                  : () => Navigator.pop(dialog, draft),
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (name == null || !_accountActive() || _creatingRoom) return;
    final spaceId = widget.space.id;
    setState(() => _creatingRoom = true);
    String? roomId;
    try {
      roomId = await createGroupRoom(accountUserId: account, name: name);
      await addRoomToSpace(
        accountUserId: account,
        spaceId: spaceId,
        roomId: roomId,
      );
      if (mounted && _accountActive()) neuToast(context, '房间已创建并加入空间');
    } catch (error) {
      if (mounted && _accountActive()) {
        neuToast(
          context,
          '${roomId == null ? '' : '房间已创建。'}${_actionFailureMessage(error)}',
        );
      }
    } finally {
      if (_accountActive()) {
        ref.invalidate(allChatRoomsProvider);
        ref.invalidate(allSpaceChildrenProvider(spaceId));
        ref.invalidate(allUngroupedRoomsProvider);
      }
      if (mounted) setState(() => _creatingRoom = false);
    }
  }

  Future<void> _markSpaceRead(List<ChatRoom> rooms) async {
    final account = _openedUserId;
    if (account == null || _markingSpaceRead || !_accountActive()) return;
    setState(() => _markingSpaceRead = true);
    try {
      for (final room in rooms) {
        if (!_accountActive()) return;
        final cleared = await markRoomAsReadWithPushCleanup(
          accountUserId: account,
          roomId: room.id,
          explicit: true,
        );
        if (!_accountActive()) return;
        if (!cleared) throw StateError('未能清除「${room.name}」的未读标记');
        setRoomAutoReadSuppressed(ref, room.id, suppressed: false);
        setRoomUnreadOverride(ref, room, unread: false);
      }
    } catch (error) {
      if (mounted && _accountActive()) {
        neuToast(context, _actionFailureMessage(error));
      }
    } finally {
      if (_accountActive()) {
        ref.invalidate(allSpaceChildrenProvider);
        ref.invalidate(allChatRoomsProvider);
        ref.invalidate(allUngroupedRoomsProvider);
      }
      if (mounted) setState(() => _markingSpaceRead = false);
    }
  }

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
        extendBodyBehindAppBar: true,
        appBar: buildFloatingAppBar(
          leading: IconButton(
            icon: Icon(Icons.arrow_back_rounded, color: context.neu.text),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text('空间', style: Theme.of(context).textTheme.headlineSmall),
        ),
        body: Center(
          child: Text('账号已切换', style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
    }
    final detailsAsync = ref.watch(spaceDetailsProvider(space.id));
    final membersAsync = ref.watch(roomMembersProvider(space.id));
    final childrenAsync = ref.watch(spaceChildrenProvider(space.id));
    final allChildrenAsync = ref.watch(allSpaceChildrenProvider(space.id));
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

    if (context.isMaterial) {
      return _buildMaterialSpaceDetail(
        context,
        details,
        detailsAsync.hasValue,
        childrenAsync,
        allChildrenAsync,
        membersAsync,
      );
    }

    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(
              title: const Text('空间'),
              actions: [
                IconButton(
                  icon: const Icon(Icons.playlist_add),
                  tooltip: '添加房间',
                  onPressed: () => _showAddRoomDialog(context, ref),
                ),
                IconButton(
                  icon: const Icon(Icons.more_horiz_rounded),
                  tooltip: '更多',
                  onPressed: () => _showSpaceMenu(
                    context,
                    ref,
                    details,
                    detailsAsync.hasValue,
                    allChildrenAsync.asData?.value,
                  ),
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: MaxContentWidth(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  NeuSpacing.lg,
                  viewPaddingTop + kToolbarHeight + NeuSpacing.sm,
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
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    details.id,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
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
                                    : () => _confirmRemoveRoom(
                                        context,
                                        ref,
                                        room,
                                      ),
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
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge,
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
                          icon: Icons.collections_outlined,
                          label: '贴纸包',
                          value: '预览与收藏',
                          onTap: () => openRoomStickerPacks(context, details.id),
                        ),
                        const SizedBox(height: 10),
                        _ActionSettingRow(
                          icon: Icons.edit_rounded,
                          label: '编辑空间',
                          value: '修改名称与说明',
                          onTap: () =>
                              _showEditSpaceDialog(context, ref, details),
                        ),
                        const SizedBox(height: 10),
                        _ActionSettingRow(
                          icon: Icons.exit_to_app_rounded,
                          label: '退出空间',
                          value: '离开当前空间',
                          danger: true,
                          onTap: () =>
                              _confirmLeaveSpace(context, ref, details),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: viewPaddingTop + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
          // 标题栏移到上方浮层,滚动内容从它下方穿过。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: NeuSpacing.sm,
                      right: NeuSpacing.md,
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
                        Expanded(
                          child: Text(
                            '空间',
                            style: Theme.of(context).textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        NeuIconButton(
                          icon: Icons.playlist_add_rounded,
                          size: 40,
                          tooltip: '添加房间',
                          onPressed: () => _showAddRoomDialog(context, ref),
                        ),
                        const SizedBox(width: NeuSpacing.xs),
                        NeuIconButton(
                          icon: Icons.more_horiz_rounded,
                          size: 40,
                          tooltip: '更多',
                          onPressed: () => _showSpaceMenu(
                            context,
                            ref,
                            details,
                            detailsAsync.hasValue,
                            allChildrenAsync.asData?.value,
                          ),
                        ),
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

  /// 空间操作菜单:编辑需要已加载的详情——用 fallback(加载中/失败)会
  /// 预填空说明,保存时会静默清掉服务端说明,所以未加载时不提供编辑。
  void _showSpaceMenu(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
    bool detailsLoaded,
    List<ChatRoom>? allChildren,
  ) {
    showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (context.isMaterial)
              NeuSheetItem(
                icon: Icons.playlist_add,
                label: '添加已有房间',
                onTap: () {
                  Navigator.pop(sheetContext);
                  _showAddRoomDialog(context, ref);
                },
              ),
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
              icon: Icons.visibility_off_outlined,
              label: '隐藏此空间的所有房间',
              onTap: () {
                if (allChildren == null) return;
                Navigator.of(sheetContext).pop();
                final roomIds = allChildren
                    .where((room) => room.roomType != 'space')
                    .map((room) => room.id);
                unawaited(
                  ref
                      .read(hiddenRoomsProvider.notifier)
                      .hideRooms(roomIds)
                      .then((_) {
                        if (context.mounted) {
                          neuToast(context, '已隐藏此空间的所有房间');
                        }
                      }),
                );
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
    SpaceDetails details, {
    _SpaceField field = _SpaceField.name,
  }) {
    if (context.isMaterial) {
      showDialog<void>(
        context: context,
        useSafeArea: false,
        builder: (_) => _SpaceFieldEditor(
          field: field,
          initialValue: field == _SpaceField.name
              ? details.name
              : details.topic ?? '',
          save: (value) async {
            if (!_accountActive()) throw '账号已切换';
            if (_spaceActionInProgress) throw _spaceBusyTip;
            _spaceActionInProgress = true;
            try {
              await updateSpaceDetails(
                accountUserId: _openedUserId ?? '',
                spaceId: details.id,
                name: field == _SpaceField.name ? value : null,
                topic: field == _SpaceField.topic ? value : null,
              );
              if (_accountActive()) {
                ref.invalidate(spaceDetailsProvider(details.id));
                ref.invalidate(spacesProvider);
                ref.invalidate(allChatRoomsProvider);
                if (context.mounted) neuToast(context, '${field.label}已更新');
              }
            } catch (error) {
              throw _actionFailureMessage(error);
            } finally {
              _spaceActionInProgress = false;
            }
          },
        ),
      );
      return;
    }
    final nameController = TextEditingController(text: details.name);
    final topicController = TextEditingController(text: details.topic ?? '');
    String? editError;
    var saving = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AppDialogSurface(
          title: '编辑空间',
          children: [
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
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
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
                          topic: topic,
                        );
                        // The account may have switched while the request was in
                        // flight: the page shows the switched placeholder — skip
                        // the local bookkeeping (same discipline as the other
                        // pages).
                        if (!_accountActive()) {
                          // Close the dialog: it would otherwise hover over the
                          // switched placeholder (same as the catch branch).
                          if (dialogContext.mounted &&
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                          return;
                        }
                        ref.invalidate(spaceDetailsProvider(details.id));
                        ref.invalidate(spacesProvider);
                        ref.invalidate(allChatRoomsProvider);
                        if (!context.mounted) return;
                        // `isCurrent` guard: the dialog may have been dismissed
                        // during its exit animation — popping then would pop the
                        // PAGE below it.
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
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
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                          return;
                        }
                        // The name write may have succeeded before a later topic
                        // write failed. Refresh the affected views even on errors
                        // so the UI reflects the server's partial result.
                        ref.invalidate(spaceDetailsProvider(details.id));
                        ref.invalidate(spacesProvider);
                        ref.invalidate(allChatRoomsProvider);
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
                    onPressed: () => ref.invalidate(allUngroupedRoomsProvider),
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
                                allSpaceChildrenProvider(widget.space.id),
                              );
                              container.invalidate(allUngroupedRoomsProvider);
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
        builder: (dialogContext, setDialogState) => AppDialogSurface(
          title: '移出空间',
          message: '要把“${room.name}”从这个空间移除吗？',
          children: [
            if (removeError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  removeError!,
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
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
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                          return;
                        }
                        // `context.mounted` first: `ref.invalidate` throws once
                        // the page is unmounted (the dialog may have been closed
                        // and the page popped while the write was in flight).
                        if (!context.mounted) return;
                        ref.invalidate(
                          allSpaceChildrenProvider(widget.space.id),
                        );
                        ref.invalidate(allUngroupedRoomsProvider);
                        // `isCurrent` guard: the dialog may have been dismissed
                        // during its exit animation — popping then would pop the
                        // PAGE below it.
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
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
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
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
        builder: (dialogContext, setDialogState) => AppDialogSurface(
          title: '退出空间',
          message: '确认退出“${details.name}”吗？',
          children: [
            if (leaveSpaceError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  leaveSpaceError!,
                  style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
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
                        setDialogState(() => leaveSpaceError = _spaceBusyTip);
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
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                          return;
                        }
                        // `context.mounted` first: `ref.invalidate` throws once
                        // the page is unmounted (the dialog may have been closed
                        // and the page popped while the write was in flight).
                        if (!context.mounted) return;
                        ref.invalidate(spacesProvider);
                        ref.invalidate(allChatRoomsProvider);
                        ref.invalidate(allUngroupedRoomsProvider);
                        // `isCurrent` guard: the dialog may have been dismissed
                        // during its exit animation — popping then would pop the
                        // PAGE below it.
                        if (dialogContext.mounted &&
                            ModalRoute.of(dialogContext)?.isCurrent == true) {
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
                              ModalRoute.of(dialogContext)?.isCurrent == true) {
                            Navigator.of(dialogContext).pop();
                          }
                          return;
                        }
                        if (dialogContext.mounted) {
                          // Render the failure inside the dialog: a page-level
                          // toast would sit beneath the modal barrier and stay
                          // invisible while the dialog stays open for retry.
                          setDialogState(
                            () => leaveSpaceError = _actionFailureMessage(e),
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
    final material = context.isMaterial;
    // Reuse a known member list without fetching every room's full roster.
    final members = roomMembersProvider(room.id);
    final knownCount = material && ref.watch(members.exists)
        ? ref.watch(members.select((value) => value.value?.length))
        : null;
    final preview = room.lastMessage.isEmpty ? room.id : room.lastMessage;
    final content = Row(
      children: [
        if (material && room.avatarUrl == null)
          Container(
            width: materialDenseListAvatarSize,
            height: materialDenseListAvatarSize,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(NeuRadius.button),
            ),
            child: Icon(
              room.roomType == 'space'
                  ? Icons.workspaces_outline
                  : Icons.chat_bubble_outline,
              size: 22,
              color: Theme.of(context).colorScheme.onPrimaryContainer,
            ),
          )
        else
          AppAvatar(
            fallback: room.name,
            size: material ? materialListAvatarSize : 42,
            radius: NeuRadius.content,
            materialRadius: NeuRadius.button,
            url: room.avatarUrl,
          ),
        SizedBox(width: material ? materialListContentGap : NeuSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                room.name,
                style: material
                    ? materialListTitleStyle(
                        Theme.of(context),
                        unread: hasUnread,
                      )
                    : Theme.of(context).textTheme.titleSmall,
                maxLines: material ? 2 : 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                knownCount != null && knownCount > 0
                    ? '$knownCount 位成员'
                    : preview,
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
        if (onRemove != null && material)
          PopupMenuButton<String>(
            tooltip: '房间操作',
            icon: const Icon(Icons.more_horiz),
            onSelected: (_) => onRemove!(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'remove', child: Text('从空间移除')),
            ],
          )
        else if (onRemove != null)
          IconButton(
            onPressed: onRemove,
            icon: Icon(
              Icons.remove_circle_outline_rounded,
              color: context.neu.error,
            ),
            tooltip: '从空间移除',
          )
        else
          Icon(Icons.chevron_right_rounded, color: context.neu.textTertiary),
      ],
    );

    if (material) {
      return MaterialPress(
        builder: (states) => Card(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: InkWell(
            statesController: states,
            onTap: () => _openSpaceChild(context, room, hasUnread),
            child: Container(
              alignment: AlignmentDirectional.centerStart,
              constraints: const BoxConstraints(minHeight: 96),
              padding: const EdgeInsets.all(NeuSpacing.lg),
              child: content,
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpacing.sm),
      child: NeuAction(
        radius: NeuRadius.content,
        onTap: () => _openSpaceChild(context, room, hasUnread),
        child: NeuSurface(
          color: context.neu.card,
          radius: NeuRadius.content,
          padding: const EdgeInsets.all(NeuSpacing.md),
          child: content,
        ),
      ),
    );
  }
}

void _openSpaceChild(BuildContext context, ChatRoom room, bool hasUnread) {
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
    if (context.isMaterial) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(
          label,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: color),
        ),
        subtitle: Text(value),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      );
    }
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
                style: Theme.of(context).textTheme.bodyLarge
                    ?.copyWith(color: color, fontWeight: FontWeight.w500),
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
