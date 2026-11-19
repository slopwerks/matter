import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/floating_date_header.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  testWidgets(
    'does not inspect separator geometry while sliver children are moving',
    (tester) async {
      final controller = ScrollController();
      final viewportKey = GlobalKey();
      final firstSeparatorKey = GlobalKey();
      final secondSeparatorKey = GlobalKey();
      final insertedSeparatorKey = GlobalKey();
      addTearDown(controller.dispose);

      Widget buildTimeline(List<GlobalKey> separatorKeys) {
        return MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: Stack(
              children: [
                CustomScrollView(
                  key: viewportKey,
                  controller: controller,
                  slivers: [
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) =>
                            SizedBox(key: separatorKeys[index], height: 400),
                        childCount: separatorKeys.length,
                        findChildIndexCallback: (key) {
                          final index = separatorKeys.indexWhere(
                            (separatorKey) => separatorKey == key,
                          );
                          return index == -1 ? null : index;
                        },
                      ),
                    ),
                  ],
                ),
                FloatingDateHeader(
                  scrollController: controller,
                  scrollViewportKey: viewportKey,
                  boundaries: List.generate(
                    separatorKeys.length,
                    (index) => DateBoundary(
                      label: 'day $index',
                      leadingTimestamp: '$index',
                    ),
                  ),
                  separatorKeys: separatorKeys,
                ),
              ],
            ),
          ),
        );
      }

      await tester.pumpWidget(
        buildTimeline([firstSeparatorKey, secondSeparatorKey]),
      );
      await tester.pump();

      await tester.pumpWidget(
        buildTimeline([
          insertedSeparatorKey,
          firstSeparatorKey,
          secondSeparatorKey,
        ]),
      );

      expect(tester.takeException(), isNull);
    },
  );
}
