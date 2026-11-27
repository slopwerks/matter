import 'package:material_ui/material_ui.dart';

/// A body selected explicitly from the message menu, not by a text gesture.
class MenuTextSelectionArea extends StatefulWidget {
  const MenuTextSelectionArea({super.key, required this.child});

  final Widget child;

  @override
  State<MenuTextSelectionArea> createState() => _MenuTextSelectionAreaState();
}

class _MenuTextSelectionAreaState extends State<MenuTextSelectionArea> {
  final _area = GlobalKey<SelectionAreaState>();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _selectBody();
  }

  Future<void> _selectBody() async {
    // Text.rich adds a nested selection container. Let its queued registrar
    // updates propagate to the outer region before sending select-all.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    _focus.requestFocus();
    // Keyboard select-all alone does not open the adjustable handles.
    _area.currentState!.selectableRegion.selectAll(
      SelectionChangedCause.toolbar,
    );
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionArea(key: _area, focusNode: _focus, child: widget.child);
}
