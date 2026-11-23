part of 'settings_page.dart';

extension _SettingsSections on _SettingsPageState {
  List<({String title, List<_SettingItem> items, _SettingsCategory category})>
  _sections(CurrentUser? currentUser, String? activeUserId) {
    final colors = context.neu;
    return <
      ({String title, List<_SettingItem> items, _SettingsCategory category})
    >[
      // ── Account switcher ────────────────────────────────
      if (_accountsLoadError != null) ...[
        (
          category: _SettingsCategory.account,
          title: '账号',
          items: [
            _SettingItem(
              icon: Icons.error_outline_rounded,
              iconColor: colors.error,
              title: '账号列表加载失败',
              subtitle: '$_accountsLoadError',
              onTap: _loadAccounts,
            ),
          ],
        ),
      ],
      // Saved accounts stay reachable even when no session is
      // active (e.g. one was just cleared): the list is read from
      // disk, and hiding it would remove the only route back into
      // an account or into adding a new one.
      if (_accounts.isNotEmpty) ...[
        (
          category: _SettingsCategory.account,
          title: '账号切换',
          items: [
            ..._accounts.map((account) {
              final isActive = account.userId == activeUserId;
              return _SettingItem(
                icon: Icons.person_outline_rounded,
                iconColor: isActive ? colors.accent : null,
                title: _formatUserId(account.userId),
                subtitle: account.homeserverUrl.replaceAll(
                  RegExp(r'https?://'),
                  '',
                ),
                trailing: isActive
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: colors.accent,
                        size: 20,
                      )
                    : _switchingAccountId == account.userId
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                // Removal internally switches accounts (see
                // `_removeAccount`); during that window a switch
                // tile must stay disabled like the remove buttons,
                // or a queued tap can target the account being
                // deleted.
                onTap:
                    (isActive ||
                        _addingAccount ||
                        _switchingAccountId != null ||
                        _removingAccountId != null)
                    ? null
                    : () => _switchAccount(account.userId),
              );
            }),
            _SettingItem(
              icon: Icons.person_add_alt_1_rounded,
              title: '添加账号',
              subtitle: '保留当前账号登录，添加后切换使用',
              onTap:
                  _addingAccount ||
                      _switchingAccountId != null ||
                      _removingAccountId != null
                  ? null
                  : _addAccount,
            ),
          ],
        ),
      ],

      // Settings groups
      (
        category: _SettingsCategory.general,
        title: '通用',
        items: [
          _SettingItem(
            icon: Icons.dark_mode_rounded,
            category: _SettingsCategory.appearance,
            title: '主题',
            subtitle: _themeStyleLabel(ref.watch(appThemeStyleProvider)),
            // 弹出选择器,不跳页。
            selects: true,
            onTap: _showThemeStylePicker,
          ),
          if (context.isMaterial)
            _SettingItem(
              icon: Icons.palette_outlined,
              category: _SettingsCategory.appearance,
              title: 'Material 配色',
              subtitle: '系统取色 · 主题色 · 浅色与深色背景',
              onTap: () => MaterialListDetail.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const MaterialColorSettingsPage(),
                ),
              ),
            ),
          _SettingItem(
            icon: Icons.notifications_rounded,
            category: _SettingsCategory.notifications,
            title: '通知',
            subtitle: 'FCM 推送 · 自定义网关 · 房间免打扰',
            onTap: currentUser == null
                ? null
                : () => MaterialListDetail.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          NotificationSettingsPage(userId: currentUser.id),
                    ),
                  ),
          ),
          _SettingItem(
            icon: Icons.home_outlined,
            title: '启动页面',
            subtitle: ref.watch(startupPageProvider).label,
            onTap: () => MaterialListDetail.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const StartupPageSettingsPage(),
              ),
            ),
          ),
          _SettingItem(
            icon: Icons.touch_app_rounded,
            title: '交互模式',
            subtitle: ref.watch(interactionModeProvider).label,
            onTap: () => MaterialListDetail.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const InteractionModeSettingsPage(),
              ),
            ),
          ),
          _SettingItem(
            icon: Icons.keyboard_rounded,
            title: '键盘发送与换行',
            subtitle: 'Enter · Shift+Enter · Alt+Enter',
            onTap: () => MaterialListDetail.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const ComposerKeyboardSettingsPage(),
              ),
            ),
          ),
          _SettingItem(
            icon: Icons.language_rounded,
            title: '语言',
            subtitle: '当前固定为简体中文',
          ),
        ],
      ),

      (
        category: _SettingsCategory.appearance,
        title: context.isMaterial ? '聊天外观' : '性能設置',
        items: [
          _SettingItem(
            icon: Icons.tune_rounded,
            title: '时间线事件显示',
            subtitle: '配置头像更改、成员进退与房间状态事件显示',
            onTap: () => MaterialListDetail.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const TimelineEventSettingsPage(),
              ),
            ),
          ),
          if (!context.isMaterial) ...[
            _SettingItem(
              icon: Icons.blur_on_rounded,
              title: '模糊效果设置',
              subtitle: '配置渐进式模糊、图片背景与阴影优化',
              onTap: () => MaterialListDetail.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => const BlurSettingsPage(),
                ),
              ),
            ),
            _buildChatVisualSwitch(
              icon: Icons.shield_moon_rounded,
              title: '消息气泡阴影',
              subtitle: '启用新拟物消息气泡的阴影',
              value: ref.watch(chatVisualSettingsProvider).bubbleShadowsEnabled,
              onChanged: (value) => ref
                  .read(chatVisualSettingsProvider.notifier)
                  .setBubbleShadowsEnabled(value),
            ),
            _buildChatVisualSwitch(
              icon: Icons.rounded_corner,
              title: '超椭圆边框',
              subtitle: '全域使用超椭圆边框',
              value: ref
                  .watch(chatVisualSettingsProvider)
                  .superellipseBorderEnabled,
              onChanged: (value) => ref
                  .read(chatVisualSettingsProvider.notifier)
                  .setSuperellipseBorderEnabled(value),
            ),
            _buildChatVisualSwitch(
              icon: Icons.gradient_rounded,
              title: '气泡渐变',
              subtitle: '启用消息气泡的渐变填充',
              value: ref
                  .watch(chatVisualSettingsProvider)
                  .bubbleGradientEnabled,
              onChanged: (value) => ref
                  .read(chatVisualSettingsProvider.notifier)
                  .setBubbleGradientEnabled(value),
            ),
            _buildChatVisualSwitch(
              icon: Icons.blur_on_rounded,
              title: '短图片模糊背景',
              subtitle: '为较矮的图片气泡显示模糊背景',
              value: ref
                  .watch(chatVisualSettingsProvider)
                  .shortImageBlurredBackdropEnabled,
              onChanged: (value) => ref
                  .read(chatVisualSettingsProvider.notifier)
                  .setShortImageBlurredBackdropEnabled(value),
            ),
          ],
          _SettingItem(
            icon: Icons.code_rounded,
            title: '代码块显示设置',
            subtitle: '高亮主题 · 背景透明度 · 实时预览',
            onTap: () => MaterialListDetail.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => const CodeBlockSettingsPage(),
              ),
            ),
          ),
          _buildChatVisualSwitch(
            icon: Icons.account_circle_rounded,
            title: '消息头像吸附',
            subtitle: '在消息分组旁显示吸附头像',
            value: ref.watch(chatVisualSettingsProvider).stickyAvatarsEnabled,
            onChanged: (value) => ref
                .read(chatVisualSettingsProvider.notifier)
                .setStickyAvatarsEnabled(value),
          ),
        ],
      ),

      (
        category: _SettingsCategory.devices,
        title: 'Matrix',
        items: [
          _SettingItem(
            icon: Icons.account_tree_rounded,
            title: 'Homeserver',
            subtitle:
                currentUser?.homeserver.replaceAll(RegExp(r'https?://'), '') ??
                'matrix.org',
          ),
          _SettingItem(
            icon: Icons.sync_rounded,
            title: '同步设置',
            subtitle: '自动管理，无手动配置项',
          ),
          _SettingItem(
            icon: Icons.devices_rounded,
            title: '设备与加密',
            subtitle: '登录设备、验证与加密恢复',
            onTap: () {
              MaterialListDetail.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const EncryptionPage()),
              );
            },
          ),
        ],
      ),
      // On web there is no app-managed disk cache to clear; the
      // browser owns the HTTP cache.
      if (!kIsWeb) ...[
        (
          category: _SettingsCategory.storage,
          title: '存储',
          items: [
            if (_credentialCompatibilityMode)
              _SettingItem(
                icon: Icons.warning_amber_rounded,
                iconColor: colors.warning,
                title: '凭据兼容模式',
                subtitle: '已启用 · Root 权限可读取登录凭据',
                trailing: _updatingCredentialCompatibilityMode
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
                onTap: _updatingCredentialCompatibilityMode
                    ? null
                    : _disableCredentialCompatibilityMode,
              ),
            _SettingItem(
              icon: Icons.storage_rounded,
              title: '存储与数据',
              subtitle: '空间用量、分类清理、自动下载与保留策略',
              onTap: () => MaterialListDetail.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const StoragePage()),
              ),
            ),
          ],
        ),
      ],

      (
        category: _SettingsCategory.about,
        title: '关于',
        items: [
          _SettingItem(
            icon: Icons.info_rounded,
            title: '当前版本',
            subtitle: _versionLabel,
            onTap: appUpdateService.isSupported && !_checkingForUpdate
                ? _checkForUpdate
                : null,
            trailing: _checkingForUpdate
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          _SettingItem(
            icon: Icons.code_rounded,
            title: '开源许可',
            subtitle: '',
            onTap: () {
              showLicensePage(context: context);
            },
          ),
          _SettingItem(
            icon: Icons.terminal_rounded,
            title: '查看日志',
            subtitle: '调试连接、同步问题',
            onTap: () {
              MaterialListDetail.push(
                context,
                MaterialPageRoute(builder: (_) => const LogViewerPage()),
              );
            },
          ),
          _SettingItem(
            icon: Icons.folder_zip_outlined,
            title: '导出日志',
            subtitle: '完整日志 zip，含设备信息，已脱敏',
            trailing: _exportingLogs
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: _exportingLogs ? null : _exportLogs,
          ),
        ],
      ),
    ];
  }
}
