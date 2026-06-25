import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import '../../theme/app_theme.dart';

/// Lightweight square cropper used for profile avatars.
class AvatarCropEditorPage extends StatelessWidget {
  const AvatarCropEditorPage({super.key, required this.imageBytes});

  final Uint8List imageBytes;

  @override
  Widget build(BuildContext context) {
    final editorTheme = Theme.of(context).copyWith(
      scaffoldBackgroundColor: AppColors.background,
      colorScheme: Theme.of(context).colorScheme.copyWith(
        primary: AppColors.primary,
        surface: AppColors.surface,
        onSurface: AppColors.onBackground,
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
          cropRotateEditor: const CropRotateEditorConfigs(
            tools: [CropRotateTool.rotate, CropRotateTool.reset],
            initAspectRatio: 1,
            maxScale: 6,
            style: CropRotateEditorStyle(
              appBarBackground: AppColors.background,
              appBarColor: AppColors.onBackground,
              background: AppColors.background,
              bottomBarBackground: AppColors.surface,
              bottomBarColor: AppColors.onBackground,
              cropCornerColor: AppColors.primary,
              helperLineColor: Colors.white54,
              cropOverlayColor: Colors.black,
              uiOverlayStyle: SystemUiOverlayStyle(
                statusBarColor: Colors.transparent,
                statusBarIconBrightness: Brightness.light,
                systemNavigationBarColor: AppColors.surface,
                systemNavigationBarIconBrightness: Brightness.light,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
