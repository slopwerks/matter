import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/matrix_html/matrix_code_block.dart';
import '../../providers/code_block_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';

const _sampleCode = '''// Matter 代码块展示样例
class MatterClient {
  final String serverUrl;
  const MatterClient({required this.serverUrl});

  Future<void> connect() async {
    print("Connecting to \$serverUrl...");
  }
}''';

class CodeBlockSettingsPage extends ConsumerStatefulWidget {
  const CodeBlockSettingsPage({super.key});

  @override
  ConsumerState<CodeBlockSettingsPage> createState() =>
      _CodeBlockSettingsPageState();
}

class _CodeBlockSettingsPageState extends ConsumerState<CodeBlockSettingsPage> {
  // 0: 跟随系统, 1: 浅色预览, 2: 深色预览
  int _previewMode = 0;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(codeBlockSettingsProvider);
    final notifier = ref.read(codeBlockSettingsProvider.notifier);
    final colors = context.neu;
    final systemIsDark = Theme.of(context).brightness == Brightness.dark;

    final isPreviewDark = switch (_previewMode) {
      1 => false,
      2 => true,
      _ => systemIsDark,
    };

    final previewBubbleColor = isPreviewDark
        ? const Color(0xFF5577C2) // 暗色模式下的发送气泡强调色
        : const Color(0xFFD6E3FF); // 浅色模式下的浅色底

    final previewTextColor = isPreviewDark
        ? Colors.white
        : const Color(0xFF1F2937);

    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('代码块设置')),
      body: MaxContentWidth(
        maxWidth: 600,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            // 实时预览区域
            _SectionHeader(
              title: '效果实时预览',
              icon: Icons.preview_rounded,
              trailing: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('系统')),
                  ButtonSegment(value: 1, label: Text('浅色')),
                  ButtonSegment(value: 2, label: Text('深色')),
                ],
                selected: {_previewMode},
                onSelectionChanged: (set) {
                  setState(() => _previewMode = set.first);
                },
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: previewBubbleColor,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isPreviewDark ? '模拟深色消息气泡' : '模拟浅色消息气泡',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: previewTextColor.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  MatrixCodeBlock(
                    code: _sampleCode,
                    language: 'dart',
                    width: double.infinity,
                    baseStyle: TextStyle(fontSize: 13, color: previewTextColor),
                    accentColor: colors.accent,
                    settingsOverride: settings,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // 透明度控制
            const _SectionHeader(title: '背景透明度', icon: Icons.opacity_rounded),
            const SizedBox(height: 8),
            GroupedRows(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            '卡片不透明度',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            '${(settings.opacity * 100).round()}%',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: colors.accent,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '100% 为实体高对比卡片，调低可透出底层气泡颜色',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Slider(
                        value: settings.opacity,
                        min: 0.1,
                        max: 1.0,
                        divisions: 18,
                        label: '${(settings.opacity * 100).round()}%',
                        onChanged: (val) => notifier.setOpacity(val),
                      ),
                    ],
                  ),
                ),
                SwitchListTile.adaptive(
                  title: const Text('代码行号', style: TextStyle(fontSize: 15)),
                  subtitle: Text(
                    '多行代码左侧显示行号',
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  value: settings.showLineNumbers,
                  onChanged: (val) => notifier.setShowLineNumbers(val),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 暗色模式高亮主题
            const _SectionHeader(
              title: '暗色模式高亮主题',
              icon: Icons.dark_mode_rounded,
            ),
            const SizedBox(height: 8),
            GroupedRows(
              children: [
                RadioGroup<String>(
                  groupValue: settings.darkTheme,
                  onChanged: (val) {
                    if (val != null) notifier.setDarkTheme(val);
                  },
                  child: Column(
                    children: darkCodeThemes.values.map((theme) {
                      final isSelected = settings.darkTheme == theme.id;
                      return RadioListTile<String>.adaptive(
                        title: Text(
                          theme.name,
                          style: const TextStyle(fontSize: 15),
                        ),
                        subtitle: Row(
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: theme.backgroundColor,
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                  color: Colors.white24,
                                  width: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              theme.id,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        value: theme.id,
                        secondary: isSelected
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: colors.accent,
                              )
                            : null,
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // 浅色模式高亮主题
            const _SectionHeader(
              title: '浅色模式高亮主题',
              icon: Icons.light_mode_rounded,
            ),
            const SizedBox(height: 8),
            GroupedRows(
              children: [
                RadioGroup<String>(
                  groupValue: settings.lightTheme,
                  onChanged: (val) {
                    if (val != null) notifier.setLightTheme(val);
                  },
                  child: Column(
                    children: lightCodeThemes.values.map((theme) {
                      final isSelected = settings.lightTheme == theme.id;
                      return RadioListTile<String>.adaptive(
                        title: Text(
                          theme.name,
                          style: const TextStyle(fontSize: 15),
                        ),
                        subtitle: Row(
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: theme.backgroundColor,
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(
                                  color: Colors.black12,
                                  width: 1,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              theme.id,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        value: theme.id,
                        secondary: isSelected
                            ? Icon(
                                Icons.check_circle_rounded,
                                color: colors.accent,
                              )
                            : null,
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget? trailing;

  const _SectionHeader({
    required this.title,
    required this.icon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: context.neu.accent),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}
