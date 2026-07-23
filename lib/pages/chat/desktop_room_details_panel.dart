import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';

class DesktopRoomDetailsPanel extends ConsumerWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;

  const DesktopRoomDetailsPanel({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membersAsync = ref.watch(roomMembersProvider(roomId));

    return ColoredBox(
      color: AppColors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Row(
              children: [
                AppAvatar(
                  fallback: roomName,
                  size: 40,
                  radius: AppRadii.content,
                  url: avatarUrl,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    roomName,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: AppColors.surfaceVariant, height: 1),
          Expanded(
            child: membersAsync.when(
              data: (members) => ListView.builder(
                padding: const EdgeInsets.only(top: 8, bottom: 16),
                itemCount: members.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: Text(
                        '成员 ${members.length}',
                        style: const TextStyle(
                          color: AppColors.onSurface,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    );
                  }
                  final member = members[index - 1];
                  return ListTile(
                    dense: true,
                    leading: AppAvatar(
                      fallback: member.name,
                      size: 36,
                      radius: 18,
                      url: member.avatarUrl,
                    ),
                    title: Text(
                      member.name,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      member.id,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
              loading: () => const Center(
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
              ),
              error: (_, _) => const Center(
                child: Text(
                  '无法加载成员',
                  style: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
