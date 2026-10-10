import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/push/fcm_push_runtime.dart';
import '../../features/push/firebase_client_config.dart';
import '../../features/push/notification_preferences.dart';
import '../../features/push/push_providers.dart';
import '../../features/push/push_runtime.dart';
import '../../features/push/push_settings.dart';
import '../../src/rust/api/matrix/notifications.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

class NotificationSettingsPage extends ConsumerStatefulWidget {
  const NotificationSettingsPage({super.key, required this.userId});
  final String userId;

  @override
  ConsumerState<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState
    extends ConsumerState<NotificationSettingsPage>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _gateway = TextEditingController();
  final _appId = TextEditingController();
  final _vapid = TextEditingController();
  bool _loaded = false;
  bool _enabled = false;
  bool _busy = false;
  final _savingRules = <NotificationRule>{};
  final _savingKeywords = <String>{};
  final _ruleOverrides = <NotificationRule, bool>{};
  final _keywordOverrides = <String, bool>{};
  int _preferenceRevision = 0;
  PushBackend _backend = PushBackend.android;
  String? _pushError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPreferences();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _gateway.dispose();
    _appId.dispose();
    _vapid.dispose();
    super.dispose();
  }

  Future<void> _refreshPreferences() async {
    final revision = _preferenceRevision;
    try {
      ref.invalidate(notificationPreferencesProvider(widget.userId));
      await ref.read(notificationPreferencesProvider(widget.userId).future);
      // Keep edits made while this server read was in flight.
      if (mounted && revision == _preferenceRevision) {
        setState(() {
          _ruleOverrides.removeWhere((rule, _) => !_savingRules.contains(rule));
          _keywordOverrides.removeWhere(
            (keyword, _) => !_savingKeywords.contains(keyword),
          );
        });
      }
    } catch (error) {
      if (mounted &&
          ref.read(notificationPreferencesProvider(widget.userId)).hasValue) {
        _showPreferenceError('刷新通知偏好失败：$error');
      }
    }
  }

  void _showPreferenceError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _saveRule(
    NotificationRule rule,
    bool enabled,
    bool previous,
    String title,
  ) async {
    if (_savingRules.contains(rule)) return;
    final api = ref.read(notificationPreferencesApiProvider);
    setState(() {
      _savingRules.add(rule);
      _ruleOverrides[rule] = enabled;
      _preferenceRevision++;
    });
    try {
      await api.setRule(widget.userId, rule, enabled);
    } catch (error) {
      if (!mounted) return;
      var confirmed = previous;
      var message = '“$title”保存失败：$error';
      try {
        // A partially applied write is checked without replacing other edits.
        final preferences = await api.load(widget.userId);
        confirmed =
            preferences.rules
                .where((setting) => setting.rule == rule)
                .firstOrNull
                ?.enabled ??
            previous;
      } catch (_) {
        message += '。请刷新确认服务器状态。';
      }
      if (!mounted) return;
      setState(() => _ruleOverrides[rule] = confirmed);
      _showPreferenceError(message);
    } finally {
      if (mounted) {
        setState(() {
          _savingRules.remove(rule);
          _preferenceRevision++;
        });
      }
    }
  }

  Future<void> _saveKeyword(String keyword, bool enabled, bool previous) async {
    if (_savingKeywords.contains(keyword)) return;
    final api = ref.read(notificationPreferencesApiProvider);
    setState(() {
      _savingKeywords.add(keyword);
      _keywordOverrides[keyword] = enabled;
      _preferenceRevision++;
    });
    try {
      await api.setKeyword(widget.userId, keyword, enabled);
    } catch (error) {
      if (!mounted) return;
      var confirmed = previous;
      var message = '关键词“$keyword”保存失败：$error';
      try {
        confirmed = (await api.load(widget.userId)).keywords.contains(keyword);
      } catch (_) {
        message += '。请刷新确认服务器状态。';
      }
      if (!mounted) return;
      setState(() => _keywordOverrides[keyword] = confirmed);
      _showPreferenceError(message);
    } finally {
      if (mounted) {
        setState(() {
          _savingKeywords.remove(keyword);
          _preferenceRevision++;
        });
      }
    }
  }

  Future<void> _addKeyword() async {
    var draft = '';
    final keyword = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加关键词'),
        content: TextField(
          onChanged: (text) => draft = text,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(
            labelText: '关键词',
            hintText: '例如项目名称',
          ),
          onSubmitted: (text) {
            if (text.trim().isNotEmpty) {
              Navigator.pop(context, text.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (draft.trim().isNotEmpty) {
                Navigator.pop(context, draft.trim());
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (keyword == null || !mounted) return;
    final previous =
        _keywordOverrides[keyword] ??
        ref
            .read(notificationPreferencesProvider(widget.userId))
            .value
            ?.keywords
            .contains(keyword) ??
        false;
    await _saveKeyword(keyword, true, previous);
  }

  Future<void> _importFirebase() async {
    setState(() {
      _busy = true;
      _pushError = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'google-services.json',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final config = FirebaseClientConfig.fromGoogleServices(
        await file.readAsString(),
      );
      if (!mounted) return;
      final previous = ref.read(firebaseClientConfigProvider).asData?.value;
      if (previous != null && previous.matches(config)) return;
      final manager = ref.read(pushRegistrationManagerProvider);
      final current = await manager.store.load(widget.userId);
      if (!mounted) return;
      await manager.configure(
        widget.userId,
        enabled: false,
        gatewayUrl: _gateway.text.isNotEmpty
            ? _gateway.text
            : current.gatewayUrl,
        appId: _appId.text.isNotEmpty ? _appId.text : current.appId,
        backend: _backend,
        vapidPublicKey: _vapid.text.isNotEmpty
            ? _vapid.text
            : current.vapidPublicKey,
      );
      await manager.changeFcmConfiguration(() async {
        await fcmPushRuntime.retireToken();
        await FirebaseClientConfigStore().save(config);
        fcmPushRuntime.configurationChanged = true;
      });
      if (mounted) {
        ref.invalidate(firebaseClientConfigProvider);
        setState(() => _enabled = false);
      }
    } catch (error) {
      if (mounted) setState(() => _pushError = '$error');
    } finally {
      if (mounted) {
        ref.invalidate(pushSettingsProvider(widget.userId));
        final settings = await PushSettingsStore().load(widget.userId);
        if (mounted) {
          setState(() {
            _enabled = settings.enabled;
            _busy = false;
          });
        }
      }
    }
  }

  Future<void> _savePush(bool enabled) async {
    if (enabled) {
      final error =
          validatePushGateway(_gateway.text) ??
          validatePushAppId(_appId.text) ??
          (_backend == PushBackend.web
              ? validateVapidPublicKey(_vapid.text)
              : null);
      if (error != null) {
        _form.currentState!.validate();
        setState(() => _pushError = error);
        return;
      }
    }
    final manager = ref.read(pushRegistrationManagerProvider);
    setState(() {
      _busy = true;
      _pushError = null;
    });
    try {
      if (enabled) await requestPushPermission(_backend);
      await manager.configure(
        widget.userId,
        enabled: enabled,
        gatewayUrl: _gateway.text,
        appId: _appId.text,
        backend: _backend,
        vapidPublicKey: _vapid.text,
      );
      if (mounted) {
        ref
            .read(pushRegistrationErrorProvider.notifier)
            .setError(widget.userId, null);
        neuToast(context, enabled ? '推送已注册' : '推送已关闭');
      }
    } catch (error) {
      if (mounted) setState(() => _pushError = '$error');
    } finally {
      if (mounted) {
        ref.invalidate(pushSettingsProvider(widget.userId));
        final settings = await PushSettingsStore().load(widget.userId);
        if (mounted) {
          setState(() {
            _enabled = settings.enabled;
            _busy = false;
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preferences = ref.watch(
      notificationPreferencesProvider(widget.userId),
    );
    final value = preferences.value;
    final pushSettings = ref.watch(pushSettingsProvider(widget.userId));
    return Scaffold(
      backgroundColor: context.neu.base,
      appBar: AppBar(
        title: const Text('通知设置'),
        backgroundColor: context.neu.base,
        actions: [
          NeuIconButton(
            tooltip: '刷新通知偏好',
            onPressed: _refreshPreferences,
            icon: Icons.refresh_rounded,
            size: 40,
          ),
        ],
      ),
      body: MaxContentWidth(
        child: RefreshIndicator(
          onRefresh: _refreshPreferences,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
                child: Text(
                  '当前账号：${widget.userId}\n设置哪些消息和事件需要提醒。修改后自动保存，并同步到其他设备。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.neu.textSecondary,
                  ),
                ),
              ),
              if (value == null && preferences.isLoading)
                const _SettingsGroup(
                  title: '通知偏好',
                  children: [
                    ListTile(
                      title: Text('正在读取通知偏好'),
                      trailing: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ],
                ),
              if (value == null && preferences.hasError)
                _SettingsGroup(
                  title: '通知偏好',
                  children: [
                    ListTile(
                      title: const Text('读取通知偏好失败'),
                      subtitle: Text('${preferences.error}'),
                      trailing: TextButton(
                        onPressed: _refreshPreferences,
                        child: const Text('重试'),
                      ),
                    ),
                  ],
                ),
              if (value != null) ..._buildPreferences(value),
              const SizedBox(height: 8),
              _SettingsGroup(
                title: '此设备的推送服务',
                children: [
                  pushSettings.when(
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: LinearProgressIndicator(),
                    ),
                    error: (error, _) => ListTile(
                      title: const Text('读取推送配置失败'),
                      subtitle: Text('$error'),
                      trailing: TextButton(
                        onPressed: () =>
                            ref.invalidate(pushSettingsProvider(widget.userId)),
                        child: const Text('重试'),
                      ),
                    ),
                    data: _buildPushSettings,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildPreferences(NotificationPreferences preferences) {
    final rules = {
      for (final setting in preferences.rules) setting.rule: setting,
    };
    final keywords = preferences.keywords.toSet();
    for (final entry in _keywordOverrides.entries) {
      if (entry.value) {
        keywords.add(entry.key);
      } else {
        keywords.remove(entry.key);
      }
    }

    Widget setting(
      NotificationRule rule,
      String title,
      String subtitle, {
      bool mode = false,
    }) {
      final value = rules[rule];
      final supported = value?.supported ?? false;
      final enabled = supported && !_savingRules.contains(rule);
      final selected = _ruleOverrides[rule] ?? value?.enabled ?? false;
      void change(bool next) => _saveRule(rule, next, selected, title);
      final detail = supported ? subtitle : '$subtitle\n此服务器不支持该规则';
      if (mode) {
        return ListTile(
          title: Text(title),
          subtitle: Text(detail),
          enabled: enabled,
          trailing: DropdownButton<bool>(
            key: ValueKey(rule),
            value: selected,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: true, child: Text('所有消息')),
              DropdownMenuItem(value: false, child: Text('仅提及')),
            ],
            onChanged: enabled
                ? (next) {
                    if (next != null) change(next);
                  }
                : null,
          ),
        );
      }
      return SwitchListTile.adaptive(
        key: ValueKey(rule),
        title: Text(title),
        subtitle: Text(detail),
        value: selected,
        onChanged: enabled ? change : null,
      );
    }

    return [
      _SettingsGroup(
        title: '总体',
        children: [
          setting(
            NotificationRule.muteAll,
            '全部静音',
            '暂停此账号的所有提醒，保留其他偏好；静音时仍可调整下方设置',
          ),
          setting(
            NotificationRule.suppressNotices,
            '过滤机器人 / 通知类消息',
            '不提醒 m.notice 消息；其他消息类型的机器人消息仍按普通规则处理',
          ),
          setting(NotificationRule.suppressEdits, '过滤编辑消息', '消息被编辑时不再次提醒'),
        ],
      ),
      _SettingsGroup(
        title: '新消息提醒范围',
        children: [
          const _InlineMessage(
            text: '选择每类聊天收到哪些新消息时提醒：“所有消息”提醒每条新消息；“仅提及”只保留已启用的提及和关键词提醒。',
          ),
          setting(
            NotificationRule.directMessage,
            '一对一聊天',
            '未加密、仅两位成员的聊天',
            mode: true,
          ),
          setting(
            NotificationRule.encryptedDirectMessage,
            '加密一对一聊天',
            '开启端到端加密的两人聊天',
            mode: true,
          ),
          setting(NotificationRule.groupMessage, '群聊', '未加密的多人聊天', mode: true),
          setting(
            NotificationRule.encryptedGroupMessage,
            '加密群聊',
            '开启端到端加密的多人聊天',
            mode: true,
          ),
          const _InlineMessage(
            text:
                '这里设置聊天的默认提醒范围；已单独设置的房间使用自己的通知设置。邀请、通话等事件按下方选项提醒。后台未解密的消息可能无法识别提及和关键词。',
          ),
        ],
      ),
      _SettingsGroup(
        title: '提及',
        children: [
          setting(NotificationRule.userMention, '直接提及我', '消息中的 @我'),
          setting(
            NotificationRule.roomMention,
            '提及全体成员',
            '@全体 / @room，需发送者有相应权限',
          ),
          setting(NotificationRule.displayName, '包含我的显示名', '旧版提及规则：消息正文包含显示名'),
          setting(
            NotificationRule.userName,
            '包含我的用户名',
            '旧版提及规则：消息正文包含 Matrix 用户名',
          ),
          setting(
            NotificationRule.roomNotif,
            '旧版 @room',
            '兼容旧客户端在消息正文中发送的 @room',
          ),
        ],
      ),
      _SettingsGroup(
        title: '邀请、通话与事件',
        children: [
          setting(NotificationRule.invite, '房间邀请', '有人邀请我加入房间'),
          setting(NotificationRule.call, '通话邀请', '收到语音或视频通话邀请'),
          setting(NotificationRule.memberEvent, '成员变动', '成员加入、离开，以及成员资料变更等事件'),
          setting(NotificationRule.reaction, '表情回应', '消息收到表情回应'),
          setting(NotificationRule.tombstone, '房间升级', '房间升级并迁移到新房间'),
        ],
      ),
      _SettingsGroup(
        title: '投票',
        children: [
          setting(NotificationRule.pollStartDirect, '一对一投票开始', '一对一聊天中发起新投票'),
          setting(NotificationRule.pollStartGroup, '群聊投票开始', '群聊中发起新投票'),
          setting(NotificationRule.pollEndDirect, '一对一投票结束', '一对一聊天中的投票已结束'),
          setting(NotificationRule.pollEndGroup, '群聊投票结束', '群聊中的投票已结束'),
          setting(NotificationRule.pollResponse, '投票回应', '有人提交投票选择'),
        ],
      ),
      _SettingsGroup(
        title: '线程',
        children: [
          setting(NotificationRule.subscribedThread, '已关注线程', '已关注的线程收到新回复时提醒'),
          setting(
            NotificationRule.suppressUnsubscribedThreads,
            '过滤未关注线程',
            '不提醒未关注线程中的回复；需服务器支持线程通知规则',
          ),
        ],
      ),
      _SettingsGroup(
        title: '关键词',
        children: [
          ListTile(
            title: const Text('关键词提醒'),
            subtitle: const Text('普通消息匹配关键词时提醒；可使用 * 和 ? 通配符'),
            trailing: NeuIconButton(
              tooltip: '添加关键词',
              onPressed: _addKeyword,
              icon: Icons.add_rounded,
              size: 36,
            ),
          ),
          if (keywords.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text('尚未设置关键词'),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final keyword in keywords)
                    InputChip(
                      label: Text(keyword),
                      onDeleted: _savingKeywords.contains(keyword)
                          ? null
                          : () => _saveKeyword(keyword, false, true),
                    ),
                ],
              ),
            ),
        ],
      ),
    ];
  }

  Widget _buildPushSettings(PushSettings settings) {
    if (!_loaded) {
      _loaded = true;
      _enabled = settings.enabled;
      _backend = settings.backend;
      _gateway.text = settings.gatewayUrl;
      _appId.text = settings.appId;
      _vapid.text = settings.vapidPublicKey;
    }
    final firebase = fcmPushSupported
        ? ref.watch(firebaseClientConfigProvider)
        : null;
    final project = firebase?.asData?.value;
    final configured =
        _backend == PushBackend.web ||
        (project != null && !fcmPushRuntime.configurationChanged);
    final error =
        _pushError ?? ref.watch(pushRegistrationErrorProvider)[widget.userId];

    return ExpansionTile(
      key: const PageStorageKey('notification-push-settings'),
      title: const Text('推送服务与网关'),
      subtitle: Text(
        pushSupported ? (_enabled ? '推送已启用' : '推送未启用') : '此平台暂不支持消息推送',
      ),
      leading: const Icon(Icons.cloud_outlined),
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      shape: const Border(),
      collapsedShape: const Border(),
      children: [
        if (!pushSupported)
          const _InlineMessage(
            text: 'Android 使用 FCM，浏览器使用 Web Push。当前平台可设置账号通知偏好，但暂不支持接收系统推送。',
          )
        else
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _InlineMessage(
                  text:
                      '此处配置当前设备的推送接入，与上方账号通知偏好分别保存。Matter 不提供默认网关；非加密消息可显示正文，加密消息显示通用提示，点击通知可打开对应聊天。',
                ),
                DropdownButtonFormField<PushBackend>(
                  initialValue: _backend,
                  decoration: const InputDecoration(
                    labelText: '推送通道',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: PushBackend.android,
                      enabled: supportsPushBackend(PushBackend.android),
                      child: const Text('Android · FCM'),
                    ),
                    DropdownMenuItem(
                      value: PushBackend.web,
                      enabled: supportsPushBackend(PushBackend.web),
                      child: const Text('浏览器 · Web Push'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (backend) {
                          if (backend != null) {
                            setState(() => _backend = backend);
                          }
                        },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const PageStorageKey('notification-gateway-url'),
                  controller: _gateway,
                  enabled: !_busy,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '推送网关 URL',
                    hintText: 'https://你的网关/_matrix/push/v1/notify',
                    helperText: '须为 HTTPS 地址',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => validatePushGateway(value ?? ''),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const PageStorageKey('notification-app-id'),
                  controller: _appId,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '应用 ID',
                    helperText: '须与网关中的应用 ID 一致',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => validatePushAppId(value ?? ''),
                ),
                if (_backend == PushBackend.web) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const PageStorageKey('notification-vapid-key'),
                    controller: _vapid,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'VAPID 公钥',
                      helperText: '网关的 Base64URL 格式 P-256 公钥',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) => validateVapidPublicKey(value ?? ''),
                  ),
                  const _InlineMessage(
                    text:
                        '浏览器须支持 Web Push，站点须使用 HTTPS；网关须支持 Web Push/VAPID，并保留账号路由数据。',
                  ),
                ],
                if (fcmPushSupported) ...[
                  const SizedBox(height: 16),
                  Text(
                    project != null
                        ? 'Firebase 项目：${project.projectId}'
                        : '尚未配置 Firebase 项目，暂不可启用 Android 推送',
                  ),
                  const SizedBox(height: 8),
                  NeuButton(
                    onPressed: _busy ? null : _importFirebase,
                    icon: const Icon(Icons.file_upload_outlined),
                    child: const Text('导入 google-services.json'),
                  ),
                  const _InlineMessage(
                    text:
                        'Android 需要 Google Play 服务。Firebase 项目由此安装的所有账号共享，更换项目会关闭并注销所有 Android 推送；网关的 FCM 项目必须与这里一致。',
                  ),
                  if (fcmPushRuntime.configurationChanged)
                    const _InlineMessage(
                      text: '新配置已保存，请在系统设置中强行停止 Matter 后重新打开，再启用推送。',
                    ),
                ],
                if (error != null) _InlineMessage(text: error, error: true),
                const SizedBox(height: 8),
                NeuButton(
                  accent: true,
                  onPressed:
                      _busy || !configured || !supportsPushBackend(_backend)
                      ? null
                      : () => _savePush(true),
                  child: Text(_enabled ? '保存并重新注册' : '启用推送'),
                ),
                if (_enabled || settings.registrations.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  NeuButton(
                    onPressed: _busy ? null : () => _savePush(false),
                    child: Text(_enabled ? '关闭推送' : '重试注销推送'),
                  ),
                ],
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          ),
      ],
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(color: context.neu.textSecondary),
          ),
        ),
        NeuSurface(
          color: context.neu.card,
          radius: NeuRadius.surface,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Material(
            type: MaterialType.transparency,
            child: Column(children: children),
          ),
        ),
      ],
    ),
  );
}

class _InlineMessage extends StatelessWidget {
  const _InlineMessage({required this.text, this.error = false});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: error ? context.neu.error : context.neu.textSecondary,
        height: 1.5,
      ),
    ),
  );
}
