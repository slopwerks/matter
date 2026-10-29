import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/timeline_event_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_surface.dart';

class TimelineEventSettingsPage extends ConsumerWidget {
  final String? roomId;
  final String? roomName;

  const TimelineEventSettingsPage({super.key, this.roomId, this.roomName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(timelineEventSettingsProvider);
    final notifier = ref.read(timelineEventSettingsProvider.notifier);
    final colors = context.neu;

    final isRoomMode = roomId != null;
    final isOverridden = isRoomMode && state.hasRoomOverride(roomId!);
    final settings = isRoomMode
        ? state.effectiveForRoom(roomId!)
        : state.global;

    final pageTitle = isRoomMode
        ? (roomName != null && roomName!.isNotEmpty
              ? '$roomName 事件显示'
              : '房间事件显示')
        : '时间线事件显示';

    void onSetPreset(TimelineEventPreset preset) {
      if (isRoomMode) {
        notifier.setRoomPreset(roomId!, preset);
      } else {
        notifier.setPreset(preset);
      }
    }

    void onSetMemberAvatar(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowMemberAvatar(roomId!, value);
      } else {
        notifier.setShowMemberAvatar(value);
      }
    }

    void onSetMemberDisplayName(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowMemberDisplayName(roomId!, value);
      } else {
        notifier.setShowMemberDisplayName(value);
      }
    }

    void onSetMemberJoinLeave(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowMemberJoinLeave(roomId!, value);
      } else {
        notifier.setShowMemberJoinLeave(value);
      }
    }

    void onSetMemberInviteBan(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowMemberInviteBan(roomId!, value);
      } else {
        notifier.setShowMemberInviteBan(value);
      }
    }

    void onSetRoomAvatar(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowRoomAvatar(roomId!, value);
      } else {
        notifier.setShowRoomAvatar(value);
      }
    }

    void onSetRoomNameTopic(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowRoomNameTopic(roomId!, value);
      } else {
        notifier.setShowRoomNameTopic(value);
      }
    }

    void onSetRoomSecurity(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowRoomSecurity(roomId!, value);
      } else {
        notifier.setShowRoomSecurity(value);
      }
    }

    void onSetCallEvents(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowCallEvents(roomId!, value);
      } else {
        notifier.setShowCallEvents(value);
      }
    }

    void onSetOtherEvents(bool value) {
      if (isRoomMode) {
        notifier.setRoomShowOtherEvents(roomId!, value);
      } else {
        notifier.setShowOtherEvents(value);
      }
    }

    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: Text(pageTitle)),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.viewPaddingOf(context).top + kToolbarHeight + 8,
          16,
          32,
        ),
        children: [
          if (isRoomMode) ...[
            _Section(
              title: '房间独立配置',
              children: [
                _EventSwitch(
                  icon: Icons.tune_rounded,
                  title: '单独配置此房间',
                  subtitle: isOverridden
                      ? '已启用此房间专属过滤规则，优先于全局设置'
                      : '未启用，当前跟随全局事件显示设置',
                  value: isOverridden,
                  onChanged: (val) {
                    if (val) {
                      notifier.enableRoomOverride(roomId!);
                    } else {
                      notifier.clearRoomOverride(roomId!);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (!isOverridden) ...[
              GlassPanel(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '当前房间正在跟随全局设置。开启上方的「单独配置此房间」后，可为此群单独定制状态事件过滤规则（如在大群中隐藏进退与改名，或在工作群中全开）。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.textSecondary,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],
          if (!isRoomMode || isOverridden) ...[
            _Section(
              title: '懒人预设',
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _PresetCard(
                              title: '推荐模式',
                              subtitle: '显示主要状态',
                              icon: Icons.recommend_rounded,
                              isSelected:
                                  settings.preset ==
                                  TimelineEventPreset.recommended,
                              onTap: () =>
                                  onSetPreset(TimelineEventPreset.recommended),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _PresetCard(
                              title: '全部显示',
                              subtitle: '展示全部事件',
                              icon: Icons.visibility_rounded,
                              isSelected:
                                  settings.preset == TimelineEventPreset.all,
                              onTap: () => onSetPreset(TimelineEventPreset.all),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: _PresetCard(
                              title: '极简模式',
                              subtitle: '隐藏进退与资料',
                              icon: Icons.filter_list_rounded,
                              isSelected:
                                  settings.preset ==
                                  TimelineEventPreset.minimal,
                              onTap: () =>
                                  onSetPreset(TimelineEventPreset.minimal),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _PresetCard(
                              title: '全部隐藏',
                              subtitle: '仅显示聊天消息',
                              icon: Icons.visibility_off_rounded,
                              isSelected:
                                  settings.preset == TimelineEventPreset.off,
                              onTap: () => onSetPreset(TimelineEventPreset.off),
                            ),
                          ),
                        ],
                      ),
                      if (settings.preset == TimelineEventPreset.custom) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: colors.accent.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(NeuRadius.tag),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.tune_rounded,
                                size: 13,
                                color: colors.accent,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '当前为自定义模式',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.accent,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '成员个人资料',
              children: [
                _EventSwitch(
                  icon: Icons.account_circle_outlined,
                  title: '成员个人头像变更',
                  subtitle: '成员设置、更换或移除个人头像',
                  value: settings.showMemberAvatar,
                  onChanged: onSetMemberAvatar,
                ),
                _EventSwitch(
                  icon: Icons.badge_outlined,
                  title: '成员昵称变更',
                  subtitle: '成员修改或清除群内显示名称',
                  value: settings.showMemberDisplayName,
                  onChanged: onSetMemberDisplayName,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '成员进出与关系',
              children: [
                _EventSwitch(
                  icon: Icons.person_add_rounded,
                  title: '成员加入与离开',
                  subtitle: '成员主动加入、退出房间或提交敲门申请',
                  value: settings.showMemberJoinLeave,
                  onChanged: onSetMemberJoinLeave,
                ),
                _EventSwitch(
                  icon: Icons.person_remove_rounded,
                  title: '成员邀请、移出与封禁',
                  subtitle: '收到群邀请、被管理员移出、封禁或解除封禁',
                  value: settings.showMemberInviteBan,
                  onChanged: onSetMemberInviteBan,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '房间信息与外观',
              children: [
                _EventSwitch(
                  icon: Icons.photo_size_select_actual_outlined,
                  title: '房间头像变更',
                  subtitle: '设置、更换或移除群头像',
                  value: settings.showRoomAvatar,
                  onChanged: onSetRoomAvatar,
                ),
                _EventSwitch(
                  icon: Icons.edit_note_rounded,
                  title: '房间名称、主题与别名',
                  subtitle: '修改群名称、公告主题、主要别名与置顶消息',
                  value: settings.showRoomNameTopic,
                  onChanged: onSetRoomNameTopic,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '房间规则与安全',
              children: [
                _EventSwitch(
                  icon: Icons.security_rounded,
                  title: '加密规则与权限级别',
                  subtitle: '启用端到端加密、创建房间、加入规则与权限变更',
                  value: settings.showRoomSecurity,
                  onChanged: onSetRoomSecurity,
                ),
              ],
            ),
            const SizedBox(height: 16),
            _Section(
              title: '通话与系统状态',
              children: [
                _EventSwitch(
                  icon: Icons.call_outlined,
                  title: '通话邀请事件',
                  subtitle: '发起音视频通话邀请与通话状态变更',
                  value: settings.showCallEvents,
                  onChanged: onSetCallEvents,
                ),
                _EventSwitch(
                  icon: Icons.info_outline_rounded,
                  title: '其他系统状态事件',
                  subtitle: '历史记录可见性、房间升级替换、第三方邀请等',
                  value: settings.showOtherEvents,
                  onChanged: onSetOtherEvents,
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          GlassPanel(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 16,
                  color: colors.textTertiary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isRoomMode
                        ? '关闭某些事件的显示仅影响当前设备在此房间的消息时间线展示，不会影响 Matrix 协议消息同步或房间实际状态。'
                        : '关闭某些事件的显示仅影响当前设备的聊天时间线展示，不会影响 Matrix 协议消息同步或房间实际状态。随时可以在这里重新开启。',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.textSecondary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final primaryColor = colors.accent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(NeuRadius.button),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? primaryColor.withValues(alpha: 0.12)
                : colors.card.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(NeuRadius.button),
            border: Border.all(
              color: isSelected
                  ? primaryColor.withValues(alpha: 0.8)
                  : colors.hairline,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    icon,
                    size: 18,
                    color: isSelected ? primaryColor : colors.textSecondary,
                  ),
                  const Spacer(),
                  if (isSelected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: primaryColor,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: isSelected ? primaryColor : colors.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: isSelected
                      ? primaryColor.withValues(alpha: 0.85)
                      : colors.textTertiary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
              color: colors.textSecondary,
            ),
          ),
        ),
        NeuSurface(
          color: colors.card,
          radius: NeuRadius.surface,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: colors.hairline,
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _EventSwitch extends StatelessWidget {
  const _EventSwitch({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: (value ? colors.accent : colors.textTertiary).withValues(
                alpha: 0.1,
              ),
              borderRadius: BorderRadius.circular(NeuRadius.tag),
            ),
            child: Icon(
              icon,
              size: 18,
              color: value ? colors.accent : colors.textTertiary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: colors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
