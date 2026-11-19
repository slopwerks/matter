import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/chat_visual_settings_provider.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import '../chat/action_failure_message.dart';
import '../chat/chat_detail_page.dart';
import '../chat/chat_list_item.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _searchCollapse = ValueNotifier(0.0);
  bool _headerSearchVisible = false;
  String _searchQuery = '';

  static const _searchBarExtent = 56.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncSearchCollapse);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchCollapse.dispose();
    super.dispose();
  }

  void _syncSearchCollapse() {
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    _searchCollapse.value = (offset / _searchBarExtent).clamp(0.0, 1.0);
    final show = _headerSearchVisible
        ? offset >= _searchBarExtent - 16
        : offset >= _searchBarExtent;
    if (show != _headerSearchVisible) {
      setState(() => _headerSearchVisible = show);
    }
  }

  Future<void> _revealSearch() async {
    if (_scrollController.hasClients) {
      await _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    }
    if (mounted) _searchFocusNode.requestFocus();
  }

  Widget _buildHeaderSearchEntry() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _headerSearchVisible
            ? NeuIconButton(
                key: const ValueKey('contacts-header-search-entry'),
                icon: Icons.search_rounded,
                tooltip: '搜索联系人',
                onPressed: _revealSearch,
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(
              title: const Text('通讯录'),
              actions: [_buildHeaderSearchEntry()],
            )
          : null,
      body: Stack(
        children: [
          NotificationListener<ScrollMetricsNotification>(
            onNotification: (notification) {
              if (notification.depth == 0) _syncSearchCollapse();
              return false;
            },
            child: CustomScrollView(
              controller: _scrollController,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                // 标题栏移到上方浮层,这里只预留其高度。
                SliverToBoxAdapter(
                  child: SizedBox(
                    height:
                        MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
                  ),
                ),
                SliverToBoxAdapter(
                  child: ValueListenableBuilder<double>(
                    valueListenable: _searchCollapse,
                    builder: (context, collapse, child) => Opacity(
                      opacity: 1 - collapse,
                      child: IgnorePointer(
                        ignoring: collapse == 1,
                        child: ExcludeFocus(
                          excluding: collapse == 1,
                          child: child!,
                        ),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        NeuSpacing.lg,
                        NeuSpacing.xs,
                        NeuSpacing.lg,
                        NeuSpacing.sm,
                      ),
                      child: AppSearchField(
                        key: const ValueKey('contacts-search-entry'),
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        hint: '搜索联系人',
                        onChanged: (value) {
                          setState(() => _searchQuery = value.toLowerCase());
                        },
                      ),
                    ),
                  ),
                ),
                contactsAsync.when(
                  data: (contacts) {
                    final filtered = _searchQuery.isEmpty
                        ? contacts
                        : contacts
                              .where(
                                (c) =>
                                    c.name.toLowerCase().contains(
                                      _searchQuery,
                                    ) ||
                                    c.status.toLowerCase().contains(
                                      _searchQuery,
                                    ),
                              )
                              .toList();

                    if (filtered.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(NeuSpacing.xl),
                          child: _EmptyView(),
                        ),
                      );
                    }

                    return SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NeuSpacing.lg,
                      ),
                      sliver: SliverList.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) => ChatListDivider(
                          indent: context.isMaterial
                              ? 12 +
                                    materialListAvatarSize +
                                    materialListContentGap
                              : 8 + 48 + 14,
                        ),
                        itemBuilder: (context, index) {
                          final contact = filtered[index];
                          return _ContactTile(
                            key: ValueKey(contact.id),
                            contact: contact,
                          );
                        },
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
                      padding: const EdgeInsets.all(NeuSpacing.xl),
                      child: Center(
                        child: SelectableText(
                          '加载失败: $err',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ),
                ),
                SliverPadding(
                  padding: EdgeInsets.only(
                    bottom: context.isMaterial
                        ? NeuSpacing.xl + MediaQuery.paddingOf(context).bottom
                        : NeuSpacing.navClearance,
                  ),
                ),
              ],
            ),
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '通讯录',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        _buildHeaderSearchEntry(),
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
}

/// 无联系人 / 搜索无结果的占位。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const NeuIconButton(icon: Icons.contacts_rounded, size: 72),
        const SizedBox(height: NeuSpacing.md),
        Text('暂无联系人', style: Theme.of(context).textTheme.bodyLarge),
        const SizedBox(height: NeuSpacing.xs),
        Text('加入房间后，成员会显示在这里', style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

class _ContactTile extends ConsumerStatefulWidget {
  final Contact contact;

  const _ContactTile({super.key, required this.contact});

  @override
  ConsumerState<_ContactTile> createState() => _ContactTileState();
}

class _ContactTileState extends ConsumerState<_ContactTile> {
  String? _resolvedAvatarUrl;
  bool _creatingDm = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _resolveAvatar();
  }

  Future<void> _resolveAvatar() async {
    if (widget.contact.avatarUrl != null &&
        widget.contact.avatarUrl!.startsWith('mxc://')) {
      final url = await resolveMxcUrlAvatar(ref, widget.contact.avatarUrl);
      if (mounted && url != null) {
        setState(() => _resolvedAvatarUrl = url);
      }
    }
  }

  /// 资料卡:头像 + 昵称 + Matrix ID,底部「发消息 / 复制 ID」。
  Future<void> _showProfile() async {
    final contact = widget.contact;
    // 页面 context 用于关闭弹层后的提示与导航;弹层自身的 context
    // 在 pop 后随路由销毁,不能拿来做这些。
    final pageContext = context;
    await showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Padding(
          padding: const EdgeInsets.fromLTRB(
            NeuSpacing.xl,
            NeuSpacing.lg,
            NeuSpacing.xl,
            NeuSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppAvatar(
                fallback: contact.name,
                size: 84,
                radius: NeuRadius.nav,
                url: _resolvedAvatarUrl,
              ),
              const SizedBox(height: NeuSpacing.md),
              Text(
                contact.name,
                style: Theme.of(pageContext).textTheme.titleLarge,
              ),
              const SizedBox(height: NeuSpacing.xs),
              Text(
                contact.status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(pageContext).textTheme.bodySmall,
              ),
              const SizedBox(height: NeuSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: NeuButton(
                  accent: true,
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    _createDm();
                  },
                  child: const Center(child: Text('发消息')),
                ),
              ),
              const SizedBox(height: NeuSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: NeuButton(
                  intensity: .7,
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: contact.status));
                    Navigator.of(sheetContext).pop();
                    neuToast(pageContext, '已复制 Matrix ID');
                  },
                  child: const Center(child: Text('复制 ID')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createDm() async {
    // Entry guard (not only the disabled button): the rebuild lags a frame,
    // so a second tap could otherwise issue a duplicate createDm (two
    // concurrent scans would both miss the existing DM and create duplicate
    // rooms).
    if (_creatingDm) return;
    setState(() => _creatingDm = true);
    // Account snapshot: a switch while the request is in flight must not
    // redirect the write, and suppresses the feedback below (the room would
    // belong to the previous account).
    final accountUserId = ref.read(activeUserIdProvider) ?? '';
    try {
      final roomId = await createDm(
        accountUserId: accountUserId,
        userId: widget.contact.id,
      );
      // The account may have switched while the request was in flight: skip
      // the navigation — the chat page would open against a room of the
      // previous account. `mounted` first: `ref.read` throws after unmount
      // (Riverpod asserts on disposed widgets).
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) {
        return;
      }
      if (context.mounted) {
        final room = ref
            .read(allChatRoomsProvider)
            .asData
            ?.value
            .where((room) => room.id == roomId)
            .firstOrNull;
        final destination =
            room ??
            ChatRoom(
              id: roomId,
              name: widget.contact.name,
              avatarUrl: _resolvedAvatarUrl,
              lastMessage: '',
              lastMessageTime: '',
              lastEventId: '',
              unreadCount: 0,
              isMarkedUnread: false,
              roomType: 'dm',
              isEncrypted: false,
              isMuted: false,
              roomState: 'joined',
            );
        if (ref.read(desktopRoomNavigationProvider).open?.call(destination) ??
            false) {
          return;
        }
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatDetailPage(
              roomId: roomId,
              roomName: widget.contact.name,
              avatarUrl: _resolvedAvatarUrl,
            ),
          ),
        );
      }
    } catch (e) {
      // 账号可能在请求期间切换：跳过失败反馈（与成功路径一致）。
      // `mounted` first: `ref.read` throws after unmount.
      if (!mounted) return;
      if (ref.read(activeUserIdProvider) != accountUserId) {
        return;
      }
      if (context.mounted) {
        // Shared wording: timeout mapping and partial-success passthrough
        // come from the single `actionFailureMessage` source.
        neuToast(context, actionFailureMessage(e));
      }
    } finally {
      if (mounted) setState(() => _creatingDm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    return NeuAction(
      radius: context.isMaterial ? materialSurfaceRadius : NeuRadius.content,
      onTap: _showProfile,
      onPressedChanged: (value) => setState(() => _pressed = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        padding: EdgeInsets.symmetric(
          horizontal: context.isMaterial ? 12 : 8,
          vertical: 10,
        ),
        decoration: ShapeDecoration(
          color: _pressed ? context.neu.accentSoft : null,
          shape: context.isMaterial
              ? materialListItemShape
              : (ChatVisualSettingsScope.maybeOf(context)
                        ?.superellipseBorderEnabled ??
                    true)
              ? RoundedSuperellipseBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.content),
                )
              : RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(NeuRadius.content),
                ),
        ),
        child: Row(
          children: [
            AppAvatar(
              fallback: contact.name,
              size: context.isMaterial ? materialListAvatarSize : 48,
              radius: NeuRadius.content,
              url: _resolvedAvatarUrl,
            ),
            SizedBox(width: context.isMaterial ? materialListContentGap : 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    maxLines: context.isMaterial ? 1 : null,
                    overflow: context.isMaterial ? TextOverflow.ellipsis : null,
                    style: context.isMaterial
                        ? materialListTitleStyle(Theme.of(context))
                        : Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    contact.status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.isMaterial
                        ? Theme.of(context).textTheme.bodyMedium
                        : Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: NeuSpacing.sm),
            if (context.isMaterial)
              IconButton(
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                tooltip: '发消息',
                onPressed: _creatingDm ? null : _createDm,
              )
            else
              NeuIconButton(
                icon: Icons.chat_bubble_outline_rounded,
                size: 36,
                tooltip: '发消息',
                onPressed: _creatingDm ? null : _createDm,
              ),
          ],
        ),
      ),
    );
  }
}
