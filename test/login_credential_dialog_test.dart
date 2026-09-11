import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:matter/pages/login/login_page.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets('credential fallback dialog confirms continuing login', (
    tester,
  ) async {
    late Future<bool> result;
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () {
              result = showSessionCredentialCompatibilityDialog(
                context,
                loginAlreadyCompleted: true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('设备安全存储不可用'), findsOneWidget);
    expect(find.textContaining('启用后将继续当前登录'), findsOneWidget);

    await tester.tap(find.text('启用兼容模式'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });
}
