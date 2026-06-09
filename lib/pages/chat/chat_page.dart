import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/cascade_title.dart';
import 'chat_list_item.dart';
import 'create_chat_page.dart';
import 'search_bar.dart';
import 'space_switcher.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  @override
  void initState() {
    super.initState();
    // Ensure rooms are fetched
    Future.microtask(() {
      if (mounted) ref.invalidate(chatRoomsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final roomsAsync = ref.watch(chatRoomsProvider);
    final connectionLabel = ref.watch(connectionLabelProvider);

    final titleText = connectionLabel.isNotEmpty ? connectionLabel : 'Matter';

    return Scaffold(
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
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: AppColors.onBackground,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            backgroundColor: AppColors.background.withValues(alpha: 0.85),
          ),
          const SliverToBoxAdapter(
            child: ChatSearchBar(),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: 8),
          ),
          const SliverToBoxAdapter(
            child: SpaceSwitcher(),
          ),
          const SliverToBoxAdapter(
            child: SizedBox(height: 8),
          ),
          roomsAsync.when(
            data: (rooms) {
              return SliverList.separated(
                itemCount: rooms.length,
                separatorBuilder: (context, index) => const Divider(
                  color: Color(0xFF1E242C),
                  thickness: 0.5,
                  height: 0.5,
                ),
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  return ChatListItem(room: room);
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
                  child: Text(
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
          // FAB positioned above bottom nav bar
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CreateChatPage()),
                );
              },
              backgroundColor: AppColors.primary,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.edit_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
