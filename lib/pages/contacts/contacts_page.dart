import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
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
      body: CustomScrollView(
        slivers: [
          const SliverAppBar(
            floating: true,
            pinned: true,
            title: Text(
              '通讯录',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.onBackground,
                letterSpacing: -0.5,
              ),
            ),
            backgroundColor: AppColors.background,
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                ),
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    const Icon(
                      Icons.search_rounded,
                      color: AppColors.onSurfaceVariant,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 15,
                        ),
                        decoration: const InputDecoration(
                          hintText: '搜索联系人',
                          hintStyle: TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 15,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                        onChanged: (value) {
                          setState(() => _searchQuery = value.toLowerCase());
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
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
                              c.name.toLowerCase().contains(_searchQuery) ||
                              c.status.toLowerCase().contains(_searchQuery),
                        )
                        .toList();

              if (filtered.isEmpty) {
                return const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(
                            Icons.contacts_rounded,
                            color: AppColors.onSurfaceVariant,
                            size: 48,
                          ),
                          SizedBox(height: 12),
                          Text(
                            '暂无联系人',
                            style: TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 15,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            '加入房间后，成员会显示在这里',
                            style: TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }

              return SliverList.separated(
                itemCount: filtered.length,
                separatorBuilder: (context, index) => const Divider(
                  color: AppColors.surfaceVariant,
                  thickness: 0.5,
                  indent: 82,
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final contact = filtered[index];
                  return _ContactTile(contact: contact);
                },
              );
            },
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
              ),
            ),
            error: (err, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: SelectableText(
                    '加载失败: $err',
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
        ],
      ),
    );
  }
}

class _ContactTile extends ConsumerStatefulWidget {
  final Contact contact;

  const _ContactTile({required this.contact});

  @override
  ConsumerState<_ContactTile> createState() => _ContactTileState();
}

class _ContactTileState extends ConsumerState<_ContactTile> {
  String? _resolvedAvatarUrl;

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

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          AppAvatar(
            fallback: contact.name,
            size: 48,
            radius: AppRadii.content,
            url: _resolvedAvatarUrl,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.name,
                  style: const TextStyle(
                    color: AppColors.onBackground,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  contact.status,
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.message_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            onPressed: () async {
              // Create DM with this contact
              try {
                final roomId = await createDm(userId: contact.id);
                if (context.mounted) {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatDetailPage(
                        roomId: roomId,
                        roomName: contact.name,
                        avatarUrl: _resolvedAvatarUrl,
                      ),
                    ),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('创建会话失败: $e'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}
