import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/material_adaptive_shell.dart';
import 'package:matter/widgets/material_list_detail.dart';
import 'package:matter/widgets/selected_chat_navigator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      'home FAB return scale is immediate only on Android $platform',
      (tester) async {
        var open = false;
        late StateSetter update;
        final position = ValueNotifier<double>(0);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildMaterialTheme(Brightness.light)
                .copyWith(platform: platform),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return MaterialAdaptiveShell(
                  window: MaterialWindowClass.compact,
                  index: 0,
                  onNavigate: (_) {},
                  position: position,
                  profile: const SizedBox(),
                  railAccount: const SizedBox(),
                  railActions: (_) => const SizedBox(),
                  railSpaces: const SizedBox(),
                  unreadCount: 0,
                  chatOpen: open,
                  dockBlurEnabled: false,
                  floatingActionButton: open
                      ? null
                      : FloatingActionButton(
                          key: const ValueKey('home-fab'),
                          onPressed: () {},
                          child: const Icon(Icons.add),
                        ),
                  pages: const [SizedBox(), SizedBox(), SizedBox(), SizedBox()],
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        update(() => open = true);
        await tester.pumpAndSettle();
        update(() => open = false);
        await tester.pump();
        final scales = tester.widgetList<ScaleTransition>(
          find.ancestor(
            of: find.byKey(const ValueKey('home-fab')),
            matching: find.byType(ScaleTransition),
          ),
        );
        expect(scales, isNotEmpty);
        if (platform == TargetPlatform.android) {
          expect(scales.every((scale) => scale.scale.value == 1), true);
        } else {
          expect(scales.any((scale) => scale.scale.value < 1), true);
        }
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        position.dispose();
      },
    );
  }
  testWidgets(
    'Android home delegates back to system after nested pages close',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final handles = <bool>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            handles.add(call.arguments as bool);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final position = ValueNotifier<double>(0);
      var index = 0;
      String? room;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MaterialAdaptiveShell(
                window: MaterialWindowClass.compact,
                index: index,
                onNavigate: (value) => setState(() => index = value),
                position: position,
                profile: const SizedBox(),
                railAccount: const SizedBox(),
                railActions: (_) => const SizedBox(),
                railSpaces: const SizedBox(),
                unreadCount: 0,
                chatOpen: room != null,
                dockBlurEnabled: false,
                pages: [
                  SelectedChatNavigator(
                    roomId: room,
                    active: index == 0,
                    list: TextButton(
                      onPressed: () => setState(() => room = 'room'),
                      child: const Text('Open chat'),
                    ),
                    detail: const Scaffold(body: Text('Chat')),
                    onChatPopped: () => setState(() => room = null),
                  ),
                  const MaterialListDetail(
                    active: false,
                    list: Text('Spaces'),
                    emptyLabel: 'empty',
                    emptyIcon: Icons.workspaces,
                  ),
                  const MaterialListDetail(
                    active: false,
                    list: Text('Contacts'),
                    emptyLabel: 'empty',
                    emptyIcon: Icons.people,
                  ),
                  MaterialListDetail(
                    active: index == 3,
                    emptyLabel: 'empty',
                    emptyIcon: Icons.settings,
                    list: Builder(
                      builder: (context) => TextButton(
                        child: const Text('Open settings'),
                        onPressed: () => MaterialListDetail.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const Scaffold(body: Text('Settings detail')),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(handles.last, false);
      await tester.tap(find.text('Open chat'));
      await tester.pumpAndSettle();
      expect(handles.last, true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handles.last, false);
      update(() => index = 3);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
      expect(handles.last, true);
      update(() => index = 0);
      await tester.pumpAndSettle();
      expect(
        handles.last,
        false,
        reason: 'inactive settings detail must not own home back',
      );
      update(() => index = 3);
      await tester.pumpAndSettle();
      expect(handles.last, true);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(handles.last, false);
      await tester.pumpWidget(const SizedBox());
      position.dispose();
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
