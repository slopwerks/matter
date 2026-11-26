import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../theme/image_editor_theme.dart';

/// Lightweight square cropper used for profile avatars.
class AvatarCropEditorPage extends StatelessWidget {
  const AvatarCropEditorPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context) {
    final neu = context.neu;
    final colors = context.isMaterial
        ? materialMediaChromeStyle(Theme.of(context))
        : (
            base: neu.base,
            surface: neu.surfaceStrong,
            text: neu.text,
            textSecondary: neu.textTertiary,
            accent: neu.accent,
          );
    final dark = Theme.of(context).brightness == Brightness.dark;
    final overlayIconBrightness = dark ? Brightness.light : Brightness.dark;
    final editorTheme = context.isMaterial
        ? buildMaterialImageEditorTheme(Theme.of(context))
        : materialEditorThemeFrom(
            Theme.of(context),
            scaffoldBackgroundColor: colors.base,
            colorScheme: ColorScheme.fromSeed(
              seedColor: colors.accent,
              brightness: Theme.of(context).brightness,
              primary: colors.accent,
              surface: colors.surface,
              onSurface: colors.text,
            ),
          );

    return CropRotateEditor.memory(
      imageBytes,
      initConfigs: CropRotateEditorInitConfigs(
        theme: editorTheme,
        convertToUint8List: true,
        enableCloseButton: true,
        callbacks: ProImageEditorCallbacks(
          onImageEditingComplete: (bytes) async {
            if (context.mounted) Navigator.of(context).pop(bytes);
          },
        ),
        configs: ProImageEditorConfigs(
          theme: editorTheme,
          i18n: const I18n(
            undo: '撤销',
            redo: '重做',
            done: '使用',
            doneLoadingMsg: '正在生成头像…',
            cropRotateEditor: I18nCropRotateEditor(
              bottomNavigationBarText: '裁切',
              rotate: '旋转',
              reset: '重置',
              back: '取消',
              done: '使用',
              undo: '撤销',
              redo: '重做',
            ),
          ),
          imageGeneration: const ImageGenerationConfigs(
            enableUseOriginalBytes: false,
            jpegQuality: 90,
            maxOutputSize: Size(1024, 1024),
            outputFormat: OutputFormat.jpg,
          ),
          cropRotateEditor: CropRotateEditorConfigs(
            tools: const [CropRotateTool.rotate, CropRotateTool.reset],
            initAspectRatio: 1,
            maxScale: 6,
            style: CropRotateEditorStyle(
              appBarBackground: colors.base,
              appBarColor: colors.text,
              background: colors.base,
              bottomBarBackground: colors.surface,
              bottomBarColor: colors.text,
              cropCornerColor: colors.accent,
              helperLineColor: colors.textSecondary,
              cropOverlayColor: Colors.black,
              uiOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: overlayIconBrightness,
                systemNavigationBarColor: colors.surface,
                systemNavigationBarIconBrightness: overlayIconBrightness,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
