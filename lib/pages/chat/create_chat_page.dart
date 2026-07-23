import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/max_content_width.dart';

class CreateChatPage extends ConsumerStatefulWidget {
  const CreateChatPage({super.key});

  @override
  ConsumerState<CreateChatPage> createState() => _CreateChatPageState();
}

class _CreateChatPageState extends ConsumerState<CreateChatPage> {
  final _searchController = TextEditingController();
  bool _isCreating = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createDm(String userId) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    try {
      await rust.createDm(userId: userId);
      ref.invalidate(chatRoomsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('私聊已创建'),
            duration: Duration(seconds: 1),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e'), duration: Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  Future<void> _createGroup(String name) async {
    if (_isCreating) return;
    setState(() => _isCreating = true);
    try {
      await rust.createGroupRoom(name: name, topic: null);
      ref.invalidate(chatRoomsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('群组已创建'),
            duration: Duration(seconds: 1),
          ),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败: $e'), duration: Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _isCreating = false);
    }
  }

  void _showJoinRoomDialog() {
    final roomIdController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        title: const Text(
          '加入房间',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: TextField(
          controller: roomIdController,
          style: const TextStyle(color: AppColors.onBackground),
          decoration: const InputDecoration(
            hintText: '!room_id:matrix.akass.cn',
            hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.surfaceVariant),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () async {
              final value = roomIdController.text.trim();
              if (value.isEmpty) return;
              try {
                await rust.joinRoom(identifier: value);
                ref.invalidate(chatRoomsProvider);
                ref.invalidate(ungroupedRoomsProvider);
                if (!mounted || !ctx.mounted) return;
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已加入房间'),
                    duration: Duration(seconds: 1),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('加入失败: $e'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('加入', style: TextStyle(color: AppColors.primary)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: AppColors.onBackground,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '新建聊天',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: MaxContentWidth(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              // Search / user ID input
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadii.surface),
                ),
                child: TextField(
                  controller: _searchController,
                  style: const TextStyle(
                    color: AppColors.onBackground,
                    fontSize: 15,
                  ),
                  decoration: const InputDecoration(
                    hintText: '输入 @用户 ID 发起私聊',
                    hintStyle: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 15,
                    ),
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: AppColors.onSurfaceVariant,
                      size: 20,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.go,
                  onSubmitted: (value) {
                    final trimmed = value.trim();
                    if (trimmed.isNotEmpty) _createDm(trimmed);
                  },
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () {
                    final trimmed = _searchController.text.trim();
                    if (trimmed.isNotEmpty) _createDm(trimmed);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.surface),
                    ),
                  ),
                  child: _isCreating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          '发起私聊',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 32),
              // Action cards
              _ActionCard(
                icon: Icons.group_add_rounded,
                iconColor: AppColors.primary,
                title: '创建群组',
                subtitle: '创建一个新的群聊房间',
                onTap: () {
                  final nameController = TextEditingController();
                  showDialog(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      backgroundColor: AppColors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                      ),
                      title: const Text(
                        '创建群组',
                        style: TextStyle(color: AppColors.onBackground),
                      ),
                      content: TextField(
                        controller: nameController,
                        style: const TextStyle(color: AppColors.onBackground),
                        decoration: const InputDecoration(
                          hintText: '群组名称',
                          hintStyle: TextStyle(
                            color: AppColors.onSurfaceVariant,
                          ),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(
                              color: AppColors.surfaceVariant,
                            ),
                          ),
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text(
                            '取消',
                            style: TextStyle(color: AppColors.onSurfaceVariant),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            final name = nameController.text.trim();
                            if (name.isNotEmpty) _createGroup(name);
                          },
                          child: const Text(
                            '创建',
                            style: TextStyle(color: AppColors.primary),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 8),
              _ActionCard(
                icon: Icons.meeting_room_rounded,
                iconColor: AppColors.warning,
                title: '加入房间',
                subtitle: '通过房间 ID 加入已有房间',
                onTap: _showJoinRoomDialog,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.surface),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadii.content),
                ),
                child: Icon(icon, color: iconColor, size: 20),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: AppColors.onSurfaceVariant,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
