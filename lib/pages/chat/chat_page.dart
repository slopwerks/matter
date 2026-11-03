import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../features/audio/audio_playback_provider.dart';
import '../../features/audio/audio_message_bar.dart';
import '../../features/audio/audio_player_panel.dart';
import '../../providers/chat_provider.dart';
import '../../providers/hidden_rooms_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../providers/connection_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/cascade_title.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/neu_surface.dart';
import 'create_chat_page.dart';
import 'chat_detail_page.dart';
import 'chat_list_item.dart';
import 'hidden_rooms_page.dart';
import 'search_page.dart';

class ChatPage extends ConsumerStatefulWidget {
  final ValueChanged<ChatRoom>? onRoomSelected;
  final String? selectedRoomId;
  final bool embedded;
  final String? title;
  final String? emptyLabel;
  final String? spaceId;
  final bool directMessagesOnly;
  final bool ungroupedRoomsOnly;
  final bool showFloatingActionButton;
  final bool autoSelectFirstRoom;

  const ChatPage({
    super.key,
    this.onRoomSelected,
    this.selectedRoomId,
    this.embedded = false,
    this.title,
    this.emptyLabel,
    this.spaceId,
    this.directMessagesOnly = false,
    this.ungroupedRoomsOnly = false,
    this.showFloatingActionButton = true,
    this.autoSelectFirstRoom = true,
  }) : assert(!directMessagesOnly || !ungroupedRoomsOnly);

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// 移动端列表滚动控制器:驱动搜索栏渐隐与头部搜索图标的显现。
  final ScrollController _scrollController = ScrollController();
  final ValueNotifier<double> _searchCollapse = ValueNotifier(0);
  bool _headerSearchVisible = false;
  ({
    String? userId,
    String? spaceId,
    bool directMessagesOnly,
    bool ungroupedRoomsOnly,
    HiddenRoomsState hiddenRooms,
    AsyncValue<Set<String>>? ignoredUsers,
  })?
  _loadedRoomsScope;
  List<ChatRoom>? _loadedRooms;

  /// Material 使用标准工具栏高度;新拟物包含上下 padding 12 + 8。
  double get _headerHeight => context.isMaterial ? kToolbarHeight : 64;

  /// 搜索栏条目高度(顶部间距 + 凹陷输入框),滚动此距离后完全折叠。
  static const double _searchBarExtent = 56;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_syncSearchCollapse);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchCollapse.dispose();
    super.dispose();
  }

  void _syncSearchCollapse() {
    final offset = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    _searchCollapse.value = (offset / _searchBarExtent).clamp(0.0, 1.0);
    // 头部图标的显隐是时间动画(见 _buildHeader),加少量迟滞避免
    // 滚动位置停在阈值附近时反复触发。
    final show = _headerSearchVisible
        ? offset >= _searchBarExtent - 16
        : offset >= _searchBarExtent;
    if (show != _headerSearchVisible) {
      setState(() => _headerSearchVisible = show);
    }
  }

  Future<void> _openAudioSource() async {
    final track = ref.read(audioPlaybackSessionProvider).current;
    if (track?.roomId == null || track?.messageId == null) return;
    final rooms =
        ref.read(allChatRoomsProvider).asData?.value ?? const <ChatRoom>[];
    final room = rooms.where((room) => room.id == track!.roomId).firstOrNull;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailPage(
          roomId: track!.roomId!,
          roomName: room?.name ?? '音频消息',
          avatarUrl: room?.avatarUrl,
          isDm: room?.roomType == 'dm',
          initialMessageId: track.messageId,
        ),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ChatSearchPage()));
  }

  void _openCreateChat() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const CreateChatPage()));
  }

  // 只读入口:点击进入独立搜索页。
  Widget _buildSearchEntry() {
    return NeuAction(
      key: const ValueKey('open-chat-search'),
      label: '搜索消息或聊天',
      onTap: _openSearch,
      child: ExcludeFocus(
        child: ExcludeSemantics(
          child: IgnorePointer(child: const AppSearchField(hint: '搜索消息或聊天')),
        ),
      ),
    );
  }

  Widget _buildHeaderSearchEntry() {
    // 搜索栏滚出后用时间动画显示入口,避免慢拖时宽度长期停在中间态。
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _headerSearchVisible
            ? NeuIconButton(
                key: const ValueKey('header-search-entry'),
                icon: Icons.search_rounded,
                tooltip: '搜索',
                onPressed: _openSearch,
              )
            : const SizedBox.shrink(),
      ),
    );
  }

  Widget _buildHeader(String titleText, {required bool hasHiddenRooms}) {
    if (context.isMaterial) {
      return AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: widget.embedded ? null : Colors.transparent,
        title: CascadeTitle(
          text: titleText,
          style: Theme.of(context).textTheme.headlineSmall!,
        ),
        actions: [
          MaterialToolbar(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  _buildHeaderSearchEntry(),
                  if (hasHiddenRooms)
                    NeuIconButton(
                      icon: Icons.visibility_off_outlined,
                      tooltip: '隐藏的聊天',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const HiddenRoomsPage(),
                        ),
                      ),
                    ),
                  if (widget.embedded)
                    NeuIconButton(
                      icon: Icons.edit_outlined,
                      tooltip: '新聊天',
                      onPressed: _openCreateChat,
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
        child: Row(
          children: [
            Expanded(
              child: CascadeTitle(
                text: titleText,
                style: Theme.of(context).textTheme.headlineSmall!,
              ),
            ),
            _buildHeaderSearchEntry(),
            if (hasHiddenRooms)
              NeuIconButton(
                icon: Icons.visibility_off_outlined,
                tooltip: '隐藏的聊天',
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const HiddenRoomsPage()),
                ),
              ),
            NeuIconButton(
              icon: Icons.edit_square,
              tooltip: '新聊天',
              onPressed: _openCreateChat,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRooms(
    AsyncValue<List<ChatRoom>> roomsAsync, {
    required bool underHeader,
    required bool keepPreviousRooms,
    double audioHeight = 0,
  }) {
    final colors = context.neu;
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final headerHeight = _headerHeight;

    // 空列表、加载、错误状态下搜索栏仍固定显示在头部下方。
    Widget withSearchEntry(Widget child) {
      if (_searchCollapse.value != 0 || _headerSearchVisible) {
        // 列表消失后滚动状态失效,同步搜索栏和头部图标。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_scrollController.hasClients) {
            _syncSearchCollapse();
          }
        });
      }
      return Column(
        children: [
          SizedBox(height: topInset + headerHeight + audioHeight),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              NeuSpacing.xs,
              NeuSpacing.lg,
              0,
            ),
            child: _buildSearchEntry(),
          ),
          Expanded(child: child),
        ],
      );
    }

    // Riverpod's whenData drops the previous value on AsyncLoading, so the
    // derived inbox state needs this page's last rendered snapshot.
    final roomsForDisplay = keepPreviousRooms && roomsAsync.isLoading
        ? AsyncData(_loadedRooms!)
        : roomsAsync;
    return roomsForDisplay.when(
      skipLoadingOnReload: keepPreviousRooms,
      skipLoadingOnRefresh: keepPreviousRooms,
      data: (rooms) {
        if (widget.autoSelectFirstRoom &&
            !roomsAsync.isLoading &&
            widget.onRoomSelected != null &&
            widget.selectedRoomId == null) {
          final firstJoinedRoom = rooms.where(
            (room) => room.roomState == 'joined',
          );
          if (firstJoinedRoom.isNotEmpty) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                widget.onRoomSelected!(firstJoinedRoom.first);
              }
            });
          }
        }
        if (rooms.isEmpty) {
          final empty = Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.forum_outlined,
                    size: 44,
                    color: colors.textSecondary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    widget.emptyLabel ?? '暂无聊天',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
          );
          return underHeader ? withSearchEntry(empty) : empty;
        }
        if (!underHeader) {
          return ListView.separated(
            // 与联系人页同节奏:列表上 8。
            padding: const EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              NeuSpacing.sm,
              NeuSpacing.lg,
              NeuSpacing.xl,
            ),
            itemCount: rooms.length,
            findItemIndexCallback: (key) {
              final index = rooms.indexWhere(
                (room) => ValueKey(room.id) == key,
              );
              return index < 0 ? null : index;
            },
            separatorBuilder: (_, _) => const ChatListDivider(),
            itemBuilder: (context, index) {
              final room = rooms[index];
              return ChatListItem(
                key: ValueKey(room.id),
                room: room,
                isSelected: room.id == widget.selectedRoomId,
                onRoomSelected: widget.onRoomSelected,
              );
            },
          );
        }
        // 列表全高滚动、内容从头部的渐变模糊下方穿过;搜索栏是列表第一项,
        // 随滚动渐隐,滚出后头部露出搜索图标。
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (notification) {
            // 恢复滚动位置或布局纠正偏移时不会触发控制器监听。
            if (notification.depth == 0) _syncSearchCollapse();
            return false;
          },
          child: ListView.separated(
            controller: _scrollController,
            padding: EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              topInset + headerHeight + audioHeight,
              NeuSpacing.lg,
              context.isMaterial
                  ? NeuSpacing.floatingDockClearance +
                        MediaQuery.paddingOf(context).bottom
                  : NeuSpacing.navClearance,
            ),
            itemCount: rooms.length + 1,
            findItemIndexCallback: (key) {
              final index = rooms.indexWhere(
                (room) => ValueKey(room.id) == key,
              );
              return index < 0 ? null : index + 1;
            },
            separatorBuilder: (_, index) => index == 0
                ? const SizedBox(height: NeuSpacing.sm)
                : const ChatListDivider(),
            itemBuilder: (context, index) {
              if (index == 0) {
                return ValueListenableBuilder<double>(
                  valueListenable: _searchCollapse,
                  builder: (context, collapse, child) =>
                      Opacity(opacity: 1 - collapse, child: child),
                  child: Padding(
                    padding: const EdgeInsets.only(top: NeuSpacing.xs),
                    child: _buildSearchEntry(),
                  ),
                );
              }
              final room = rooms[index - 1];
              return ChatListItem(
                key: ValueKey(room.id),
                room: room,
                isSelected: room.id == widget.selectedRoomId,
                onRoomSelected: widget.onRoomSelected,
              );
            },
          ),
        );
      },
      loading: () {
        final loading = Center(
          child: CircularProgressIndicator(
            color: colors.accent,
            strokeWidth: 2,
          ),
        );
        return underHeader ? withSearchEntry(loading) : loading;
      },
      error: (err, _) {
        final error = Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: SelectableText(
              '加载失败: $err',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        );
        return underHeader ? withSearchEntry(error) : error;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final audioVisible =
        ref.watch(audioPlayerVisibleProvider) &&
        (!widget.embedded || widget.selectedRoomId == null);
    final audioSession = ref.read(audioPlaybackSessionProvider);
    final audioHeight = audioVisible ? audioMessageBarHeight : 0.0;
    final AsyncValue<List<ChatRoom>> roomsAsync;
    if (widget.spaceId case final spaceId?) {
      roomsAsync = ref.watch(spaceChildrenProvider(spaceId));
    } else if (widget.directMessagesOnly) {
      roomsAsync = ref
          .watch(inboxRoomsProvider)
          .whenData(
            (rooms) => rooms.where((room) => room.roomType == 'dm').toList(),
          );
    } else if (widget.ungroupedRoomsOnly) {
      roomsAsync = ref
          .watch(ungroupedRoomsProvider)
          .whenData(
            (rooms) => rooms.where((room) => room.roomType != 'dm').toList(),
          );
    } else {
      roomsAsync = ref.watch(inboxRoomsProvider);
    }
    final connectionLabel = ref.watch(connectionLabelProvider);
    final allRooms = ref.watch(allChatRoomsProvider).asData?.value;
    final roomsScope = (
      userId: ref.watch(activeUserIdProvider),
      spaceId: widget.spaceId,
      directMessagesOnly: widget.directMessagesOnly,
      ungroupedRoomsOnly: widget.ungroupedRoomsOnly,
      hiddenRooms: ref.watch(hiddenRoomsProvider),
      ignoredUsers: ref.exists(ignoredUserIdsProvider)
          ? ref.watch(ignoredUserIdsProvider)
          : null,
    );
    // Keep the existing list during a background fetch, but not when its
    // account, visibility or room scope changes.
    if (!roomsAsync.isLoading && roomsAsync.hasValue && !roomsAsync.hasError) {
      _loadedRoomsScope = roomsScope;
      _loadedRooms = roomsAsync.requireValue;
    }
    final keepPreviousRooms = _loadedRoomsScope == roomsScope;
    final hiddenRooms = ref.read(hiddenRoomsProvider.notifier);
    final hasHiddenRooms = allRooms?.any(hiddenRooms.isHidden) ?? false;

    final titleText =
        widget.title ??
        (connectionLabel.isNotEmpty ? connectionLabel : 'Matter');

    if (widget.embedded) {
      // 桌面端内嵌:搜索栏固定,列表不穿透头部。
      return ColoredBox(
        color: colors.base,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(titleText, hasHiddenRooms: hasHiddenRooms),
            if (audioVisible)
              AudioMessageBar(
                session: audioSession,
                onSourceTap: () => unawaited(_openAudioSource()),
                onQueueTap: () =>
                    unawaited(showAudioPlayerPanel(context, audioSession)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.lg,
                NeuSpacing.xs,
                NeuSpacing.lg,
                0,
              ),
              child: _buildSearchEntry(),
            ),
            Expanded(
              child: _buildRooms(
                roomsAsync,
                underHeader: false,
                keepPreviousRooms: keepPreviousRooms,
              ),
            ),
          ],
        ),
      );
    }

    final topInset = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      floatingActionButton:
          context.isMaterial && widget.showFloatingActionButton
          ? FloatingActionButton(
              tooltip: '新聊天',
              onPressed: _openCreateChat,
              child: const Icon(Icons.edit_outlined),
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: _buildRooms(
              roomsAsync,
              underHeader: true,
              keepPreviousRooms: keepPreviousRooms,
              audioHeight: audioHeight,
            ),
          ),
          if (audioVisible)
            Positioned(
              top: topInset + _headerHeight,
              left: 0,
              right: 0,
              child: AudioMessageBar(
                session: audioSession,
                onSourceTap: () => unawaited(_openAudioSource()),
                onQueueTap: () =>
                    unawaited(showAudioPlayerPanel(context, audioSession)),
              ),
            ),
          // 渐变模糊头部:柔和过渡从下方滚过的内容,避免硬裁切感。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topInset + _headerHeight,
            child: const TopFadeBlur(useShader: true),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topInset + _headerHeight,
            child: _buildHeader(titleText, hasHiddenRooms: hasHiddenRooms),
          ),
        ],
      ),
    );
  }
}
