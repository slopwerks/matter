import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/neu_surface.dart';
import 'chat_detail_page.dart';
import 'chat_list_item.dart';
import 'chat_timestamp.dart';

const _searchPageSize = 30;
const _searchHistoryEmptyPageLimit = 8;

/// 搜索框行的实测高度:上下内边距 8/4 加输入框自身高度 50。
const _searchFieldRowHeight = 62.0;

List<rust.ChatRoom> filterRoomsForSearch(
  List<rust.ChatRoom> rooms,
  String query,
) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return const [];
  return rooms.where((room) {
    if (room.roomState != 'joined') return false;
    return room.name.toLowerCase().contains(normalized) ||
        room.id.toLowerCase().contains(normalized);
  }).toList();
}

class ChatSearchPage extends ConsumerStatefulWidget {
  final String? roomId;

  const ChatSearchPage({super.key, this.roomId});

  @override
  ConsumerState<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends ConsumerState<ChatSearchPage>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounce;
  String _query = '';
  String _activeQuery = '';
  TabController? _tabController;
  int _selectedTab = 0;

  bool get _isRoomSearch => widget.roomId != null;

  @override
  void initState() {
    super.initState();
    if (!_isRoomSearch) {
      _tabController = TabController(length: 2, vsync: this)
        ..addListener(_handleTabChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _handleTabChanged() {
    final index = _tabController?.index ?? 0;
    if (index == _selectedTab || !mounted) return;
    setState(() => _selectedTab = index);
    if (index != 0) _cancelPendingMessageSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _cancelPendingMessageSearch();
    _tabController
      ?..removeListener(_handleTabChanged)
      ..dispose();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _cancelPendingMessageSearch();
    setState(() {
      _query = value;
      _activeQuery = '';
    });
    _debounce = Timer(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      setState(() => _activeQuery = value.trim());
    });
  }

  void _onQuerySubmitted(String value) {
    _debounce?.cancel();
    final submitted = value.trim();
    if (submitted == _activeQuery) return;
    _cancelPendingMessageSearch();
    setState(() {
      _query = value;
      _activeQuery = submitted;
    });
  }

  void _clearQuery() {
    _debounce?.cancel();
    _cancelPendingMessageSearch();
    _controller.clear();
    setState(() {
      _query = '';
      _activeQuery = '';
    });
    _focusNode.requestFocus();
  }

  void _cancelPendingMessageSearch() {
    if (_activeQuery.isEmpty) return;
    try {
      unawaited(
        rust.cancelMessageSearch(roomId: widget.roomId).catchError((_) {}),
      );
    } catch (_) {
      // Widget tests can override the provider without initializing Rust.
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final searchFieldRowHeight = context.isMaterial
        ? 68.0
        : _searchFieldRowHeight;
    final searchField = AppSearchField(
      key: const ValueKey('chat-search-field'),
      controller: _controller,
      focusNode: _focusNode,
      hint: _isRoomSearch ? '搜索此聊天的消息' : '搜索消息或聊天',
      textInputAction: TextInputAction.search,
      trailing: _query.isEmpty
          ? null
          : context.isMaterial
          ? IconButton(
              icon: const Icon(Icons.close),
              tooltip: '清除搜索',
              onPressed: _clearQuery,
            )
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _clearQuery,
              child: const Icon(Icons.close_rounded),
            ),
      onChanged: _onQueryChanged,
      onSubmitted: _onQuerySubmitted,
    );
    final header = Padding(
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
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(width: NeuSpacing.sm),
          Expanded(child: searchField),
        ],
      ),
    );

    final tabBar = _isRoomSearch
        ? null
        : TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '消息'),
              Tab(text: '聊天'),
            ],
            labelColor: context.isMaterial ? null : colors.accent,
            unselectedLabelColor: context.isMaterial
                ? null
                : colors.textTertiary,
            indicatorColor: context.isMaterial ? null : colors.accent,
            dividerColor: context.isMaterial ? null : colors.hairline,
          );
    // 浮动标题栏的高度(搜索框行 + 标签栏),同时用作结果列表的顶部内边距
    // 和渐变模糊层的高度,结果滚动时从标题栏下方穿过。
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    final headerHeight =
        searchFieldRowHeight + (tabBar?.preferredSize.height ?? 0);
    final topInset = viewPaddingTop + headerHeight;

    final messageSearchKey = ValueKey(
      Object.hash(
        'message-search',
        ref.watch(activeUserIdProvider),
        widget.roomId,
      ),
    );
    final body = _isRoomSearch
        ? _MessageSearchResults(
            key: messageSearchKey,
            query: _activeQuery,
            roomId: widget.roomId,
            topInset: topInset,
          )
        : TabBarView(
            controller: _tabController,
            children: [
              _MessageSearchResults(
                key: messageSearchKey,
                active: _selectedTab == 0,
                query: _activeQuery,
                topInset: topInset,
              ),
              _RoomSearchResults(
                active: _selectedTab == 1,
                query: _query,
                topInset: topInset,
              ),
            ],
          );

    final scaffold = Scaffold(
      backgroundColor: context.isMaterial ? null : colors.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: '返回',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              toolbarHeight: searchFieldRowHeight,
              title: searchField,
              bottom: tabBar,
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(child: body),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: topInset,
              child: const TopFadeBlur(useShader: true),
            ),
          // 标题栏移到上方浮层,结果从它下方穿过。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: headerHeight,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [header, ?tabBar],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          _debounce?.cancel();
          _cancelPendingMessageSearch();
        }
      },
      child: scaffold,
    );
  }
}

class _MessageSearchResults extends ConsumerStatefulWidget {
  final bool active;
  final String query;
  final String? roomId;

  /// 浮动标题栏占用的顶部内边距(设备顶部安全区 + 标题栏高度)。
  final double topInset;

  const _MessageSearchResults({
    super.key,
    this.active = true,
    required this.query,
    this.roomId,
    required this.topInset,
  });

  @override
  ConsumerState<_MessageSearchResults> createState() =>
      _MessageSearchResultsState();
}

class _MessageSearchResultsState extends ConsumerState<_MessageSearchResults> {
  final Map<String, rust.MessageSearchResult> _completedResults = {};
  List<String> _terms = const [];
  int _offset = 0;
  int _backfillGeneration = 0;
  bool _backfillRunning = false;
  Object? _backfillError;
  rust.MessageSearchPage? _progressivePage;
  String? _searchAccount;

  void _resetSearch() {
    _backfillGeneration++;
    _backfillRunning = false;
    _backfillError = null;
    _progressivePage = null;
    _completedResults.clear();
    _terms = const [];
    _offset = 0;
  }

  @override
  void didUpdateWidget(covariant _MessageSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.roomId != widget.roomId ||
        oldWidget.active != widget.active) {
      _resetSearch();
    }
  }

  @override
  void dispose() {
    _backfillGeneration++;
    super.dispose();
  }

  MessageSearchRequest get _request {
    return MessageSearchRequest(
      query: widget.query,
      roomId: widget.roomId,
      offset: _offset,
      limit: _searchPageSize,
    );
  }

  void _loadMore(rust.MessageSearchPage page, MessageSearchRequest request) {
    final nextOffset = request.offset + request.limit;
    setState(() {
      _progressivePage = null;
      _backfillError = null;
      for (final result in page.results) {
        _completedResults['${result.roomId}\n${result.eventId}'] = result;
      }
      _terms = page.terms;
      _offset = nextOffset;
    });
  }

  void _startHistoryBackfill(rust.MessageSearchPage page) {
    if (page.historyComplete || _backfillRunning || _backfillError != null) {
      return;
    }
    _progressivePage ??= page;
    _backfillRunning = true;
    _backfillError = null;
    final generation = ++_backfillGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _backfillGeneration) return;
      unawaited(_runHistoryBackfill(widget.roomId, generation));
    });
  }

  Future<void> _runHistoryBackfill(String? roomId, int generation) async {
    final account = ref.read(activeUserIdProvider);
    var emptyPages = 0;
    bool current() =>
        mounted &&
        widget.active &&
        generation == _backfillGeneration &&
        ref.read(activeUserIdProvider) == account;
    try {
      while (current()) {
        final progress = await ref.read(messageSearchHistoryBackfillProvider)(
          roomId,
        );
        if (!current()) return;

        final request = _request;
        try {
          await rust.cancelMessageSearch(roomId: roomId).catchError((_) {});
        } catch (_) {
          // Widget tests can run without initializing Rust; the superseded
          // search cancellation is best-effort anyway.
        }
        if (!current()) return;
        ref.invalidate(messageSearchProvider(request));
        final refreshed = await ref.read(messageSearchProvider(request).future);
        if (!current()) return;
        setState(() {
          _progressivePage = refreshed;
          _terms = refreshed.terms;
        });
        await WidgetsBinding.instance.endOfFrame;

        if (progress.reachedStart) break;
        // The SDK may advance a gap while returning no events. A bounded
        // series of empty steps is retryable, not proof that history ended.
        emptyPages = progress.loadedEvents == 0 ? emptyPages + 1 : 0;
        if (emptyPages >= _searchHistoryEmptyPageLimit) {
          throw StateError('搜索较早消息暂未取得进展，请重试继续');
        }
      }
    } catch (error) {
      if (mounted && generation == _backfillGeneration) {
        setState(() => _backfillError = error);
      }
    } finally {
      if (mounted && generation == _backfillGeneration) {
        setState(() => _backfillRunning = false);
      }
    }
  }

  void _retryHistoryBackfill() {
    final page = _progressivePage;
    if (page == null) return;
    setState(() => _backfillError = null);
    _startHistoryBackfill(page);
  }

  Widget _pageAction({
    required bool loading,
    required Object? error,
    required bool canLoadMore,
    required MessageSearchRequest request,
    rust.MessageSearchPage? page,
  }) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: NeuButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => ref.invalidate(messageSearchProvider(request)),
            child: const Text('加载失败，点击重试'),
          ),
        ),
      );
    }
    if (canLoadMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: NeuButton(
            icon: const Icon(Icons.expand_more_rounded),
            onPressed: page == null ? null : () => _loadMore(page, request),
            child: const Text('加载更多'),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final account = ref.watch(activeUserIdProvider);
    if (_searchAccount != account) {
      _searchAccount = account;
      _resetSearch();
    }
    if (!widget.active || widget.query.isEmpty) {
      return const SizedBox.shrink();
    }
    final request = _request;
    final search = ref.watch(messageSearchProvider(request));
    final page = _progressivePage ?? search.asData?.value;
    if (page != null) {
      _startHistoryBackfill(page);
    }
    if (_completedResults.isEmpty && page == null) {
      if (search.hasError) {
        return _SearchStatus(
          icon: Icons.error_outline_rounded,
          text: '搜索暂时不可用，请重试',
          action: NeuIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '重试',
            onPressed: () => ref.invalidate(messageSearchProvider(request)),
          ),
        );
      }
      return Center(
        child: CircularProgressIndicator(color: colors.accent, strokeWidth: 2),
      );
    }

    final resultsById = Map<String, rust.MessageSearchResult>.of(
      _completedResults,
    );
    if (page != null) {
      for (final result in page.results) {
        resultsById['${result.roomId}\n${result.eventId}'] = result;
      }
    }
    final results = resultsById.values.toList(growable: false);
    if (results.isEmpty && page != null && !page.historyComplete) {
      if (_backfillError != null) {
        return _SearchStatus(
          icon: Icons.error_outline_rounded,
          text: '搜索较早消息失败，请重试',
          action: NeuIconButton(
            icon: Icons.refresh_rounded,
            tooltip: '重试',
            onPressed: _retryHistoryBackfill,
          ),
        );
      }
      return Center(
        child: CircularProgressIndicator(color: colors.accent, strokeWidth: 2),
      );
    }
    if (results.isEmpty && page != null) {
      return const _SearchStatus(
        icon: Icons.search_off_rounded,
        text: '没有找到匹配的消息',
      );
    }

    final loadingMore = _completedResults.isNotEmpty && search.isLoading;
    final loadMoreError = _completedResults.isNotEmpty ? search.error : null;
    final canLoadMore = page?.hasMore == true;
    final historyIncomplete = page != null && !page.historyComplete;
    final showPageAction = loadingMore || loadMoreError != null || canLoadMore;
    return ListView.builder(
      key: PageStorageKey(
        Object.hash('message-search-results', widget.roomId, widget.query),
      ),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        NeuSpacing.lg,
        widget.topInset + NeuSpacing.sm,
        NeuSpacing.lg,
        NeuSpacing.xl,
      ),
      itemCount: results.length + (showPageAction || historyIncomplete ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == results.length) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (historyIncomplete)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _backfillError != null
                      ? NeuButton(
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: _retryHistoryBackfill,
                          child: const Text('搜索较早消息失败，点击重试'),
                        )
                      : const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(height: 8),
                            Text('正在搜索较早消息…'),
                          ],
                        ),
                ),
              if (showPageAction)
                _pageAction(
                  loading: loadingMore,
                  error: loadMoreError,
                  canLoadMore: canLoadMore,
                  request: request,
                  page: page,
                ),
            ],
          );
        }
        return _MessageSearchTile(
          result: results[index],
          terms: page?.terms ?? _terms,
          roomScoped: widget.roomId != null,
        );
      },
    );
  }
}

class _MessageSearchTile extends ConsumerWidget {
  final rust.MessageSearchResult result;
  final List<String> terms;
  final bool roomScoped;

  const _MessageSearchTile({
    required this.result,
    required this.terms,
    required this.roomScoped,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.only(bottom: NeuSpacing.md),
      child: NeuAction(
        key: ValueKey('message-search-result-${result.eventId}'),
        radius: NeuRadius.content,
        onTap: () => _openResult(context, ref),
        child: NeuSurface(
          color: colors.card,
          radius: NeuRadius.content,
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppAvatar(
                fallback: roomScoped ? result.senderName : result.roomName,
                size: 40,
                radius: NeuRadius.content,
                url: roomScoped ? null : result.roomAvatarUrl,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            roomScoped ? result.senderName : result.roomName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatChatListTime(result.timestamp),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (!roomScoped) ...[
                      const SizedBox(height: 2),
                      Text(
                        result.isEdited
                            ? '${result.senderName} · 已编辑'
                            : result.senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    const SizedBox(height: 5),
                    _HighlightedMessageText(text: result.body, terms: terms),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openResult(BuildContext context, WidgetRef ref) async {
    if (roomScoped) {
      Navigator.of(context).pop(result.eventId);
      return;
    }

    rust.ChatRoom? room;
    try {
      final rooms = await ref.read(chatRoomsProvider.future);
      for (final candidate in rooms) {
        if (candidate.id == result.roomId) {
          room = candidate;
          break;
        }
      }
    } catch (_) {
      // The indexed snapshot remains enough to open the result when the room
      // list is temporarily unavailable.
    }
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatDetailPage(
          roomId: result.roomId,
          roomName: room?.name ?? result.roomName,
          avatarUrl: room?.avatarUrl ?? result.roomAvatarUrl,
          nameEventId: room?.nameEventId,
          avatarEventId: room?.avatarEventId,
          isDm: room == null ? result.isDm : room.roomType == 'dm',
          initialMessageId: result.eventId,
        ),
      ),
    );
  }
}

({String text, List<int> starts, List<int> ends}) _lowercaseWithOffsets(
  String source,
) {
  final normalized = StringBuffer();
  final starts = <int>[];
  final ends = <int>[];
  var sourceOffset = 0;
  for (final rune in source.runes) {
    final character = String.fromCharCode(rune);
    final lowered = character.toLowerCase();
    final sourceEnd = sourceOffset + character.length;
    normalized.write(lowered);
    for (var index = 0; index < lowered.length; index++) {
      starts.add(sourceOffset);
      ends.add(sourceEnd);
    }
    sourceOffset = sourceEnd;
  }
  return (text: normalized.toString(), starts: starts, ends: ends);
}

List<TextRange> messageHighlightRanges(String text, List<String> terms) {
  final normalizedText = _lowercaseWithOffsets(text);
  final ranges = <TextRange>[];
  for (final term in terms) {
    final normalizedTerm = _lowercaseWithOffsets(term).text;
    if (normalizedTerm.isEmpty) continue;
    var from = 0;
    while (from < normalizedText.text.length) {
      final start = normalizedText.text.indexOf(normalizedTerm, from);
      if (start < 0) break;
      final end = start + normalizedTerm.length;
      ranges.add(
        TextRange(
          start: normalizedText.starts[start],
          end: normalizedText.ends[end - 1],
        ),
      );
      from = end;
    }
  }
  if (ranges.isEmpty) return const [];
  ranges.sort((left, right) => left.start.compareTo(right.start));
  final merged = <TextRange>[];
  for (final range in ranges) {
    if (merged.isEmpty || range.start > merged.last.end) {
      merged.add(range);
      continue;
    }
    final previous = merged.removeLast();
    merged.add(
      TextRange(
        start: previous.start,
        end: range.end > previous.end ? range.end : previous.end,
      ),
    );
  }
  return merged;
}

class _HighlightedMessageText extends StatelessWidget {
  final String text;
  final List<String> terms;

  const _HighlightedMessageText({required this.text, required this.terms});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final ranges = messageHighlightRanges(text, terms);
    final normalStyle = Theme.of(context).textTheme.bodyMedium;
    if (ranges.isEmpty) {
      return Text(
        text,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: normalStyle,
      );
    }
    final spans = <TextSpan>[];
    var offset = 0;
    for (final range in ranges) {
      if (range.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, range.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: TextStyle(color: colors.accent, fontWeight: FontWeight.w700),
        ),
      );
      offset = range.end;
    }
    if (offset < text.length) {
      spans.add(TextSpan(text: text.substring(offset)));
    }
    return Text.rich(
      TextSpan(style: normalStyle, children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _RoomSearchResults extends ConsumerWidget {
  final bool active;
  final String query;

  /// 浮动标题栏占用的顶部内边距(设备顶部安全区 + 标题栏高度)。
  final double topInset;

  const _RoomSearchResults({
    required this.active,
    required this.query,
    required this.topInset,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.neu;
    if (!active || query.trim().isEmpty) return const SizedBox.shrink();
    return ref
        .watch(chatRoomsProvider)
        .when(
          loading: () => Center(
            child: CircularProgressIndicator(
              color: colors.accent,
              strokeWidth: 2,
            ),
          ),
          error: (error, _) => _SearchStatus(
            icon: Icons.error_outline_rounded,
            text: '加载聊天失败: $error',
          ),
          data: (rooms) {
            final results = filterRoomsForSearch(rooms, query);
            if (results.isEmpty) {
              return const _SearchStatus(
                icon: Icons.search_off_rounded,
                text: '没有找到匹配的聊天',
              );
            }
            return ListView.separated(
              key: PageStorageKey(Object.hash('room-search-results', query)),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                NeuSpacing.lg,
                topInset + NeuSpacing.sm,
                NeuSpacing.lg,
                NeuSpacing.xl,
              ),
              itemCount: results.length,
              separatorBuilder: (_, _) => const ChatListDivider(),
              itemBuilder: (_, index) => ChatListItem(room: results[index]),
            );
          },
        );
  }
}

class _SearchStatus extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? action;

  const _SearchStatus({required this.icon, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NeuSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NeuIconButton(icon: icon, size: 84, onPressed: null),
            const SizedBox(height: NeuSpacing.lg),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (action != null) ...[
              const SizedBox(height: NeuSpacing.sm),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
