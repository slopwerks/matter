import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';

/// A non-interactive hover card; Tooltip owns delay, placement and disposal.
class DesktopPickerPreview extends StatelessWidget {
  const DesktopPickerPreview({
    super.key,
    required this.preview,
    required this.name,
    required this.details,
    required this.child,
  });

  final Widget preview;
  final String name;
  final String details;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final style = desktopPickerPreviewStyle(context);
    return Tooltip(
      waitDuration: const Duration(milliseconds: 450),
      exitDuration: const Duration(milliseconds: 100),
      preferBelow: false,
      ignorePointer: true,
      excludeFromSemantics: true,
      decoration: style.decoration,
      padding: style.padding,
      richMessage: WidgetSpan(
        child: SizedBox(
          width: 180,
          child: DefaultTextStyle(
            style: style.details,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 112,
                  width: 140,
                  child: Center(child: preview),
                ),
                Text(
                  name,
                  style: style.name,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  details,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
      child: child,
    );
  }
}
