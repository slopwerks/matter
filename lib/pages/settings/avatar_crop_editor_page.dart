import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../theme/neu_colors.dart';

/// Lightweight square cropper used for profile avatars.
class AvatarCropEditorPage extends StatelessWidget {
  const AvatarCropEditorPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final overlayIconBrightness = dark ? Brightness.light : Brightness.dark;
    final editorTheme = Theme.of(context).copyWith(
      scaffoldBackgroundColor: colors.base,
      colorScheme: Theme.of(context).colorScheme.copyWith(
        primary: colors.accent,
        surface: colors.surfaceStrong,
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
              bottomBarBackground: colors.surfaceStrong,
              bottomBarColor: colors.text,
              cropCornerColor: colors.accent,
              helperLineColor: colors.textTertiary,
              cropOverlayColor: Colors.black,
              uiOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: overlayIconBrightness,
                systemNavigationBarColor: colors.surfaceStrong,
                systemNavigationBarIconBrightness: overlayIconBrightness,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
