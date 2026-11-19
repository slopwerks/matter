import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/room_metadata_patch.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../helpers/neu_test_theme.dart';
import 'package:matter/widgets/neu_surface.dart';

/// The knock-requests provider is gated on an active session; tests pump the
/// management page without one, so force the session ready.
final _sessionReadyOverride = sessionReadyProvider.overrideWith(
  () => MutableState(true),
);

class _FakeRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  bool failSupplementalLoads = true;
  Completer<void>? pendingDetailsUpdate;
  Completer<void>? pendingDetailsLoad;
  Completer<void>? pendingMembersLoad;
  Object? detailsError;
  Completer<void>? pendingKnockLoad;
  Completer<void>? pendingInvite;
  Completer<void>? pendingRejectKnock;
  Completer<void>? pendingLeave;
  int inviteCalls = 0;
  int leaveCalls = 0;
  List<rust.KnockRequest> knockRequests = const [];
  int detailsLoadCalls = 0;
  int membersLoadCalls = 0;
  int approveKnockCalls = 0;
  int rejectKnockCalls = 0;
  int markReadCalls = 0;
  int markUnreadCalls = 0;
  int setMutedCalls = 0;
  int setIgnoredCalls = 0;
  String? ignoredAccountUserId;
  String? ignoredUserId;
  bool? ignoredFlag;
  Completer<void>? pendingMutedUpdate;
  Completer<void>? pendingMutedRead;
  Completer<void>? pendingApproveKnock;
  Completer<void>? pendingMarkRead;
  Completer<void>? pendingMarkUnread;
  Completer<List<String>>? pendingSetIgnored;
  String? nameUpdateError;
  String? topicUpdateError;
  String? updatedName;
  String? updatedTopic;
  bool? updatedTopicFlag;
  bool ignoredUsersFromServer = true;
  List<String> ignoredUsers = const ['@blocked:example.org'];
  String roomName = 'Project room';
  String? roomTopic = 'Topic';
  String? roomAvatarUrl;
  String? roomNameEventId = r'$name-0';
  String? roomAvatarEventId;
  String? roomTopicEventId = r'$topic-0';
  bool muted = true;
  List<rust.Contact> members = const [
    rust.Contact(id: '@alice:example.org', name: 'Alice', status: 'online'),
  ];

  @override
  Future<rust.RoomDetails> crateApiMatrixGetRoomDetails({
    required String roomId,
  }) async {
    detailsLoadCalls++;
    await pendingDetailsLoad?.future;
    if (detailsError case final error?) throw error;
    return rust.RoomDetails(
      id: roomId,
      name: roomName,
      hasExplicitName: true,
      avatarUrl: roomAvatarUrl,
      topic: roomTopic,
      nameEventId: roomNameEventId,
      avatarEventId: roomAvatarEventId,
      topicEventId: roomTopicEventId,
    );
  }

  @override
  Future<bool> crateApiMatrixIsRoomMuted({required String roomId}) async {
    await pendingMutedRead?.future;
    if (failSupplementalLoads) throw StateError('muted unavailable');
    return muted;
  }

  @override
  Future<void> crateApiMatrixSetRoomMuted({
    required String accountUserId,
    required String roomId,
    required bool muted,
  }) {
    setMutedCalls++;
    return pendingMutedUpdate?.future ?? Future.value();
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async {
    membersLoadCalls++;
    await pendingMembersLoad?.future;
    if (failSupplementalLoads) throw StateError('members unavailable');
    return members;
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  @override
  Future<List<rust.KnockRequest>> crateApiMatrixGetRoomKnockRequests({
    required String roomId,
  }) async {
    await pendingKnockLoad?.future;
    if (failSupplementalLoads) throw StateError('knocks unavailable');
    return knockRequests;
  }

  @override
  Future<void> crateApiMatrixInviteUserToRoom({
    required String accountUserId,
    required String roomId,
    required String userId,
  }) {
    inviteCalls++;
    return pendingInvite?.future ?? Future.value();
  }

  @override
  Future<rust.IgnoredUsers> crateApiMatrixGetIgnoredUsers() async {
    if (failSupplementalLoads) throw StateError('ignored unavailable');
    return rust.IgnoredUsers(
      userIds: ignoredUsers,
      fromServer: ignoredUsersFromServer,
    );
  }

  @override
  Future<List<String>> crateApiMatrixSetUserIgnored({
    required String accountUserId,
    required String userId,
    required bool ignored,
  }) {
    setIgnoredCalls++;
    ignoredAccountUserId = accountUserId;
    ignoredUserId = userId;
    ignoredFlag = ignored;
    // Reflect the server's post-write list (the fake holds the pre-write
    // state, so without an explicit completer the caller-visible list is
    // the current one — never an empty list, which would silently wipe the
    // persisted snapshot in production-shaped code paths).
    return pendingSetIgnored?.future ?? Future.value(ignoredUsers);
  }

  @override
  Future<rust.RoomDetailsUpdate> crateApiMatrixUpdateRoomDetails({
    required String accountUserId,
    required String roomId,
    required String name,
    required bool updateName,
    required bool updateTopic,
    String? topic,
  }) async {
    updatedName = name;
    updatedTopicFlag = updateTopic;
    updatedTopic = updateTopic ? topic : null;
    await pendingDetailsUpdate?.future;
    return rust.RoomDetailsUpdate(
      nameEventId: updateName && nameUpdateError == null ? r'$name-1' : null,
      topicEventId: updateTopic && topicUpdateError == null
          ? r'$topic-1'
          : null,
      nameError: nameUpdateError,
      topicError: topicUpdateError,
    );
  }

  @override
  Future<void> crateApiMatrixApproveRoomKnock({
    required String accountUserId,
    required String roomId,
    required String userId,
  }) async {
    approveKnockCalls++;
    await pendingApproveKnock?.future;
  }

  @override
  Future<void> crateApiMatrixRejectRoomKnock({
    required String accountUserId,
    required String roomId,
    required String userId,
  }) async {
    rejectKnockCalls++;
    await pendingRejectKnock?.future;
  }

  @override
  Future<void> crateApiMatrixLeaveRoom({
    required String accountUserId,
    required String roomId,
  }) async {
    leaveCalls++;
    await pendingLeave?.future;
  }

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    markReadCalls++;
    await pendingMarkRead?.future;
    return true;
  }

  @override
  Future<void> crateApiMatrixMarkRoomUnread({
    required String accountUserId,
    required String roomId,
  }) async {
    markUnreadCalls++;
    await pendingMarkUnread?.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    // Ignore-list reconciliation state is process-wide in production and is
    // reset by session transitions. These tests create fresh provider
    // containers for the same account, so mirror that boundary explicitly.
    resetIgnoredListAccountState('@carol:example.org');
    resetIgnoredListAccountState('@confirmed-management:example.org');
    rustApi.failSupplementalLoads = true;
    rustApi.pendingDetailsUpdate = null;
    rustApi.pendingDetailsLoad = null;
    rustApi.pendingMembersLoad = null;
    rustApi.detailsError = null;
    rustApi.pendingKnockLoad = null;
    rustApi.pendingInvite = null;
    rustApi.pendingRejectKnock = null;
    rustApi.pendingLeave = null;
    rustApi.inviteCalls = 0;
    rustApi.leaveCalls = 0;
    rustApi.knockRequests = const [];
    rustApi.detailsLoadCalls = 0;
    rustApi.membersLoadCalls = 0;
    rustApi.approveKnockCalls = 0;
    rustApi.rejectKnockCalls = 0;
    rustApi.markReadCalls = 0;
    rustApi.markUnreadCalls = 0;
    rustApi.setMutedCalls = 0;
    rustApi.setIgnoredCalls = 0;
    rustApi.ignoredAccountUserId = null;
    rustApi.pendingMutedUpdate = null;
    rustApi.pendingMutedRead = null;
    rustApi.pendingApproveKnock = null;
    rustApi.pendingMarkRead = null;
    rustApi.pendingMarkUnread = null;
    rustApi.pendingSetIgnored = null;
    rustApi.nameUpdateError = null;
    rustApi.topicUpdateError = null;
    rustApi.updatedName = null;
    rustApi.updatedTopic = null;
    rustApi.updatedTopicFlag = null;
    rustApi.ignoredUsersFromServer = true;
    rustApi.ignoredUsers = const ['@blocked:example.org'];
    rustApi.roomName = 'Project room';
    rustApi.roomTopic = 'Topic';
    rustApi.roomAvatarUrl = null;
    rustApi.roomNameEventId = r'$name-0';
    rustApi.roomAvatarEventId = null;
    rustApi.roomTopicEventId = r'$topic-0';
    rustApi.muted = true;
    rustApi.members = const [
      rust.Contact(id: '@alice:example.org', name: 'Alice', status: 'online'),
    ];
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows partial load failures instead of empty room data', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('无法加载成员'), findsOneWidget);
    expect(find.text('无法加载加入请求'), findsOneWidget);
    expect(find.text('通知设置加载/更新失败，点击重试'), findsOneWidget);
    expect(find.text('无法加载已忽略用户'), findsOneWidget);
    expect(find.text('成员 0'), findsNothing);
    expect(find.text('已忽略用户 (0)'), findsNothing);
  });

  testWidgets('retries a failed supplemental section independently', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    rustApi.failSupplementalLoads = false;

    final memberErrorTile = find.ancestor(
      of: find.text('无法加载成员'),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: memberErrorTile, matching: find.byTooltip('重试')),
    );
    await tester.pumpAndSettle();

    expect(find.text('成员 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('无法加载加入请求'), findsOneWidget);
  });

  testWidgets('refreshes members for room membership sync events', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('成员 1'), findsOneWidget);

    rustApi.members = const [
      rust.Contact(id: '@alice:example.org', name: 'Alice', status: 'online'),
      rust.Contact(id: '@bob:example.org', name: 'Bob', status: 'online'),
    ];
    rustApi.syncEvents.add(
      const rust.SyncEvent.roomMembersChanged(roomId: '!other:example.org'),
    );
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(rustApi.membersLoadCalls, 1);

    rustApi.syncEvents.add(
      const rust.SyncEvent.roomMembersChanged(roomId: '!room:example.org'),
    );
    // The event-driven member refresh is throttled (500ms), like the
    // knock-list refresh; advance past the throttle before settling.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(rustApi.membersLoadCalls, 2);
    expect(find.text('成员 2'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets(
    'sync refreshes remote room state without overwriting a local draft',
    (tester) async {
      rustApi.failSupplementalLoads = false;
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [_sessionReadyOverride],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: RoomManagementPage(
              roomId: '!room:example.org',
              roomName: 'Project room',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      rustApi.roomName = 'Remote name';
      rustApi.roomTopic = 'Remote topic';
      rustApi.roomAvatarUrl = 'mxc://example.org/remote';
      rustApi.roomNameEventId = r'$name-remote';
      rustApi.roomAvatarEventId = r'$avatar-remote';
      rustApi.roomTopicEventId = r'$topic-remote';
      rustApi.muted = false;
      rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
      await tester.pumpAndSettle();

      final nameField = find.widgetWithText(TextField, '房间名称');
      final topicField = find.widgetWithText(TextField, '房间主题');
      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'Remote name',
      );
      expect(
        tester.widget<TextField>(topicField).controller!.text,
        'Remote topic',
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse,
      );

      await tester.enterText(nameField, 'Local draft');
      rustApi.roomName = 'Newer remote name';
      rustApi.roomTopic = 'Newer remote topic';
      rustApi.roomNameEventId = r'$name-newer-remote';
      rustApi.roomTopicEventId = r'$topic-newer-remote';
      rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(nameField).controller!.text,
        'Local draft',
      );
      expect(
        tester.widget<TextField>(topicField).controller!.text,
        'Newer remote topic',
      );
    },
  );

  testWidgets('refreshes ignored users for account-data sync events', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(
            () => MutableState<String?>('@remote-ignore-test:example.org'),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已忽略用户 (1)'), findsOneWidget);
    expect(find.byTooltip('忽略用户'), findsOneWidget);

    rustApi.ignoredUsers = const [
      '@blocked:example.org',
      '@alice:example.org',
      '@remote:example.org',
    ];
    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
    await tester.pumpAndSettle();

    expect(find.text('已忽略用户 (3)'), findsOneWidget);
    expect(find.byTooltip('取消忽略'), findsOneWidget);

    rustApi.ignoredUsers = const ['@blocked:example.org'];
    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
    await tester.pumpAndSettle();

    expect(find.text('已忽略用户 (1)'), findsOneWidget);
    expect(find.byTooltip('忽略用户'), findsOneWidget);
  });

  testWidgets('initial load cannot overwrite a newer ignored-user snapshot', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    rustApi.pendingMembersLoad = Completer<void>();
    final staleIgnoredUsers = Completer<Set<String>>();
    var ignoredBuilds = 0;
    final container = ProviderContainer(
      overrides: [
        _sessionReadyOverride,
        ignoredUserIdsProvider.overrideWith((ref) {
          ignoredBuilds++;
          return ignoredBuilds == 1
              ? staleIgnoredUsers.future
              : Future.value({'@new-one:example.org', '@new-two:example.org'});
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pump();

    container.invalidate(ignoredUserIdsProvider);
    expect(await container.read(ignoredUserIdsProvider.future), hasLength(2));
    await tester.pump();
    await tester.pump();

    staleIgnoredUsers.complete({'@stale:example.org'});
    rustApi.pendingMembersLoad!.complete();
    await tester.pumpAndSettle();

    expect(find.text('已忽略用户 (2)'), findsOneWidget);
    expect(find.text('已忽略用户 (1)'), findsNothing);
  });

  testWidgets('full refresh keeps a newer confirmed ignore list', (
    tester,
  ) async {
    const userId = '@confirmed-management:example.org';
    rustApi.failSupplementalLoads = false;
    rustApi.ignoredUsersFromServer = false;
    // The raw SDK store still lacks Alice, but Rust's FFI fallback overlays
    // the pending local override before returning this effective list.
    rustApi.ignoredUsers = const ['@blocked:example.org', '@alice:example.org'];
    await persistIgnoredUserList(userId, {
      '@blocked:example.org',
      '@alice:example.org',
    });
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(
            () => MutableState<String?>(userId),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已忽略用户 (2)'), findsOneWidget);
    expect(find.byTooltip('取消忽略'), findsOneWidget);

    // A lag-compensation refresh is not proof that the SDK store has seen
    // this device's successful account-data write yet.
    rustApi.syncEvents.add(const rust.SyncEvent.fullRefreshRequired());
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump();
    }

    expect(find.text('已忽略用户 (2)'), findsOneWidget);
    expect(find.byTooltip('取消忽略'), findsOneWidget);
  });

  testWidgets('finishing a save after leaving does not update disposed state', (
    tester,
  ) async {
    final update = Completer<void>();
    rustApi.pendingDetailsUpdate = update;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    update.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ignoring a user writes through even if the page closes mid-request',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final ignore = Completer<List<String>>();
      rustApi.failSupplementalLoads = false;
      rustApi.pendingSetIgnored = ignore;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _sessionReadyOverride,
            activeUserIdProvider.overrideWith(
              () => MutableState<String?>('@carol:example.org'),
            ),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: RoomManagementPage(
              roomId: '!room:example.org',
              roomName: 'Project room',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('忽略用户'));
      await tester.pump();
      expect(rustApi.setIgnoredCalls, 1);
      expect(rustApi.ignoredAccountUserId, '@carol:example.org');

      // The page is popped while the server request is still in flight; the
      // write-through must still land in the persisted snapshot, otherwise
      // the sender's cached messages stay visible. The response carries the
      // complete post-write list (the server already held @blocked), so the
      // first-ever write-through must not drop other ignored users.
      await tester.pumpWidget(const SizedBox.shrink());
      ignore.complete(const ['@blocked:example.org', '@alice:example.org']);
      await tester.pump();
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ignored_users_v1_@carol:example.org'),
        containsAll(['@blocked:example.org', '@alice:example.org']),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('ignore actions adopt the complete server list', (tester) async {
    rustApi.failSupplementalLoads = false;
    final ignore = Completer<List<String>>();
    rustApi.pendingSetIgnored = ignore;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(
            () => MutableState<String?>('@carol:example.org'),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('忽略用户'));
    await tester.pump();
    const updated = [
      '@blocked:example.org',
      '@alice:example.org',
      '@remote:example.org',
    ];
    rustApi.ignoredUsers = updated;
    ignore.complete(updated);
    await tester.pumpAndSettle();

    expect(find.text('已忽略用户 (3)'), findsOneWidget);
    expect(find.byTooltip('取消忽略'), findsOneWidget);
  });

  testWidgets('keeps saved room details instead of reloading stale cache', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    RoomNamePatch? changedName;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              if (patch is RoomNamePatch) changedName = patch;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Renamed room');
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(rustApi.detailsLoadCalls, 1);
    expect(rustApi.updatedName, 'Renamed room');
    expect(rustApi.updatedTopic, 'Updated topic');
    expect(rustApi.updatedTopicFlag, isTrue);
    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      'Renamed room',
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'Updated topic',
    );
    expect(changedName?.name, 'Renamed room');

    // A sync can arrive before the SDK room state sees this device's state
    // event echo. The stale pre-save snapshot must not revert the form.
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      'Renamed room',
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'Updated topic',
    );

    // Once the matching state-event IDs arrive, the pending edits reconcile.
    rustApi.roomName = 'Renamed room';
    rustApi.roomTopic = 'Updated topic';
    rustApi.roomNameEventId = r'$name-1';
    rustApi.roomTopicEventId = r'$topic-1';
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pumpAndSettle();
    expect(rustApi.detailsLoadCalls, 3);
  });

  testWidgets('save completion preserves a concurrent room-state refresh', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    rustApi.pendingDetailsLoad = Completer<void>();
    rustApi.pendingDetailsUpdate = Completer<void>();
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(rustApi.detailsLoadCalls, 2);

    await tester.enterText(find.byType(TextField).first, 'Name during save');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pump();
    expect(rustApi.updatedName, 'Name during save');

    rustApi.roomName = 'Remote name during save';
    rustApi.roomTopic = 'Remote topic during save';
    rustApi.roomAvatarUrl = 'mxc://example.org/remote-during-save';
    rustApi.roomNameEventId = r'$name-remote-during-save';
    rustApi.roomTopicEventId = r'$topic-remote-during-save';
    rustApi.roomAvatarEventId = r'$avatar-remote-during-save';
    rustApi.pendingDetailsLoad!.complete();
    await tester.pump();

    rustApi.pendingDetailsUpdate!.complete();
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    // The name the user typed during the save is kept (in-progress edits
    // are never clobbered by a concurrent refresh)...
    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      'Name during save',
    );
    // ...while the untouched topic adopts the remote value.
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'Remote topic during save',
    );
  });

  testWidgets('renaming does not submit an untouched topic', (tester) async {
    rustApi.failSupplementalLoads = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Renamed room');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(rustApi.updatedName, 'Renamed room');
    expect(rustApi.updatedTopic, isNull);
    expect(rustApi.updatedTopicFlag, isFalse);
  });

  testWidgets('keeps a successful rename when the topic update fails', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.topicUpdateError = 'topic unavailable';
    RoomNamePatch? changedName;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              if (patch is RoomNamePatch) changedName = patch;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Renamed room');
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(changedName?.name, 'Renamed room');
    expect(changedName?.nameEventId, r'$name-1');
    expect(find.textContaining('主题更新失败'), findsOneWidget);
  });

  testWidgets('saving only the topic preserves remote room metadata', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    RoomMetadataPatch? changedPatch;
    var outerName = 'Remote name';
    String? outerAvatarUrl = 'mxc://example.org/remote-avatar';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
            onRoomDetailsChanged: (patch) {
              changedPatch = patch;
              switch (patch) {
                case RoomNamePatch():
                  outerName = patch.name;
                  break;
                case RoomAvatarPatch():
                  outerAvatarUrl = patch.avatarUrl;
                  break;
              }
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'Updated topic');
    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pumpAndSettle();

    expect(changedPatch, isNull);
    expect(outerName, 'Remote name');
    expect(outerAvatarUrl, 'mxc://example.org/remote-avatar');
  });

  testWidgets('removes an approved knock and refreshes room members', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('批准'));
    await tester.pumpAndSettle();

    expect(rustApi.approveKnockCalls, 1);
    expect(rustApi.membersLoadCalls, 2);
    expect(find.text('Bob'), findsNothing);
  });

  testWidgets('disables both knock actions while one is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];
    final pendingApprove = Completer<void>();
    rustApi.pendingApproveKnock = pendingApprove;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('批准'));
    await tester.pump();

    IconButton actionButton(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );
    expect(actionButton('批准').onPressed, isNull);
    expect(actionButton('拒绝').onPressed, isNull);
    await tester.tap(find.byTooltip('拒绝'));
    expect(rustApi.approveKnockCalls, 1);
    expect(rustApi.rejectKnockCalls, 0);

    pendingApprove.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a re-knock becomes visible after the echo or grace expiry', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
    await tester.tap(find.byTooltip('拒绝'));
    await tester.pumpAndSettle();

    expect(rustApi.rejectKnockCalls, 1);
    // Optimistically hidden until the server echo removes the membership.
    expect(find.text('Bob'), findsNothing);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(RoomManagementPage)),
    );

    // A direct re-knock snapshot may arrive without an observed empty state.
    // The grace expiry must reveal it without another provider refresh.
    await tester.pump(const Duration(seconds: 11));
    await tester.pump();
    expect(find.text('Bob'), findsOneWidget);

    // Server echo: the rejected knock is gone from the membership list.
    rustApi.knockRequests = const [];
    container.invalidate(roomKnockRequestsProvider('!room:example.org'));
    await tester.pumpAndSettle();

    // The same user knocks again; the new request must become visible.
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];
    container.invalidate(roomKnockRequestsProvider('!room:example.org'));
    await tester.pumpAndSettle();

    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('disables the mute switch while a mute update is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    final pending = Completer<void>();
    rustApi.pendingMutedUpdate = pending;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final muteSwitch = find.byType(SwitchListTile);
    expect(muteSwitch, findsOneWidget);

    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 1);

    // While the request is in flight the switch is disabled: rapid toggles
    // must not fire competing push-rule updates.
    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 1);

    pending.complete();
    await tester.pumpAndSettle();
    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 2);
  });

  testWidgets('account switch blocks stale page actions from reaching Rust', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final accountState = MutableState<String?>('@original:example.org');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(() => accountState),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final muteSwitch = find.byType(SwitchListTile);
    await tester.tap(muteSwitch);
    await tester.pump();
    expect(rustApi.setMutedCalls, 1);

    // The page outlives its account (desktop panels, tab stacks): switching
    // replaces the page content with the neutral placeholder immediately, so
    // no further action can reach the new account's client.
    accountState.value = '@other:example.org';
    await tester.pumpAndSettle();
    expect(find.text('账号已切换'), findsOneWidget);
    expect(muteSwitch, findsNothing);
    expect(rustApi.setMutedCalls, 1);
  });

  testWidgets('switching away and back preserves unsaved room edits', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final accountState = MutableState<String?>('@original:example.org');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(() => accountState),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Unsaved room name');
    await tester.enterText(fields.at(1), 'Unsaved topic');

    accountState.value = '@other:example.org';
    await tester.pumpAndSettle();
    accountState.value = '@original:example.org';
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(fields.at(0)).controller!.text,
      'Unsaved room name',
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller!.text,
      'Unsaved topic',
    );
  });

  testWidgets('a mid-load account switch shows the placeholder, not a crash', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.pendingDetailsLoad = Completer<void>();
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final accountState = MutableState<String?>('@original:example.org');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(() => accountState),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pump();

    // Switch account while the initial load is still in flight, then let
    // the load finish: the page must not apply the old account's data (or
    // crash on the unloaded details), but show the neutral placeholder.
    accountState.value = '@other:example.org';
    await tester.pump();
    rustApi.pendingDetailsLoad!.complete();
    await tester.pumpAndSettle();

    expect(find.text('账号已切换'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a failed reload after switching back shows the error, not the placeholder',
    (tester) async {
      rustApi.failSupplementalLoads = false;
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final accountState = MutableState<String?>('@original:example.org');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            _sessionReadyOverride,
            activeUserIdProvider.overrideWith(() => accountState),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: RoomManagementPage(
              roomId: '!room:example.org',
              roomName: 'Project room',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Switch away: placeholder shows.
      accountState.value = '@other:example.org';
      await tester.pumpAndSettle();
      expect(find.text('账号已切换'), findsOneWidget);

      // Switch back while the network is failing: the page must surface the
      // load error (with its retry entry), not keep the stale placeholder.
      rustApi.detailsError = StateError('offline');
      accountState.value = '@original:example.org';
      await tester.pumpAndSettle();

      expect(find.text('账号已切换'), findsNothing);
      expect(find.textContaining('加载失败:'), findsOneWidget);
    },
  );

  testWidgets('marking the current room unread closes its chat view', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    var roomClosed = false;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                      onRoomClosed: () => roomClosed = true,
                    ),
                  ),
                ),
                child: const Text('打开房间'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开房间'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pumpAndSettle();

    expect(rustApi.markUnreadCalls, 1);
    expect(roomClosed, isTrue);
    expect(find.byType(RoomManagementPage), findsNothing);
    expect(find.text('打开房间'), findsOneWidget);
  });

  testWidgets('a failed pending unread action restores state after leaving', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.pendingMarkUnread = Completer<void>();
    final container = ProviderContainer(overrides: [_sessionReadyOverride]);
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                    ),
                  ),
                ),
                child: const Text('打开房间'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开房间'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pump();
    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isTrue,
    );

    Navigator.of(tester.element(find.byType(RoomManagementPage))).pop();
    await tester.pumpAndSettle();
    rustApi.pendingMarkUnread!.completeError(StateError('offline'));
    await tester.pump();

    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isFalse,
    );
    expect(
      container.read(roomUnreadOverrideProvider('!room:example.org')),
      isNull,
    );
  });

  testWidgets('a timed-out pending unread action keeps the suppression armed', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.pendingMarkUnread = Completer<void>();
    final container = ProviderContainer(overrides: [_sessionReadyOverride]);
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                    ),
                  ),
                ),
                child: const Text('打开房间'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开房间'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pump();
    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isTrue,
    );

    // A timeout is not a failure: the queued write's tail may still land,
    // and a later auto-read must not revoke a marker that did land. The
    // suppression stays armed (same discipline as the mute timeout marker);
    // only the optimistic override is dropped.
    rustApi.pendingMarkUnread!.completeError(StateError('操作超时，请稍后查看最终状态。'));
    await tester.pump();

    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isTrue,
    );
    expect(
      container.read(roomUnreadOverrideProvider('!room:example.org')),
      isNull,
    );
  });

  testWidgets('a failed pending read action restores state after leaving', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.pendingMarkRead = Completer<void>();
    final container = ProviderContainer(overrides: [_sessionReadyOverride]);
    addTearDown(container.dispose);
    container
            .read(roomAutoReadSuppressedProvider('!room:example.org').notifier)
            .value =
        true;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                    ),
                  ),
                ),
                child: const Text('打开房间'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开房间'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('标记为已读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为已读'));
    await tester.pump();
    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isFalse,
    );

    Navigator.of(tester.element(find.byType(RoomManagementPage))).pop();
    await tester.pumpAndSettle();
    rustApi.pendingMarkRead!.completeError(StateError('offline'));
    await tester.pump();

    expect(
      container.read(roomAutoReadSuppressedProvider('!room:example.org')),
      isTrue,
    );
  });

  testWidgets(
    'a completed room action does not pop a page the user already left',
    (tester) async {
      rustApi.failSupplementalLoads = false;
      rustApi.pendingMarkUnread = Completer<void>();
      final container = ProviderContainer(overrides: [_sessionReadyOverride]);
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const RoomManagementPage(
                        roomId: '!room:example.org',
                        roomName: 'Project room',
                      ),
                    ),
                  ),
                  child: const Text('打开房间'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开房间'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('标记为未读'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('标记为未读'));
      await tester.pump();

      // The user leaves via the back button while the request is in flight.
      Navigator.of(tester.element(find.byType(RoomManagementPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(RoomManagementPage), findsNothing);

      // The action completes after the page is gone: the management page is
      // no longer the current route, so it must not pop the underlying
      // scaffold route too (that would drop the user out of the app).
      rustApi.pendingMarkUnread!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(RoomManagementPage), findsNothing);
      expect(find.text('打开房间'), findsOneWidget);
    },
  );

  testWidgets('closing a nested chat preserves its parent route', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (rootContext) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(rootContext).push(
                  MaterialPageRoute<void>(
                    builder: (spaceContext) => Scaffold(
                      body: TextButton(
                        onPressed: () => Navigator.of(spaceContext).push(
                          MaterialPageRoute<void>(
                            builder: (chatContext) => Scaffold(
                              body: TextButton(
                                onPressed: () => Navigator.of(chatContext).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const RoomManagementPage(
                                      roomId: '!room:example.org',
                                      roomName: 'Project room',
                                    ),
                                  ),
                                ),
                                child: const Text('打开管理'),
                              ),
                            ),
                          ),
                        ),
                        child: const Text('打开聊天'),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开空间'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开空间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开管理'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('标记为未读'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('标记为未读'));
    await tester.pumpAndSettle();

    expect(find.text('打开聊天'), findsOneWidget);
    expect(find.text('打开空间'), findsNothing);
    expect(find.byType(RoomManagementPage), findsNothing);
  });

  testWidgets('a background refresh clears the full-page load error', (
    tester,
  ) async {
    rustApi.detailsError = StateError('offline');
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('加载失败:'), findsOneWidget);

    // Connectivity returns; the next sync cycle reloads the room state.
    rustApi.detailsError = null;
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败:'), findsNothing);
    expect(find.text('房间信息'), findsOneWidget);
    expect(find.text('Project room'), findsOneWidget);
    // The recovery also restores the members the failed initial load never
    // fetched (the recovered page must not silently show "成员 0").
    expect(find.text('成员 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
  });

  testWidgets('knock section keeps its list while a refresh is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@knocker:example.org', displayName: 'Knocker'),
    ];
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(
            () => MutableState<String?>('@alice:example.org'),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加入请求 1'), findsOneWidget);
    expect(find.byTooltip('批准'), findsOneWidget);

    // A room-list sync event invalidates the knock provider; its reload is
    // slow. The section must keep showing the previous list instead of
    // disappearing and re-appearing.
    rustApi.pendingKnockLoad = Completer<void>();
    rustApi.syncEvents.add(const rust.SyncEvent.roomListChanged());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.text('加入请求 1'), findsOneWidget);
    expect(find.byTooltip('批准'), findsOneWidget);

    rustApi.pendingKnockLoad!.complete();
    await tester.pumpAndSettle();
    expect(find.text('加入请求 1'), findsOneWidget);
  });

  testWidgets('invite dialog disables submit while the invite is in flight', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byTooltip('邀请用户'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('邀请用户'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '@newbie:example.org');
    rustApi.pendingInvite = Completer<void>();
    await tester.tap(find.text('邀请'));
    await tester.pump();

    // The request is in flight with the dialog still open: both buttons are
    // disabled, so a second tap cannot send a duplicate invite.
    expect(rustApi.inviteCalls, 1);
    expect(
      tester.widget<NeuButton>(find.widgetWithText(NeuButton, '邀请')).onPressed,
      isNull,
    );
    await tester.tap(find.text('邀请'), warnIfMissed: false);
    await tester.pump();
    expect(rustApi.inviteCalls, 1);
    expect(find.text('邀请用户'), findsOneWidget);

    rustApi.pendingInvite!.complete();
    await tester.pumpAndSettle();
    expect(find.text('邀请用户'), findsNothing);
    expect(find.text('邀请已发送'), findsOneWidget);
  });

  testWidgets('knock action failures show an error and keep the section', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    rustApi.knockRequests = const [
      rust.KnockRequest(userId: '@bob:example.org', displayName: 'Bob'),
    ];

    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Approval failure: error surfaced, the request stays actionable.
    rustApi.pendingApproveKnock = Completer<void>();
    await tester.tap(find.byTooltip('批准'));
    await tester.pump();
    rustApi.pendingApproveKnock!.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败:'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(rustApi.membersLoadCalls, 1);

    // Rejection failure: same behavior on the reject path.
    rustApi.pendingRejectKnock = Completer<void>();
    await tester.tap(find.byTooltip('拒绝'));
    await tester.pump();
    rustApi.pendingRejectKnock!.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败:'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(rustApi.rejectKnockCalls, 1);
  });

  testWidgets('invite failure keeps the dialog open and shows an error', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byTooltip('邀请用户'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('邀请用户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '@newbie:example.org');

    rustApi.pendingInvite = Completer<void>();
    await tester.tap(find.text('邀请'));
    await tester.pump();
    rustApi.pendingInvite!.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    // The dialog stays open so the user can retry, with the failure visible.
    expect(find.text('邀请用户'), findsOneWidget);
    expect(find.textContaining('操作失败:'), findsOneWidget);

    // Let the error snackbar (4s default) expire so the retry result can
    // surface; pump past the default duration.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    rustApi.pendingInvite = Completer<void>();
    await tester.tap(find.text('邀请'));
    await tester.pump();
    expect(rustApi.inviteCalls, 2);
    rustApi.pendingInvite!.complete();
    await tester.pumpAndSettle();
    expect(find.text('邀请用户'), findsNothing);
    expect(find.text('邀请已发送'), findsOneWidget);
  });

  testWidgets('invite success refreshes room members', (tester) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rustApi.membersLoadCalls, 1);

    await tester.scrollUntilVisible(
      find.byTooltip('邀请用户'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('邀请用户'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '@newbie:example.org');
    await tester.tap(find.text('邀请'));
    await tester.pumpAndSettle();

    expect(rustApi.inviteCalls, 1);
    // The invitee must appear without waiting for the server join event:
    // the success path refetches members like the knock approval path.
    expect(rustApi.membersLoadCalls, 2);
  });

  testWidgets('leaving a room confirms, calls leave, and closes the page', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (rootContext) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(rootContext).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                    ),
                  ),
                ),
                child: const Text('打开管理'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开管理'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('退出房间'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('退出房间'));
    await tester.pumpAndSettle();
    expect(find.text('退出后将无法继续接收此房间的新消息。'), findsOneWidget);

    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    expect(rustApi.leaveCalls, 1);
    expect(find.byType(RoomManagementPage), findsNothing);
    expect(find.text('打开管理'), findsOneWidget);
  });

  testWidgets('leaving a room can be cancelled', (tester) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('退出房间'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('退出房间'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(rustApi.leaveCalls, 0);
    expect(find.byType(RoomManagementPage), findsOneWidget);
  });

  testWidgets('a failed leave keeps the page and shows the error', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('退出房间'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('退出房间'));
    await tester.pumpAndSettle();

    rustApi.pendingLeave = Completer<void>();
    await tester.tap(find.text('退出'));
    await tester.pump();
    rustApi.pendingLeave!.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败:'), findsOneWidget);
    expect(find.byType(RoomManagementPage), findsOneWidget);
  });

  testWidgets('a leave in flight can be dismissed and still closes the page', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (rootContext) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(rootContext).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const RoomManagementPage(
                      roomId: '!room:example.org',
                      roomName: 'Project room',
                    ),
                  ),
                ),
                child: const Text('打开管理'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开管理'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('退出房间'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('退出房间'));
    await tester.pumpAndSettle();

    rustApi.pendingLeave = Completer<void>();
    await tester.tap(find.text('退出'));
    await tester.pump();

    // While the leave is in flight the dialog stays dismissible (barrier
    // tap): the write keeps running and the page closes itself on
    // success, so the user is not locked in for the whole queue bound.
    await tester.tapAt(const Offset(10, 10));
    // Let the dialog's pop transition finish (bounded pumps: the in-flight
    // spinner keeps an indeterminate animation, so pumpAndSettle would
    // spin forever).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('退出后将无法继续接收此房间的新消息。'), findsNothing);

    rustApi.pendingLeave!.complete();
    await tester.pumpAndSettle();

    expect(rustApi.leaveCalls, 1);
    expect(find.byType(RoomManagementPage), findsNothing);
    expect(find.text('打开管理'), findsOneWidget);
  });

  testWidgets('an in-flight mute toggle wins over a stale refresh read', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);

    // A sync cycle starts a muted-state refresh whose read hangs.
    rustApi.pendingMutedRead = Completer<void>();
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(rustApi.detailsLoadCalls, 2);

    // The user toggles the switch while that read is in flight.
    rustApi.pendingMutedUpdate = Completer<void>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    // The stale read returns the pre-toggle server value (true): it must
    // not overwrite the optimistic toggle. The write is still in flight
    // (the switch shows a saving spinner), so a pumpAndSettle would spin
    // on the indeterminate indicator; pump bounded frames instead.
    rustApi.pendingMutedRead!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    rustApi.pendingMutedUpdate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('已关闭免打扰'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('a timed-out mute write keeps the optimistic value', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    // A timeout may still land server-side: the switch keeps the optimistic
    // value and the failure promises a later sync reconciliation.
    rustApi.pendingMutedUpdate = Completer<void>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    rustApi.pendingMutedUpdate!.completeError(StateError('操作超时，请稍后查看最终状态。'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    expect(find.textContaining('若未生效请点击重试同步'), findsOneWidget);
  });

  testWidgets(
    'a contradicting sync read after a mute timeout keeps the retry tile',
    (tester) async {
      rustApi.failSupplementalLoads = false;
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [_sessionReadyOverride],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: RoomManagementPage(
              roomId: '!room:example.org',
              roomName: 'Project room',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      // A timeout may still land server-side: the switch keeps the
      // optimistic value and the failure promises a later sync
      // reconciliation.
      rustApi.pendingMutedUpdate = Completer<void>();
      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      rustApi.pendingMutedUpdate!.completeError(StateError('操作超时，请稍后查看最终状态。'));
      await tester.pumpAndSettle();
      expect(find.text('通知设置加载/更新失败，点击重试'), findsOneWidget);

      // The write actually failed: the next sync read returns the server's
      // contradicting value. The switch must not auto-roll back (the queued
      // write could still land), and the error tile must survive the
      // successful read — a null `muted.error` must not hide the retry
      // entry while the write's outcome is still unknown.
      rustApi.muted = true;
      rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.text('通知设置加载/更新失败，点击重试'), findsOneWidget);
      expect(find.byTooltip('重试'), findsOneWidget);

      // The manual retry (force-adopt) settles the switch onto the server
      // value and clears the error display.
      await tester.tap(find.byTooltip('重试'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('通知设置加载/更新失败，点击重试'), findsNothing);
    },
  );

  testWidgets('a deterministic mute failure rolls the switch back', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    // A deterministic rejection means the server state is unchanged: roll
    // the switch back and surface the failure.
    rustApi.pendingMutedUpdate = Completer<void>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    rustApi.pendingMutedUpdate!.completeError(StateError('Forbidden'));
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    expect(find.textContaining('通知设置更新失败:'), findsOneWidget);
    expect(find.text('通知设置加载/更新失败，点击重试'), findsOneWidget);
  });

  testWidgets('a stale failing mute read cannot disable a fresh toggle', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Switch), findsOneWidget);

    // A sync cycle starts a muted-state read that will fail.
    rustApi.pendingMutedRead = Completer<void>();
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();

    // The user toggles the switch while that read is in flight.
    rustApi.pendingMutedUpdate = Completer<void>();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    // The stale read fails after the toggle started: its error must not
    // disable the switch the user just toggled successfully. The write is
    // still in flight (saving spinner), so pump bounded frames instead of
    // pumpAndSettle.
    rustApi.failSupplementalLoads = true;
    rustApi.pendingMutedRead!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    // No error tile, no retry button: the toggle owns the switch state.
    expect(find.text('无法加载通知设置'), findsNothing);

    rustApi.pendingMutedUpdate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('已关闭免打扰'), findsOneWidget);
  });

  testWidgets('unignoring a user sends ignored:false and updates the list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    rustApi.failSupplementalLoads = false;
    // Alice is both a member and ignored, so her member tile shows the
    // unignore button.
    rustApi.ignoredUsers = const ['@alice:example.org'];
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          _sessionReadyOverride,
          activeUserIdProvider.overrideWith(
            () => MutableState<String?>('@carol:example.org'),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已忽略用户 (1)'), findsOneWidget);
    expect(find.byTooltip('取消忽略'), findsOneWidget);

    // The server has already dropped the target (cross-device unignore);
    // tapping must send ignored:false for the right user.
    rustApi.ignoredUsers = const [];
    await tester.tap(find.byTooltip('取消忽略'));
    await tester.pump();
    await tester.pump();

    expect(rustApi.ignoredUserId, '@alice:example.org');
    expect(rustApi.ignoredFlag, isFalse);
    expect(find.text('已取消忽略 @alice:example.org'), findsOneWidget);
    expect(find.text('已忽略用户 (0)'), findsOneWidget);
  });

  testWidgets('saving without changes skips the RPC and explains why', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(rustApi.updatedName, isNull);

    await tester.tap(find.byTooltip('保存房间信息'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // No RPC fired and the user is told nothing changed.
    expect(rustApi.updatedName, isNull);
    expect(rustApi.updatedTopicFlag, isNull);
    expect(find.text('没有需要保存的修改'), findsOneWidget);
  });

  testWidgets('a failed members refresh keeps previously loaded members', (
    tester,
  ) async {
    rustApi.failSupplementalLoads = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [_sessionReadyOverride],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: RoomManagementPage(
            roomId: '!room:example.org',
            roomName: 'Project room',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('成员 1'), findsOneWidget);
    expect(find.text('@alice:example.org'), findsOneWidget);

    // A later sync cycle reloads members and fails: the already rendered
    // list must stay visible with an inline error, not vanish behind an
    // error tile.
    rustApi.failSupplementalLoads = true;
    rustApi.syncEvents.add(
      const rust.SyncEvent.roomMembersChanged(roomId: '!room:example.org'),
    );
    // The event-driven member refresh is throttled (500ms), like the
    // knock-list refresh; advance past the throttle before settling.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(find.text('成员 1'), findsNothing); // Title loses the count.
    expect(find.text('@alice:example.org'), findsOneWidget);
    expect(find.text('成员刷新失败，显示缓存数据'), findsOneWidget);
  });
}
