import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'composer_picker_panel.dart';
import 'date_separator.dart';
import 'message_group.dart';
import 'message_input.dart';

class ChatDetailPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final String subtitle;
  final bool isDm;

  const ChatDetailPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.subtitle = '在线',
    this.isDm = false,
  });

  @override
  ConsumerState<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends ConsumerState<ChatDetailPage> {
  final _scrollController = ScrollController();
  final _scrollViewportKey = GlobalKey();
  final List<ChatMessage> _olderMessages = [];
  final List<MessageGroup> _groupedMessages = [];
  final Map<String, ChatMessage> _messageIndex = {};
  final List<_TimelineEntry> _timelineEntries = [];
  List<ChatMessage> _displayedMessages = [];
  bool _isLoadingOlder = false;
  bool _hasMoreMessages = true;
  bool _olderLoadArmed = true;
  String _derivedMessagesFingerprint = '';
  InputPanelMode _inputPanelMode = InputPanelMode.none;
  double _inputChromeHeight = 68;
  double _panelBaselineHeight = 0;
  bool _keepPickerDuringKeyboardOpen = false;
  bool _keyboardWasVisible = false;

  static const double _olderLoadTriggerDistance = 24.0;
  static const double _olderLoadRearmDistance = 240.0;

  void _setInputPanelMode(InputPanelMode mode) {
    if (_inputPanelMode == mode) return;
    setState(() {
      _keepPickerDuringKeyboardOpen =
          _inputPanelMode == InputPanelMode.emoji &&
          mode == InputPanelMode.keyboard;
      if (mode == InputPanelMode.none) {
        _keepPickerDuringKeyboardOpen = false;
      }
      _inputPanelMode = mode;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(replyingToProvider(widget.roomId).notifier).value = null;
      ref.read(currentRoomIdProvider.notifier).value = widget.roomId;
      // Keep the global typing listener alive and subscribe to this room.
      ref.read(typingStreamProvider);
      subscribeTypingForRoom(roomId: widget.roomId).catchError((e) {
        debugPrint('subscribeTypingForRoom failed: $e');
      });
    });
  }

  Map<String, String?> _buildAvatarMap(
    List<ChatMessage> messages,
    List<Contact> members,
  ) {
    final map = <String, String?>{};
    for (final m in members) {
      map[m.id] = m.avatarUrl;
    }
    // Also cover senders not in members (edge case)
    for (final msg in messages) {
      if (!msg.isMe && !map.containsKey(msg.senderId)) {
        map[msg.senderId] = null;
      }
    }
    return map;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    final distanceFromOlderEdge = metrics.maxScrollExtent - metrics.pixels;
    if (distanceFromOlderEdge > _olderLoadRearmDistance) {
      _olderLoadArmed = true;
    }

    if (notification is ScrollEndNotification &&
        _olderLoadArmed &&
        !_isLoadingOlder &&
        _hasMoreMessages &&
        _displayedMessages.isNotEmpty &&
        distanceFromOlderEdge <= _olderLoadTriggerDistance) {
      _olderLoadArmed = false;
      _loadOlderMessages();
    }
    return false;
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreMessages || _displayedMessages.isEmpty) {
      return;
    }

    setState(() => _isLoadingOlder = true);
    try {
      final older = await getMessagesBefore(
        roomId: widget.roomId,
        fromEventId: _displayedMessages.first.id,
        limit: 100,
      );
      if (!mounted) return;

      final knownIds = _displayedMessages.map((message) => message.id).toSet();
      final newMessages = older
          .where((message) => !knownIds.contains(message.id))
          .toList();
      setState(() {
        _olderMessages.insertAll(0, newMessages);
        _hasMoreMessages = older.isNotEmpty && newMessages.isNotEmpty;
        _isLoadingOlder = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingOlder = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载更早消息失败: $error')));
    }
  }

  List<ChatMessage> _mergeMessages(List<ChatMessage> latestMessages) {
    final byId = <String, ChatMessage>{
      for (final message in _olderMessages) message.id: message,
      for (final message in latestMessages) message.id: message,
    };
    final messages = byId.values.toList()
      ..sort((a, b) {
        final aTime = int.tryParse(a.timestamp) ?? 0;
        final bTime = int.tryParse(b.timestamp) ?? 0;
        return aTime.compareTo(bTime);
      });
    return messages;
  }

  List<ChatMessage> _mergeLocalOutgoingMessages(
    List<ChatMessage> latestMessages,
    List<LocalOutgoingMessage> localMessages,
  ) {
    if (localMessages.isEmpty) return latestMessages;
    final matchedLocalIds = _matchedLocalOutgoingIds(
      latestMessages,
      localMessages,
    );
    if (matchedLocalIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final id in matchedLocalIds) {
          LocalOutgoingMessage? local;
          for (final message in localMessages) {
            if (message.message.id == id) {
              local = message;
              break;
            }
          }
          rememberResolvedMxcUrl(
            ref,
            local?.sourceImageUrl,
            local?.message.imageUrl,
          );
          removeLocalOutgoingMessage(ref, widget.roomId, id);
        }
      });
    }

    return [
      ...latestMessages,
      ...localMessages
          .where((message) => !matchedLocalIds.contains(message.message.id))
          .map((message) => message.message),
    ];
  }

  Set<String> _matchedLocalOutgoingIds(
    List<ChatMessage> latestMessages,
    List<LocalOutgoingMessage> localMessages,
  ) {
    final ids = <String>{};
    for (final local in localMessages) {
      final localTime = int.tryParse(local.message.timestamp) ?? 0;
      final matched = latestMessages.any((remote) {
        if (!remote.isMe ||
            remote.msgType != MessageType.image ||
            remote.imageUrl == null) {
          return false;
        }
        final remoteTime = int.tryParse(remote.timestamp) ?? 0;
        return remote.imageUrl == local.sourceImageUrl &&
            remote.content == local.message.content &&
            remoteTime >= localTime - 60000;
      });
      if (matched) {
        ids.add(local.message.id);
      }
    }
    return ids;
  }

  List<MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <MessageGroup>[];
    for (final message in messages) {
      final startsNewGroup =
          groups.isEmpty ||
          groups.last.senderId != message.senderId ||
          chatDateKey(groups.last.messages.last.timestamp) !=
              chatDateKey(message.timestamp);
      if (startsNewGroup) {
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: message.isMe,
            messages: [message],
          ),
        );
      } else {
        groups.last.messages.add(message);
      }
    }
    return groups;
  }

  String _messagesFingerprint(List<ChatMessage> latestMessages) {
    final buffer = StringBuffer()
      ..write('older=')
      ..write(_olderMessages.length)
      ..write(';latest=')
      ..write(latestMessages.length);
    for (final message in _olderMessages) {
      buffer
        ..write('|o:')
        ..write(message.id)
        ..write('@')
        ..write(message.timestamp);
    }
    for (final message in latestMessages) {
      buffer
        ..write('|l:')
        ..write(message.id)
        ..write('@')
        ..write(message.timestamp)
        ..write('#')
        ..write(message.isEdited ? 1 : 0)
        ..write('#')
        ..write(message.reactions.length)
        ..write('#')
        ..write(message.readers.length);
    }
    return buffer.toString();
  }

  void _rebuildDerivedMessages(List<ChatMessage> latestMessages) {
    final fingerprint = _messagesFingerprint(latestMessages);
    if (_derivedMessagesFingerprint == fingerprint) {
      return;
    }
    _derivedMessagesFingerprint = fingerprint;
    final displayedMessages = _mergeMessages(latestMessages);
    _displayedMessages = displayedMessages;
    _messageIndex
      ..clear()
      ..addEntries(
        displayedMessages.map((message) => MapEntry(message.id, message)),
      );
    _groupedMessages
      ..clear()
      ..addAll(_groupMessages(displayedMessages));
    _timelineEntries
      ..clear()
      ..addAll(_buildTimelineEntries(_groupedMessages));
  }

  List<_TimelineEntry> _buildTimelineEntries(List<MessageGroup> groups) {
    final entries = <_TimelineEntry>[];
    for (var i = groups.length - 1; i >= 0; i--) {
      final group = groups[i];
      entries.add(_TimelineEntry.group(group));
      if (i == 0 ||
          chatDateKey(groups[i - 1].messages.first.timestamp) !=
              chatDateKey(group.messages.first.timestamp)) {
        entries.add(
          _TimelineEntry.date(formatChatDate(group.messages.first.timestamp)),
        );
      }
    }
    return entries;
  }

  @override
  void deactivate() {
    // Clear current room and stop typing tracking — defer to avoid modifying
    // provider during build.
    Future.microtask(() {
      try {
        ref.read(currentRoomIdProvider.notifier).value = null;
      } catch (e) {
        debugPrint('deactivate: clear currentRoomId failed: $e');
      }
      unsubscribeTyping().catchError((e) {
        debugPrint('unsubscribeTyping failed: $e');
      });
    });
    super.deactivate();
  }

  bool _isEventGroup(MessageGroup group) {
    return group.messages.every((m) => m.msgType == MessageType.event);
  }

  bool _needsStickyAvatar(MessageGroup group) {
    return !widget.isDm && !group.isMe && !_isEventGroup(group);
  }

  Widget _buildTimelineEntry(
    _TimelineEntry entry,
    Map<String, String?> avatarMap,
  ) {
    switch (entry.type) {
      case _TimelineEntryType.group:
        final group = entry.group!;
        return MessageGroupWidget(
          key: ValueKey(
            'group:${group.senderId}:${group.messages.first.id}:${group.messages.last.id}',
          ),
          group: group,
          roomId: widget.roomId,
          messageIndex: _messageIndex,
          showAvatar: _needsStickyAvatar(group),
          compact: widget.isDm,
          senderAvatarUrl: avatarMap[group.senderId],
          scrollController: _scrollController,
          scrollViewportKey: _scrollViewportKey,
          onImageLoaded: null,
        );
      case _TimelineEntryType.date:
        return DateSeparator(
          key: ValueKey('date:${entry.dateLabel}'),
          dateLabel: entry.dateLabel!,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.roomId));
    final membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    final localOutgoingMessages = ref.watch(
      localOutgoingMessagesProvider(widget.roomId),
    );
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardHeight > 0 && keyboardHeight > _panelBaselineHeight) {
      _panelBaselineHeight = keyboardHeight;
    }
    final keyboardVisible = keyboardHeight > 0;
    if (keyboardVisible) {
      _keyboardWasVisible = true;
    } else if (_keyboardWasVisible &&
        _inputPanelMode == InputPanelMode.keyboard &&
        !_keepPickerDuringKeyboardOpen) {
      _keyboardWasVisible = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _inputPanelMode != InputPanelMode.keyboard) return;
        setState(() => _inputPanelMode = InputPanelMode.none);
      });
    }
    final keepsStablePicker =
        _inputPanelMode == InputPanelMode.emoji ||
        _keepPickerDuringKeyboardOpen;
    final pickerFullHeight = _panelBaselineHeight > 0
        ? _panelBaselineHeight
        : ComposerPickerPanel.baseHeight;
    final pickerHeight = keepsStablePicker
        ? math.max(0.0, pickerFullHeight - keyboardHeight)
        : 0.0;
    final bottomOffset =
        (_inputPanelMode == InputPanelMode.keyboard || keepsStablePicker)
        ? keyboardHeight
        : 0.0;
    final panelReservedHeight = keepsStablePicker
        ? pickerFullHeight
        : (_inputPanelMode == InputPanelMode.keyboard ? keyboardHeight : 0.0);
    final messageBottomPadding = _inputChromeHeight + panelReservedHeight;
    final animatePanelChange = !keyboardVisible;

    if (_keepPickerDuringKeyboardOpen &&
        keyboardHeight >= pickerFullHeight - 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_keepPickerDuringKeyboardOpen) return;
        setState(() => _keepPickerDuringKeyboardOpen = false);
      });
    }

    return PopScope(
      canPop: _inputPanelMode == InputPanelMode.none && !keyboardVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _setInputPanelMode(InputPanelMode.none);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background.withValues(alpha: 0.92),
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              AppAvatar(
                fallback: widget.roomName,
                size: 36,
                radius: AppRadii.content,
                url: widget.avatarUrl,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.roomName,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '搜索暂未提供',
              icon: const Icon(
                Icons.search_rounded,
                color: AppColors.onBackground,
              ),
              onPressed: null,
            ),
            IconButton(
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.onBackground,
              ),
              onPressed: () {
                _showRoomDetails(context);
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: messagesAsync.when(
                data: (messages) {
                  final timelineMessages = _mergeLocalOutgoingMessages(
                    messages,
                    localOutgoingMessages,
                  );
                  _rebuildDerivedMessages(timelineMessages);
                  final displayedMessages = _displayedMessages;
                  final avatarMap = membersAsync.maybeWhen(
                    data: (members) =>
                        _buildAvatarMap(displayedMessages, members),
                    orElse: () => const <String, String?>{},
                  );
                  return TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: messageBottomPadding),
                    duration: animatePanelChange
                        ? const Duration(milliseconds: 180)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedBottomPadding, _) {
                      return NotificationListener<ScrollNotification>(
                        onNotification: _handleScrollNotification,
                        child: CustomScrollView(
                          key: _scrollViewportKey,
                          reverse: true,
                          controller: _scrollController,
                          slivers: [
                            SliverPadding(
                              padding: EdgeInsets.only(
                                bottom: 8 + animatedBottomPadding,
                              ),
                            ),
                            SliverList.builder(
                              itemCount: _timelineEntries.length,
                              itemBuilder: (context, index) {
                                return _buildTimelineEntry(
                                  _timelineEntries[index],
                                  avatarMap,
                                );
                              },
                            ),
                            const SliverPadding(
                              padding: EdgeInsets.only(top: 8),
                            ),
                          ],
                        ),
                      );
                    },
                    child: const SizedBox.shrink(),
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      '加载失败: $err',
                      style: const TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedPositioned(
              left: 0,
              right: 0,
              bottom: bottomOffset,
              duration: Duration.zero,
              curve: Curves.easeOutCubic,
              child: _MeasuredSize(
                onChanged: (size) {
                  final chromeHeight = math.max(
                    0.0,
                    size.height - pickerHeight,
                  );
                  if ((_inputChromeHeight - chromeHeight).abs() < 0.5) {
                    return;
                  }
                  setState(() => _inputChromeHeight = chromeHeight);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTypingIndicator(),
                    MessageInput(
                      key: ValueKey('msg_input_${widget.roomId}'),
                      roomId: widget.roomId,
                      panelMode: _inputPanelMode,
                      pickerHeight: pickerHeight,
                      pickerFullHeight: pickerFullHeight,
                      animatePickerHeight: animatePanelChange,
                      onPanelModeChanged: _setInputPanelMode,
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

  /// "… is typing" indicator shown above the message input.
  Widget _buildTypingIndicator() {
    final typing = ref.watch(typingUsersProvider(widget.roomId));
    if (typing.isEmpty) return const SizedBox.shrink();

    // Derive display names from user ids (localpart fallback).
    final names = typing.map((id) {
      final part = id.split(':').first;
      return part.startsWith('@') ? part.substring(1) : part;
    }).toList();

    final String text;
    if (names.length == 1) {
      text = '${names.first} 正在输入…';
    } else if (names.length == 2) {
      text = '${names[0]} 和 ${names[1]} 正在输入…';
    } else {
      text = '${names.length} 人正在输入…';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showRoomDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    AppAvatar(
                      fallback: widget.roomName,
                      size: 56,
                      url: widget.avatarUrl,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.roomName,
                            style: const TextStyle(
                              color: AppColors.onBackground,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.roomId,
                            style: const TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.surfaceVariant, height: 0.5),
              // Room members preview
              Consumer(
                builder: (context, ref, _) {
                  final membersAsync = ref.watch(
                    roomMembersProvider(widget.roomId),
                  );
                  return membersAsync.when(
                    data: (members) {
                      return Column(
                        children: [
                          _DetailMenuItem(
                            icon: Icons.people_rounded,
                            label: '成员 (${members.length})',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: SizedBox(
                              height: 44,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: members.length > 10
                                    ? 10
                                    : members.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final member = members[index];
                                  return AppAvatar(
                                    fallback: member.name,
                                    size: 40,
                                    radius: 20,
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                    error: (_, _) => const SizedBox.shrink(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TimelineEntryType { group, date }

class _TimelineEntry {
  final _TimelineEntryType type;
  final MessageGroup? group;
  final String? dateLabel;

  const _TimelineEntry._({required this.type, this.group, this.dateLabel});

  factory _TimelineEntry.group(MessageGroup group) {
    return _TimelineEntry._(type: _TimelineEntryType.group, group: group);
  }

  factory _TimelineEntry.date(String label) {
    return _TimelineEntry._(type: _TimelineEntryType.date, dateLabel: label);
  }
}

class _DetailMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DetailMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.onSurface, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.onBackground,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MeasuredSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChanged;

  const _MeasuredSize({required this.onChanged, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderMeasuredSize(onChanged);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasuredSize renderObject,
  ) {
    renderObject.onChanged = onChanged;
  }
}

class _RenderMeasuredSize extends RenderProxyBox {
  ValueChanged<Size> onChanged;
  Size? _oldSize;

  _RenderMeasuredSize(this.onChanged);

  @override
  void performLayout() {
    super.performLayout();
    final newSize = child?.size ?? Size.zero;
    if (_oldSize == newSize) return;
    _oldSize = newSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onChanged(newSize);
    });
  }
}
