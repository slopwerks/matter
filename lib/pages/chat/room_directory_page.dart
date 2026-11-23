import 'dart:async';

import 'package:flutter/material.dart';

import '../../widgets/material_list_detail.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/tokens.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/max_content_width.dart';
import 'chat_detail_page.dart';
import 'space_detail_page.dart';

class RoomDirectoryPage extends ConsumerStatefulWidget {
  const RoomDirectoryPage({
    super.key,
    this.focusAddress = false,
    this.spaceAddress = false,
  });
  final bool focusAddress;
  final bool spaceAddress;

  static Future<void> open(
    BuildContext context, {
    bool focusAddress = false,
    bool spaceAddress = false,
  }) => MaterialListDetail.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => RoomDirectoryPage(
        focusAddress: focusAddress,
        spaceAddress: spaceAddress,
      ),
    ),
  );

  @override
  ConsumerState<RoomDirectoryPage> createState() => _RoomDirectoryPageState();
}

class _RoomDirectoryPageState extends ConsumerState<RoomDirectoryPage> {
  final _focus = FocusNode();
  final _controller = TextEditingController();
  late final String? _account;
  Timer? _debounce;
  int _revision = 0;
  List<rust.DirectoryRoom> _rooms = [];
  final _membership = <String, ({String previous, String state})>{};
  final _working = <String>{};
  String? _next;
  String? _error;
  bool _loading = true;

  bool get _current =>
      mounted && _account != null && ref.read(activeUserIdProvider) == _account;
  bool _isAddress(String text) =>
      text.startsWith('!') ||
      text.startsWith('#') ||
      text.startsWith('matrix:') ||
      Uri.tryParse(text)?.hasScheme == true;

  @override
  void initState() {
    super.initState();
    _account = ref.read(activeUserIdProvider);
    if (widget.focusAddress || widget.spaceAddress) _focus.requestFocus();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _search(String value, {bool immediate = false}) {
    _debounce?.cancel();
    ++_revision;
    setState(() {
      _rooms = [];
      _next = null;
      _loading = true;
      _error = null;
    });
    if (immediate) {
      _load();
    } else {
      _debounce = Timer(const Duration(milliseconds: 300), _load);
    }
  }

  Future<void> _load({String? since}) async {
    if (!_current) return;
    final revision = ++_revision;
    final query = _controller.text.trim();
    if (widget.spaceAddress && !_isAddress(query)) {
      setState(() => _loading = false);
      return;
    }
    if (!_loading || _error != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final rust.DirectoryRoomPage result;
      if (_isAddress(query)) {
        final room = await rust.previewRoomAddress(
          accountUserId: _account!,
          address: query,
        );
        result = rust.DirectoryRoomPage(rooms: [room]);
      } else {
        result = await rust.searchRoomDirectory(
          accountUserId: _account!,
          query: query,
          since: since,
        );
      }
      if (!_current || revision != _revision) return;
      setState(() {
        for (final room in result.rooms) {
          final pending = _membership[room.id];
          // Keep immediate feedback only while sync still reports the old
          // state. A confirmed change (including an invitation) supersedes it.
          if (pending != null && room.state != pending.previous) {
            _membership.remove(room.id);
          }
        }
        final byId = {
          if (since != null)
            for (final room in _rooms) room.id: room,
          for (final room in result.rooms) room.id: room,
        };
        _rooms = byId.values.toList();
        _next = result.next == since ? null : result.next;
        _loading = false;
      });
    } catch (error) {
      if (_current && revision == _revision) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  void _openRoom(rust.DirectoryRoom room) {
    final name = room.name ?? room.alias ?? room.id;
    if (room.isSpace) {
      MaterialListDetail.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SpaceDetailPage(
            space: rust.Space(
              id: room.id,
              name: name,
              avatarUrl: room.avatarUrl,
            ),
          ),
        ),
      );
      return;
    }
    final cached = ref
        .read(allChatRoomsProvider)
        .value
        ?.where((r) => r.id == room.id)
        .firstOrNull;
    if (cached != null &&
        (ref.read(desktopRoomNavigationProvider).open?.call(cached) ?? false)) {
      return;
    }
    MaterialListDetail.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailPage(
          roomId: room.id,
          roomName: name,
          avatarUrl: room.avatarUrl,
          isDm: cached?.roomType == 'dm',
        ),
      ),
    );
  }

  Future<void> _enter(rust.DirectoryRoom room, {required bool knock}) async {
    if (!_current || !_working.add(room.id)) return;
    setState(() {});
    try {
      await rust.enterDirectoryRoom(
        accountUserId: _account!,
        roomId: room.id,
        via: room.via,
        knock: knock,
      );
      if (!mounted || !_current) return;
      _membership[room.id] = (
        previous: room.state,
        state: knock ? 'knocked' : 'joined',
      );
      ref.invalidate(allChatRoomsProvider);
      ref.invalidate(allUngroupedRoomsProvider);
      ref.invalidate(spacesProvider);
      ref.invalidate(searchRoomsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            knock
                ? '已发送加入申请'
                : room.isSpace
                ? '已加入空间'
                : '已加入房间',
          ),
        ),
      );
    } catch (error) {
      if (mounted && _current) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _working.remove(room.id));
    }
  }

  Widget _action(rust.DirectoryRoom room) {
    if (widget.spaceAddress && !room.isSpace) return const Text('未识别为空间');
    final state = _membership[room.id]?.state ?? room.state;
    final busy = _working.contains(room.id);
    final knock =
        room.joinRule == 'knock' || room.joinRule == 'knock_restricted';
    final label = switch (state) {
      'joined' => '打开会话',
      'knocked' => '已申请',
      'banned' => '无法加入',
      'invited' => '接受邀请',
      _ when knock => '申请加入',
      _ when room.joinRule == 'invite' || room.joinRule == 'private' => '需要邀请',
      _ => '加入',
    };
    if (state == 'knocked' || state == 'banned' || label == '需要邀请') {
      return Text(label);
    }
    return FilledButton.tonal(
      onPressed: busy
          ? null
          : () {
              if (state == 'joined') {
                _openRoom(room);
              } else {
                _enter(room, knock: state != 'invited' && knock);
              }
            },
      child: Text(
        busy
            ? '处理中…'
            : room.isSpace && state == 'joined'
            ? '打开空间'
            : label,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final spacing = context.tokens.spacing;
    final current = ref.watch(activeUserIdProvider);
    final query = _controller.text.trim();
    return Scaffold(
      appBar: buildFloatingAppBar(
        title: Text(widget.spaceAddress ? '加入空间' : '查找房间'),
      ),
      body: current == null || current != _account
          ? const Center(child: Text('请从当前账号重新打开房间目录'))
          : MaxContentWidth(
              child: Column(
                children: [
                  Padding(
                    padding: EdgeInsets.all(spacing.lg),
                    child: AppSearchField(
                      controller: _controller,
                      focusNode: _focus,
                      hint: widget.spaceAddress
                          ? '输入空间 ID、别名或粘贴链接'
                          : '搜索房间名，或粘贴房间地址',
                      textInputAction: TextInputAction.search,
                      onChanged: _search,
                      onSubmitted: (s) => _search(s, immediate: true),
                      trailing: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                _controller.clear();
                                _search('', immediate: true);
                              },
                            ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: EdgeInsets.symmetric(horizontal: spacing.lg),
                      itemCount: _rooms.length + 2,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return Padding(
                            padding: EdgeInsets.only(bottom: spacing.sm),
                            child: Text(
                              widget.spaceAddress
                                  ? '空间预览'
                                  : _isAddress(query)
                                  ? '房间预览'
                                  : query.isEmpty
                                  ? '公开房间'
                                  : '搜索结果',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          );
                        }
                        if (index > _rooms.length) {
                          if (_loading) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (_error != null) {
                            return Column(
                              children: [
                                Text(_error!),
                                TextButton(
                                  onPressed: () => _load(since: _next),
                                  child: const Text('重试'),
                                ),
                              ],
                            );
                          }
                          if (_next != null) {
                            return TextButton(
                              onPressed: () => _load(since: _next),
                              child: const Text('加载更多'),
                            );
                          }
                          if (_rooms.isEmpty) {
                            return Center(
                              child: Text(
                                widget.spaceAddress
                                    ? '请输入空间地址查看预览'
                                    : query.isEmpty
                                    ? '当前服务器没有列出公开房间'
                                    : '没有找到匹配的房间',
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        }
                        final room = _rooms[index - 1];
                        final name = room.name ?? room.alias ?? room.id;
                        return ListTile(
                          contentPadding: EdgeInsets.symmetric(
                            vertical: spacing.xs,
                          ),
                          leading: AppAvatar(
                            fallback: name,
                            url: room.avatarUrl,
                            size: 40,
                          ),
                          title: Text(name),
                          subtitle: Text(
                            [
                              room.alias ?? room.id,
                              if (_isAddress(query) &&
                                  room.joinRule == null &&
                                  room.state == 'left')
                                '服务器未提供加入规则',
                              if (room.topic?.isNotEmpty == true) room.topic!,
                            ].join('\n'),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: _action(room),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
