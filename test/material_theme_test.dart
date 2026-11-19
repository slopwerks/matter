import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/providers/chat_visual_settings_provider.dart';
import 'package:matter/providers/theme_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/widgets/neu_field.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:matter/widgets/sheets.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    test('Material $brightness uses ColorScheme roles and readable text', () {
      final theme = buildMaterialTheme(brightness);
      final colors = theme.extension<NeuColors>()!;
      expect(theme.useMaterial3, isTrue);
      expect(colors.isMaterial, isTrue);
      // The page is one step off M3's surface so cards can sit on it: in light
      // mode surface and surfaceBright are both tone 98, so a page on surface
      // left the card indistinguishable from it.
      expect(colors.base, theme.scaffoldBackgroundColor);
      expect(
        colors.base,
        brightness == Brightness.dark
            ? theme.colorScheme.surface
            : theme.colorScheme.surfaceContainer,
      );
      expect(colors.text, theme.colorScheme.onSurface);
      expect(colors.accent, theme.colorScheme.primary);
      expect(
        theme.appBarTheme.titleTextStyle?.color,
        theme.colorScheme.onSurface,
      );
      expect(
        theme.dialogTheme.titleTextStyle?.color,
        theme.colorScheme.onSurface,
      );
      expect(theme.splashFactory, isNot(NoSplash.splashFactory));
      final luminances = [
        colors.accent.computeLuminance(),
        colors.onAccent.computeLuminance(),
      ]..sort();
      expect(
        (luminances.last + .05) / (luminances.first + .05),
        greaterThanOrEqualTo(4.5),
      );
    });
  }

  test(
    'shared colors interpolate with the Material theme instead of jumping',
    () {
      final light = buildMaterialTheme(Brightness.light);
      final dark = buildMaterialTheme(Brightness.dark);
      final start = light.extension<NeuColors>()!;
      final end = dark.extension<NeuColors>()!;
      final middle = ThemeData.lerp(light, dark, .25).extension<NeuColors>()!;
      expect(middle.base, Color.lerp(start.base, end.base, .25));
      expect(middle.card, Color.lerp(start.card, end.card, .25));
      expect(middle.text, Color.lerp(start.text, end.text, .25));
      expect(middle.accent, Color.lerp(start.accent, end.accent, .25));
      expect(middle.glassFill, Color.lerp(start.glassFill, end.glassFill, .25));
      expect(middle.isMaterial, isTrue);
    },
  );

  for (final style in AppThemeStyle.values) {
    test('restores persisted ${style.name}', () async {
      SharedPreferences.setMockInitialValues({'app_theme_style': style.name});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(appThemeStyleProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appThemeStyleProvider), style);
    });
  }

  test('persists Material and allows switching back to neu', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(appThemeStyleProvider);
    await Future<void>.delayed(Duration.zero);
    await container
        .read(appThemeStyleProvider.notifier)
        .setStyle(AppThemeStyle.materialSystem);
    expect(
      (await SharedPreferences.getInstance()).getString('app_theme_style'),
      'materialSystem',
    );
    expect(container.read(appThemeStyleProvider).themeMode, ThemeMode.system);
    await container
        .read(appThemeStyleProvider.notifier)
        .setStyle(AppThemeStyle.neuDark);
    expect(container.read(appThemeStyleProvider).isMaterial, isFalse);
    expect(
      (await SharedPreferences.getInstance()).getString('app_theme_style'),
      'neuDark',
    );
  });

  testWidgets('Material visual settings leave stored neu preferences intact', (
    tester,
  ) async {
    late ChatVisualSettings settings;
    Future<void> pump(ThemeData theme) => tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: ChatVisualSettingsScope(
          settings: const ChatVisualSettings(),
          child: Builder(
            builder: (context) {
              settings = ChatVisualSettingsScope.of(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await pump(buildMaterialTheme(Brightness.light));
    expect(settings.chatBlurEnabled, isFalse);
    expect(settings.bubbleGradientEnabled, isFalse);
    expect(settings.bubbleShadowsEnabled, isFalse);
    expect(settings.superellipseBorderEnabled, isFalse);
    await pump(buildNeuTheme(NeuColors.light, Brightness.light));
    await tester.pumpAndSettle();
    expect(settings.chatBlurEnabled, isTrue);
    expect(settings.bubbleGradientEnabled, isTrue);
    expect(settings.bubbleShadowsEnabled, isTrue);
    expect(settings.superellipseBorderEnabled, isTrue);
  });

  testWidgets('Material buttons and fields support keyboard and touch', (
    tester,
  ) async {
    var taps = 0;
    String? submitted;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              NeuButton(
                accent: true,
                onPressed: () => taps++,
                child: const Text('发送'),
              ),
              NeuTextField(
                hint: '消息',
                onSubmitted: (value) => submitted = value,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    await tester.tap(find.text('发送'));
    expect(taps, 2);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(submitted, 'hello');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Material confirm, prompt and sheet retain return values', (
    tester,
  ) async {
    bool? confirmed;
    String? prompted;
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () async {
                    confirmed = await showNeuConfirm(
                      context,
                      title: '退出',
                      message: '退出账号？',
                    );
                  },
                  child: const Text('确认框'),
                ),
                TextButton(
                  onPressed: () async {
                    prompted = await showNeuPrompt(
                      context,
                      title: '名称',
                      initial: '旧名称',
                    );
                  },
                  child: const Text('输入框'),
                ),
                TextButton(
                  onPressed: () async {
                    selected = await showNeuSheet<String>(
                      context: context,
                      child: Builder(
                        builder: (sheetContext) => NeuSheetItem(
                          icon: Icons.check,
                          label: '选中',
                          onTap: () =>
                              Navigator.of(sheetContext).pop('selected'),
                        ),
                      ),
                    );
                  },
                  child: const Text('弹层'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('确认框'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
    await tester.tap(find.text('输入框'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新名称');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(prompted, '新名称');
    await tester.tap(find.text('弹层'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byType(ListTile), findsOneWidget);
    await tester.tap(find.text('选中'));
    await tester.pumpAndSettle();
    expect(selected, 'selected');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Material bubbles have a solid fill without shadows or gradients',
    (tester) async {
      late ShapeDecoration outgoing;
      late ShapeDecoration incoming;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.dark),
          home: Builder(
            builder: (context) {
              outgoing = neuBubbleDecoration(
                context,
                context.neu,
                isMe: true,
                borderRadius: BorderRadius.circular(18),
              ) as ShapeDecoration;
              incoming = neuBubbleDecoration(
                context,
                context.neu,
                isMe: false,
                borderRadius: BorderRadius.circular(18),
              ) as ShapeDecoration;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        outgoing.color,
        buildMaterialTheme(Brightness.dark).colorScheme.primary,
      );
      expect(incoming.color, isNotNull);
      expect(outgoing.gradient, isNull);
      expect(outgoing.shadows, isEmpty);
      expect(outgoing.shape, isA<RoundedRectangleBorder>());
    },
  );

  testWidgets('reader lays out at narrow width with enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const MessageReaderPage(html: '<p>Hello Material</p>'),
      ),
    );
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('阅读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
