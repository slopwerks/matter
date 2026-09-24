import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_visual_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_surface.dart';

class BlurSettingsPage extends ConsumerWidget {
  const BlurSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(chatVisualSettingsProvider);
    final notifier = ref.read(chatVisualSettingsProvider.notifier);
    return Scaffold(
      backgroundColor: context.neu.base,
      appBar: AppBar(
        title: const Text('模糊效果设置'),
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _BlurSection(
            title: '总体效果',
            children: [
              _BlurSwitch(
                title: '启用聊天模糊',
                subtitle: '关闭后使用不透明或渐变表面，完全跳过背景模糊',
                value: settings.chatBlurEnabled,
                onChanged: notifier.setChatBlurEnabled,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _BlurSection(
            title: '渐进式边缘模糊',
            children: [
              _BlurSwitch(
                title: 'GPU 渐进式着色器',
                subtitle: '使用 inspire_blur 的双向 GPU 着色器；关闭后使用原生滤镜',
                value: settings.progressiveBlurShaderEnabled,
                onChanged: notifier.setProgressiveBlurShaderEnabled,
              ),
              _BlurSwitch(
                title: '限制物理模糊半径',
                subtitle: '限制高像素密度设备的采样半径，降低每像素采样次数',
                value: settings.progressiveBlurSigmaCapEnabled,
                onChanged: notifier.setProgressiveBlurSigmaCapEnabled,
              ),
              _BlurSwitch(
                title: '非均匀模糊',
                subtitle: '边缘效果减少横向采样，使用更便宜的各向异性模糊',
                value: settings.progressiveBlurAnisotropicEnabled,
                onChanged: notifier.setProgressiveBlurAnisotropicEnabled,
              ),
              _BlurSwitch(
                title: '精简兼容模式',
                subtitle: '不支持 GPU 着色器时使用 6 个滤镜条带，而不是 16 个',
                value: settings.progressiveBlurReducedFallbackEnabled,
                onChanged: notifier.setProgressiveBlurReducedFallbackEnabled,
              ),
            ],
          ),
          const SizedBox(height: 16),
          _BlurSection(
            title: '其他模糊',
            children: [
              _BlurSwitch(
                title: '轻量图片背景模糊',
                subtitle: '短图片背景使用较小半径，避免重复图片渲染的高采样成本',
                value: settings.imageBlurOptimizationEnabled,
                onChanged: notifier.setImageBlurOptimizationEnabled,
              ),
              _BlurSwitch(
                title: '轻量气泡阴影模糊',
                subtitle: '降低消息气泡阴影半径；不改变阴影开关',
                value: settings.shadowBlurOptimizationEnabled,
                onChanged: notifier.setShadowBlurOptimizationEnabled,
              ),
            ],
          ),
          const SizedBox(height: 16),
          GlassPanel(
            padding: const EdgeInsets.all(16),
            child: Text(
              '普通玻璃面板仍使用 Flutter 原生 ImageFilter.blur。渐进式模糊的固定采样核和降采样由 inspire_blur 0.4.1 内部管理，当前版本没有公开配置接口。',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: context.neu.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BlurSection extends StatelessWidget {
  const _BlurSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              letterSpacing: 1.1,
            ),
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

class _BlurSwitch extends StatelessWidget {
  const _BlurSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.neu.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
