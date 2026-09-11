import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import 'search_page.dart';

class ChatSearchBar extends StatelessWidget {
  const ChatSearchBar({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Material(
        color: colors.card,
        borderRadius: BorderRadius.circular(NeuRadius.surface),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey('open-chat-search'),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => const ChatSearchPage())),
          child: SizedBox(
            height: 44,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  Icons.search_rounded,
                  color: colors.textTertiary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '搜索消息或聊天',
                    style: TextStyle(color: colors.textTertiary, fontSize: 15),
                  ),
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
