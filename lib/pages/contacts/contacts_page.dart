import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import '../chat/action_failure_message.dart';
import '../chat/chat_detail_page.dart';

class ContactsPage extends ConsumerStatefulWidget {
  const ContactsPage({super.key});

  @override
  ConsumerState<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends ConsumerState<ContactsPage> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final contactsAsync = ref.watch(contactsProvider);

    return Scaffold(
      backgroundColor: context.neu.base,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            pinned: true,
            title: Text('通讯录', style: Theme.of(context).textTheme.titleLarge),
            backgroundColor: context.neu.base,
            scrolledUnderElevation: 0,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.lg,
                NeuSpacing.xs,
                NeuSpacing.lg,
                NeuSpacing.sm,
              ),
              child: NeuTextField(
                hint: '搜索联系人',
                leading: const Icon(Icons.search_rounded),
                onChanged: (value) {
                  setState(() => _searchQuery = value.toLowerCase());
                },
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
                              c.name.toLowerCase().contains(_searchQuery) ||
                              c.status.toLowerCase().contains(_searchQuery),
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
                padding: const EdgeInsets.symmetric(horizontal: NeuSpacing.lg),
                sliver: SliverList.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: NeuSpacing.md),
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
          const SliverPadding(
            padding: EdgeInsets.only(bottom: NeuSpacing.navClearance),
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
      radius: NeuRadius.content,
      onTap: _showProfile,
      child: NeuSurface(
        radius: NeuRadius.content,
        color: context.neu.card,
        padding: const EdgeInsets.symmetric(
          horizontal: NeuSpacing.lg,
          vertical: NeuSpacing.md,
        ),
        child: Row(
          children: [
            AppAvatar(
              fallback: contact.name,
              size: 48,
              radius: NeuRadius.content,
              url: _resolvedAvatarUrl,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    contact.status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: NeuSpacing.sm),
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
