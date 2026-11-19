import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/widgets/mobile_tab_view.dart';

import '../helpers/neu_test_theme.dart';

const _searchKey = ValueKey('contacts-search-entry');
const _headerKey = ValueKey('contacts-header-search-entry');

List<Contact> _contacts() => [
  const Contact(id: '@bob:example.org', name: 'Bob', status: 'offline'),
  for (var i = 0; i < 40; i++)
    Contact(id: '@alice$i:example.org', name: 'Alice $i', status: 'online'),
];

Future<void> _pumpPage(
  WidgetTester tester,
  ProviderContainer container,
  bool material, {
  Widget home = const ContactsPage(),
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: neuTestTheme(material: material),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

double _searchOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .ancestor(
            of: find.byKey(_searchKey, skipOffstage: false),
            matching: find.byType(Opacity, skipOffstage: false),
          )
          .first,
    )
    .opacity;

void main() {
  for (final material in [false, true]) {
    final style = material ? 'Material' : 'Neu';
    testWidgets(
      '$style contacts search fades into a header button that restores focus',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            contactsProvider.overrideWith((ref) async => _contacts()),
          ],
        );
        addTearDown(container.dispose);
        await _pumpPage(tester, container, material);
        expect(find.byKey(_headerKey), findsNothing);
        expect(_searchOpacity(tester), 1);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -28));
        await tester.pump();
        expect(find.byKey(_headerKey), findsNothing);
        expect(_searchOpacity(tester), inExclusiveRange(0, 1));
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -180));
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsOneWidget);
        expect(_searchOpacity(tester), 0);
        await tester.tap(find.byKey(_headerKey));
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsNothing);
        expect(_searchOpacity(tester), 1);
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .pixels,
          0,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$style contacts retains the query and filtering after collapsing search',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            contactsProvider.overrideWith((ref) async => _contacts()),
          ],
        );
        addTearDown(container.dispose);
        await _pumpPage(tester, container, material);
        expect(find.text('Bob'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'AlIcE');
        await tester.pumpAndSettle();
        expect(find.text('Bob'), findsNothing);
        expect(find.text('Alice 0'), findsOneWidget);
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -1200),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField, skipOffstage: false))
              .focusNode!
              .hasFocus,
          isFalse,
        );
        await tester.tap(find.byKey(_headerKey));
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, 'AlIcE');
        expect(field.focusNode!.hasFocus, isTrue);
        expect(find.text('Bob'), findsNothing);
        expect(find.text('Alice 0'), findsOneWidget);
        // Status filtering and clearing still use the existing instant search.
        await tester.enterText(find.byType(TextField), 'offline');
        await tester.pumpAndSettle();
        expect(find.text('Bob'), findsOneWidget);
        expect(find.text('Alice 0'), findsNothing);
        await tester.enterText(find.byType(TextField), '');
        await tester.pumpAndSettle();
        expect(find.text('Alice 0'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '$style contacts restores search after refreshing the list while away',
      (tester) async {
        var contacts = _contacts();
        final container = ProviderContainer(
          overrides: [contactsProvider.overrideWith((ref) async => contacts)],
        );
        addTearDown(container.dispose);
        final tab = ValueNotifier(0);
        final position = ValueNotifier(0.0);
        addTearDown(tab.dispose);
        addTearDown(position.dispose);
        await _pumpPage(
          tester,
          container,
          material,
          home: ValueListenableBuilder<int>(
            valueListenable: tab,
            builder: (context, index, _) => MobileTabView(
              index: index,
              position: position,
              onChanged: (value) => tab.value = value,
              children: const [ContactsPage(), SizedBox.expand()],
            ),
          ),
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(find.byKey(_headerKey), findsOneWidget);
        tab.value = 1;
        await tester.pumpAndSettle();
        contacts = [];
        container.invalidate(contactsProvider);
        await tester.pumpAndSettle();
        tab.value = 0;
        await tester.pumpAndSettle();
        expect(find.text('暂无联系人'), findsOneWidget);
        expect(find.byKey(_headerKey), findsNothing);
        expect(_searchOpacity(tester), 1);
        contacts = _contacts();
        container.invalidate(contactsProvider);
        await tester.pumpAndSettle();
        expect(find.text('Bob'), findsOneWidget);
        expect(_searchOpacity(tester), 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
