import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum StartupPage {
  remember,
  allChats,
  directMessages,
  ungroupedRooms,
  spaces,
  contacts,
  settings,
}

enum NavigationDestinationPage {
  allChats,
  directMessages,
  ungroupedRooms,
  space,
  spaces,
  contacts,
  settings,
}

extension StartupPageLabel on StartupPage {
  String get label => switch (this) {
    StartupPage.remember => '记住上次页面',
    StartupPage.allChats => '全部会话',
    StartupPage.directMessages => '私聊',
    StartupPage.ungroupedRooms => '未归属群组',
    StartupPage.spaces => '空间列表',
    StartupPage.contacts => '通讯录',
    StartupPage.settings => '设置',
  };
}

class StartupLocation {
  const StartupLocation(this.page, {this.spaceId});
  final NavigationDestinationPage page;
  final String? spaceId;
}

class StartupPageNotifier extends Notifier<StartupPage> {
  bool _edited = false;
  late Future<SharedPreferences> _preferences;

  @override
  StartupPage build() {
    _preferences = SharedPreferences.getInstance();
    _restore();
    return StartupPage.remember;
  }

  Future<void> _restore() async {
    final prefs = await _preferences;
    if (!ref.mounted || _edited) return;
    state =
        StartupPage.values.asNameMap()[prefs.getString('startup_page')] ??
        StartupPage.remember;
  }

  Future<void> setPage(StartupPage page) async {
    _edited = true;
    state = page;
    await (await _preferences).setString('startup_page', page.name);
  }
}

final startupPageProvider = NotifierProvider<StartupPageNotifier, StartupPage>(
  StartupPageNotifier.new,
);

String _lastPageKey(String userId) =>
    'last_page_${base64Url.encode(utf8.encode(userId))}';

Future<void> rememberNavigationPage(
  String userId,
  StartupLocation location,
) async {
  if (userId.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    _lastPageKey(userId),
    jsonEncode({
      'page': location.page.name,
      if (location.spaceId != null) 'space_id': location.spaceId,
    }),
  );
}

Future<StartupLocation> loadStartupLocation(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  final selected =
      StartupPage.values.asNameMap()[prefs.getString('startup_page')] ??
      StartupPage.remember;
  if (selected != StartupPage.remember) {
    return StartupLocation(
      NavigationDestinationPage.values.byName(selected.name),
    );
  }
  final saved = prefs.getString(_lastPageKey(userId));
  if (saved != null) {
    try {
      final data = jsonDecode(saved);
      if (data is Map<String, dynamic>) {
        final page = NavigationDestinationPage.values.asNameMap()[data['page']];
        final spaceId = data['space_id'];
        if (page != null &&
            (page != NavigationDestinationPage.space || spaceId is String)) {
          return StartupLocation(
            page,
            spaceId: spaceId is String ? spaceId : null,
          );
        }
      }
    } on FormatException {
      // An invalid local value falls back to all conversations.
    }
  }
  return const StartupLocation(NavigationDestinationPage.allChats);
}
