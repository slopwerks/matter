import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../features/fonts/system_font_catalog.dart';
import '../../features/matrix_html/matrix_code_block.dart';
import '../../providers/app_font_provider.dart';
import '../../theme/neu_colors.dart';
import '../../theme/tokens/app_typography.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

const _previewCodeSnippet = '''// 0O 1lI != => 等宽清晰度示例
final greeting = "Hello, Matter!";''';

/// 独立字体与排版设置页面，管理界面字体、聊天正文字体、等宽字体、回退字体与字号缩放。
class FontSettingsPage extends ConsumerWidget {
  const FontSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiFont = ref.watch(appFontProvider);
    final chatFont = ref.watch(chatFontProvider);
    final monoFont = ref.watch(monospaceFontProvider);
    final fallbackFont = ref.watch(fallbackFontProvider);
    final scales = ref.watch(fontScaleSettingsProvider);

    final isAllDefault =
        uiFont == null &&
        chatFont == null &&
        monoFont is BundledFontChoice &&
        fallbackFont == null &&
        scales.isDefault;

    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('字体与排版')),
      body: MaxContentWidth(
        maxWidth: context.isMaterial ? 720 : double.infinity,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.viewPaddingOf(context).top + kToolbarHeight + 8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            const _FontPreviewSection(),
            const SizedBox(height: 16),
            _FontSection(
              title: '字体选择',
              icon: Icons.text_fields_rounded,
              children: [
                _FontRoleRow(
                  icon: Icons.text_fields_rounded,
                  title: '界面字体',
                  subtitle: _describeUiFont(uiFont),
                  onTap: () => _pickUiFont(context, ref),
                ),
                _FontRoleRow(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: '聊天正文字体',
                  subtitle: _describeChatFont(chatFont),
                  onTap: () => _pickChatFont(context, ref),
                ),
                _FontRoleRow(
                  icon: Icons.code_rounded,
                  title: '等宽字体',
                  subtitle: _describeMonoFont(monoFont),
                  onTap: () => _pickMonoFont(context, ref),
                ),
                _FontRoleRow(
                  icon: Icons.layers_outlined,
                  title: '回退字体',
                  subtitle: _describeFallbackFont(fallbackFont),
                  onTap: () => _pickFallbackFont(context, ref),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _FontSection(
              title: '字号缩放',
              icon: Icons.format_size_rounded,
              children: [
                _FontScaleRow(
                  title: '界面字号',
                  subtitle: '标题、列表、菜单与输入控件整体缩放',
                  value: scales.uiScale,
                  min: kMinUiFontScale,
                  max: kMaxUiFontScale,
                  divisions: 9,
                  onChanged: (v) => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setUiScale(v),
                  onReset: () => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setUiScale(1.0),
                ),
                _FontScaleRow(
                  title: '聊天正文字号',
                  subtitle: '独立调节聊天气泡内消息文字大小',
                  value: scales.chatScale,
                  min: kMinContentFontScale,
                  max: kMaxContentFontScale,
                  divisions: 11,
                  onChanged: (v) => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setChatScale(v),
                  onReset: () => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setChatScale(1.0),
                ),
                _FontScaleRow(
                  title: '等宽与代码字号',
                  subtitle: '代码块、行内代码、日志与密钥显示大小',
                  value: scales.monoScale,
                  min: kMinContentFontScale,
                  max: kMaxContentFontScale,
                  divisions: 11,
                  onChanged: (v) => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setMonoScale(v),
                  onReset: () => ref
                      .read(fontScaleSettingsProvider.notifier)
                      .setMonoScale(1.0),
                ),
              ],
            ),
            const SizedBox(height: 20),
            _ResetFontsButton(
              enabled: !isAllDefault,
              onPressed: () async {
                await Future.wait([
                  ref.read(appFontProvider.notifier).reset(),
                  ref.read(chatFontProvider.notifier).reset(),
                  ref.read(monospaceFontProvider.notifier).reset(),
                  ref.read(fallbackFontProvider.notifier).reset(),
                  ref.read(fontScaleSettingsProvider.notifier).reset(),
                ]);
                if (context.mounted) {
                  neuToast(context, '已恢复默认字体设置');
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

String _describeUiFont(FontChoice? choice) => switch (choice) {
  PickedFontChoice(:final name) => '本地文件 · $name',
  SystemFontChoice(:final family) => '系统字体 · $family',
  BundledFontChoice(:final name) => '内置 · $name',
  PlatformDefaultFontChoice() || null => '跟随系统',
};

String _describeChatFont(FontChoice? choice) => switch (choice) {
  null => '跟随界面字体',
  PlatformDefaultFontChoice() => '跟随系统默认',
  SystemFontChoice(:final family) => '系统字体 · $family',
  PickedFontChoice(:final name) => '本地文件 · $name',
  BundledFontChoice(:final name) => '内置 · $name',
};

String _describeMonoFont(FontChoice? choice) => switch (choice) {
  BundledFontChoice(:final name) => '内置 · $name',
  SystemFontChoice(:final family) => '系统字体 · $family',
  PickedFontChoice(:final name) => '本地文件 · $name',
  PlatformDefaultFontChoice() || null => '跟随系统 (monospace)',
};

String _describeFallbackFont(FallbackChoice? choice) => switch (choice) {
  null => '跟随系统（已保留 Emoji 回退）',
  FamilyFallback(:final family) => '系统字体 · $family（含 Emoji 回退）',
  FileFallback(:final name) => '本地文件 · $name（含 Emoji 回退）',
};

Future<void> _pickUiFont(BuildContext context, WidgetRef ref) async {
  final current = ref.read(appFontProvider);
  final catalog = await ref.read(systemFontCatalogProvider.future);
  if (!context.mounted) return;
  final action = await showNeuSheet<String>(
    context: context,
    child: Builder(
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: current == null
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: '跟随系统',
            onTap: () => Navigator.pop(sheet, 'system'),
          ),
          if (catalog.families.isNotEmpty)
            NeuSheetItem(
              icon: Icons.font_download_outlined,
              label: '选择系统字体',
              onTap: () => Navigator.pop(sheet, 'families'),
            ),
          NeuSheetItem(
            icon: Icons.folder_open_rounded,
            label: current is PickedFontChoice ? '更换本地字体文件' : '选择本地字体文件',
            onTap: () => Navigator.pop(sheet, 'file'),
          ),
          if (current != null)
            NeuSheetItem(
              icon: Icons.delete_outline_rounded,
              label: '恢复跟随系统',
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  final notifier = ref.read(appFontProvider.notifier);
  switch (action) {
    case 'system':
    case 'remove':
      await notifier.reset();
    case 'families':
      final active = switch (current) {
        SystemFontChoice(:final family) => family,
        _ => null,
      };
      final family = await _showSystemFontPicker(
        context,
        catalog,
        active: active,
      );
      if (family != null) await notifier.selectSystemFamily(family);
    case 'file':
      final picked = await notifier.pickFile();
      if (context.mounted) {
        neuToast(context, picked ? '界面字体已更新' : '未读取到可用字体文件');
      }
  }
}

Future<void> _pickChatFont(BuildContext context, WidgetRef ref) async {
  final current = ref.read(chatFontProvider);
  final catalog = await ref.read(systemFontCatalogProvider.future);
  if (!context.mounted) return;
  final action = await showNeuSheet<String>(
    context: context,
    child: Builder(
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: current == null
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: '跟随界面字体',
            onTap: () => Navigator.pop(sheet, 'follow_ui'),
          ),
          NeuSheetItem(
            icon: current is PlatformDefaultFontChoice
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: '跟随系统默认',
            onTap: () => Navigator.pop(sheet, 'system_default'),
          ),
          if (catalog.families.isNotEmpty)
            NeuSheetItem(
              icon: Icons.font_download_outlined,
              label: '选择系统字体',
              onTap: () => Navigator.pop(sheet, 'families'),
            ),
          NeuSheetItem(
            icon: Icons.folder_open_rounded,
            label: current is PickedFontChoice ? '更换本地字体文件' : '选择本地字体文件',
            onTap: () => Navigator.pop(sheet, 'file'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  final notifier = ref.read(chatFontProvider.notifier);
  switch (action) {
    case 'follow_ui':
      await notifier.reset();
    case 'system_default':
      await notifier.selectPlatformDefault();
    case 'families':
      final active = switch (current) {
        SystemFontChoice(:final family) => family,
        _ => null,
      };
      final family = await _showSystemFontPicker(
        context,
        catalog,
        active: active,
      );
      if (family != null) await notifier.selectSystemFamily(family);
    case 'file':
      final picked = await notifier.pickFile();
      if (context.mounted) {
        neuToast(context, picked ? '聊天正文字体已更新' : '未读取到可用字体文件');
      }
  }
}

Future<void> _pickMonoFont(BuildContext context, WidgetRef ref) async {
  final current = ref.read(monospaceFontProvider);
  final catalog = await ref.read(systemFontCatalogProvider.future);
  if (!context.mounted) return;
  final action = await showNeuSheet<String>(
    context: context,
    child: Builder(
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: current is BundledFontChoice
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: 'Ioskeley Mono（内置）',
            onTap: () => Navigator.pop(sheet, 'bundled'),
          ),
          NeuSheetItem(
            icon: current is PlatformDefaultFontChoice || current == null
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: '跟随系统 (monospace)',
            onTap: () => Navigator.pop(sheet, 'system_default'),
          ),
          if (catalog.families.isNotEmpty)
            NeuSheetItem(
              icon: Icons.font_download_outlined,
              label: '选择系统字体',
              onTap: () => Navigator.pop(sheet, 'families'),
            ),
          NeuSheetItem(
            icon: Icons.folder_open_rounded,
            label: current is PickedFontChoice ? '更换本地字体文件' : '选择本地字体文件',
            onTap: () => Navigator.pop(sheet, 'file'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  final notifier = ref.read(monospaceFontProvider.notifier);
  switch (action) {
    case 'bundled':
      await notifier.selectBundled();
    case 'system_default':
      await notifier.selectPlatformDefault();
    case 'families':
      final active = switch (current) {
        SystemFontChoice(:final family) => family,
        _ => null,
      };
      final family = await _showSystemFontPicker(
        context,
        catalog,
        active: active,
        preferMonospace: true,
      );
      if (family != null) await notifier.selectSystemFamily(family);
    case 'file':
      final picked = await notifier.pickFile();
      if (context.mounted) {
        neuToast(context, picked ? '等宽字体已更新' : '未读取到可用字体文件');
      }
  }
}

Future<void> _pickFallbackFont(BuildContext context, WidgetRef ref) async {
  final current = ref.read(fallbackFontProvider);
  final catalog = await ref.read(systemFontCatalogProvider.future);
  if (!context.mounted) return;
  final action = await showNeuSheet<String>(
    context: context,
    child: Builder(
      builder: (sheet) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          NeuSheetItem(
            icon: current == null
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
            label: '跟随系统',
            onTap: () => Navigator.pop(sheet, 'system'),
          ),
          if (catalog.families.isNotEmpty)
            NeuSheetItem(
              icon: Icons.font_download_outlined,
              label: '选择系统字体',
              onTap: () => Navigator.pop(sheet, 'families'),
            ),
          NeuSheetItem(
            icon: Icons.folder_open_rounded,
            label: switch (current) {
              FileFallback(:final name) => '更换本地字体文件（$name）',
              _ => '选择本地字体文件',
            },
            onTap: () => Navigator.pop(sheet, 'file'),
          ),
          if (current != null)
            NeuSheetItem(
              icon: Icons.delete_outline_rounded,
              label: '移除自定义回退字体',
              onTap: () => Navigator.pop(sheet, 'remove'),
            ),
        ],
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  final notifier = ref.read(fallbackFontProvider.notifier);
  switch (action) {
    case 'system':
    case 'remove':
      await notifier.reset();
    case 'families':
      final active = switch (current) {
        FamilyFallback(:final family) => family,
        _ => null,
      };
      final family = await _showSystemFontPicker(
        context,
        catalog,
        active: active,
      );
      if (family != null) await notifier.selectFamily(family);
    case 'file':
      final picked = await notifier.pickFile();
      if (context.mounted) {
        neuToast(context, picked ? '回退字体已更新' : '未读取到可用字体文件');
      }
  }
}

Future<String?> _showSystemFontPicker(
  BuildContext context,
  SystemFontCatalog catalog, {
  String? active,
  bool preferMonospace = false,
}) {
  return showNeuSheet<String>(
    context: context,
    child: _SystemFontPickerSheet(
      catalog: catalog,
      active: active,
      preferMonospace: preferMonospace,
    ),
  );
}

class _SystemFontPickerSheet extends StatefulWidget {
  const _SystemFontPickerSheet({
    required this.catalog,
    this.active,
    this.preferMonospace = false,
  });

  final SystemFontCatalog catalog;
  final String? active;
  final bool preferMonospace;

  @override
  State<_SystemFontPickerSheet> createState() => _SystemFontPickerSheetState();
}

class _SystemFontPickerSheetState extends State<_SystemFontPickerSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  late bool _monoOnly =
      widget.preferMonospace && widget.catalog.monospaceFamilies.isNotEmpty;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final source = _monoOnly
        ? widget.catalog.families
              .where(widget.catalog.monospaceFamilies.contains)
              .toList()
        : widget.catalog.families;
    final filtered = query.isEmpty
        ? source
        : source.where((f) => f.toLowerCase().contains(query)).toList();

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 460),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索系统字体（共 ${source.length} 个）',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (widget.catalog.monospaceFamilies.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Row(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: Text('全部 (${widget.catalog.families.length})'),
                    selected: !_monoOnly,
                    onSelected: (_) => setState(() => _monoOnly = false),
                  ),
                  ChoiceChip(
                    label: Text(
                      '等宽 (${widget.catalog.monospaceFamilies.length})',
                    ),
                    selected: _monoOnly,
                    onSelected: (_) => setState(() => _monoOnly = true),
                  ),
                ],
              ),
            ),
          Flexible(
            child: filtered.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 28),
                    child: Text(
                      '没有匹配的系统字体',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final family = filtered[index];
                      final isSelected = family == widget.active;
                      final isMono = widget.catalog.monospaceFamilies.contains(
                        family,
                      );
                      final baseStyle = Theme.of(context).textTheme.bodyLarge;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 20,
                          color: isSelected
                              ? context.neu.accent
                              : context.neu.textSecondary,
                        ),
                        title: Text(
                          family,
                          style: baseStyle?.copyWith(
                            fontFamily: family,
                            fontFamilyFallback: baseStyle.fontFamilyFallback,
                          ),
                        ),
                        trailing: isMono
                            ? Text(
                                'Mono',
                                style: Theme.of(context).textTheme.labelSmall
                                    ?.copyWith(color: context.neu.textTertiary),
                              )
                            : null,
                        onTap: () => Navigator.pop(context, family),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FontPreviewSection extends StatelessWidget {
  const _FontPreviewSection();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.neu;
    final typography = AppTypography.maybeOf(context);
    final chatStyle = (typography?.chatBody ?? theme.textTheme.bodyLarge!)
        .copyWith(color: colors.text);
    final inlineCodeStyle = AppTypography.monospaceOf(
      context,
      base: chatStyle,
      backgroundColor: colors.text.withValues(alpha: 0.1),
    );

    final previewBody = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('界面排版预览 · AaBbCc 123456', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('界面标题、设置列表和次要说明跟随界面字体与界面字号缩放。', style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: context.isMaterial
                ? theme.colorScheme.surfaceContainerHigh
                : colors.surfaceStrong,
            borderRadius: BorderRadius.circular(context.isMaterial ? 16 : 14),
          ),
          child: Text.rich(
            TextSpan(
              style: chatStyle,
              children: [
                const TextSpan(text: '聊天气泡正文：支持中英文混排、'),
                TextSpan(text: 'const count = 42', style: inlineCodeStyle),
                const TextSpan(text: ' 与表情回退 ✨🎉。'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        MatrixCodeBlock(
          code: _previewCodeSnippet,
          language: 'dart',
          width: double.infinity,
          baseStyle: TextStyle(fontSize: 13, color: colors.text),
          accentColor: colors.accent,
        ),
      ],
    );

    if (context.isMaterial) {
      return MaterialDetailCard(
        title: '效果实时预览',
        description: '界面、聊天气泡与代码块会随下方设置实时更新。',
        child: previewBody,
      );
    }
    return _FontSection(
      title: '效果实时预览',
      icon: Icons.preview_rounded,
      children: [
        Padding(padding: const EdgeInsets.all(14), child: previewBody),
      ],
    );
  }
}

class _FontSection extends StatelessWidget {
  const _FontSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (context.isMaterial) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              spacing: 8,
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          GroupedRows(
            dividerIndent: NeuSpacing.rowTitleInset,
            children: children,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: [
              Icon(icon, size: 18, color: context.neu.accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.1,
                ),
              ),
            ],
          ),
        ),
        NeuSurface(
          color: context.neu.card,
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
                    color: context.neu.hairline,
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

class _FontRoleRow extends StatelessWidget {
  const _FontRoleRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.unfold_more_rounded, size: 20),
        onTap: onTap,
      );
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: context.neu.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: context.neu.textSecondary),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.unfold_more_rounded,
              size: 18,
              color: context.neu.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _FontScaleRow extends StatelessWidget {
  const _FontScaleRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
    required this.onReset,
  });

  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.neu;
    final pct = '${(value * 100).round()}%';
    final isDefault = (value - 1.0).abs() < 0.001;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (!isDefault)
                IconButton(
                  tooltip: '重置为 100%',
                  visualDensity: VisualDensity.compact,
                  onPressed: onReset,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                ),
              Text(
                pct,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: isDefault ? colors.textSecondary : colors.accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: pct,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _ResetFontsButton extends StatelessWidget {
  const _ResetFontsButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return Align(
        alignment: AlignmentDirectional.centerEnd,
        child: OutlinedButton.icon(
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.restore_rounded, size: 18),
          label: const Text('恢复默认字体设置'),
        ),
      );
    }
    return NeuButton(
      padding: const EdgeInsets.symmetric(vertical: 12),
      icon: const Icon(Icons.restore_rounded, size: 18),
      onPressed: enabled ? onPressed : null,
      child: const Center(child: Text('恢复默认字体设置')),
    );
  }
}
