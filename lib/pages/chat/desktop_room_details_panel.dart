import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_surface.dart';
import 'room_metadata_patch.dart';
import 'room_management_page.dart';

class DesktopRoomDetailsPanel extends ConsumerWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final VoidCallback? onRoomLeft;
  final ValueChanged<RoomMetadataPatch>? onRoomDetailsChanged;

  const DesktopRoomDetailsPanel({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.onRoomLeft,
    this.onRoomDetailsChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.neu;
    final membersAsync = ref.watch(roomMembersProvider(roomId));

    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 12, 16),
            child: Row(
              children: [
                AppAvatar(
                  fallback: roomName,
                  size: 40,
                  radius: NeuRadius.content,
                  url: avatarUrl,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    roomName,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                NeuIconButton(
                  icon: Icons.settings_rounded,
                  size: 38,
                  tooltip: '房间管理',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => RoomManagementPage(
                        roomId: roomId,
                        roomName: roomName,
                        avatarUrl: avatarUrl,
                        onRoomClosed: onRoomLeft,
                        onRoomDetailsChanged: onRoomDetailsChanged,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(color: colors.hairline, height: 1),
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
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2,
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
                      radius: NeuRadius.content,
                      url: member.avatarUrl,
                    ),
                    title: Text(
                      member.name,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      member.id,
                      style: Theme.of(context).textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
              loading: () => Center(
                child: CircularProgressIndicator(
                  color: colors.accent,
                  strokeWidth: 2,
                ),
              ),
              error: (_, _) => Center(
                child: Text(
                  '无法加载成员',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
