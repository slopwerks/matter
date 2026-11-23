part of 'space_detail_page.dart';

enum _SpaceField {
  name('空间名称'),
  topic('空间话题');

  const _SpaceField(this.label);
  final String label;
}

class _SpaceFieldEditor extends StatefulWidget {
  const _SpaceFieldEditor({
    required this.field,
    required this.initialValue,
    required this.save,
  });
  final _SpaceField field;
  final String initialValue;
  final Future<void> Function(String value) save;

  @override
  State<_SpaceFieldEditor> createState() => _SpaceFieldEditorState();
}

class _SpaceFieldEditorState extends State<_SpaceFieldEditor> {
  late final _controller = TextEditingController(text: widget.initialValue);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving) return;
    final value = _controller.text.trim();
    if (widget.field == _SpaceField.name && value.isEmpty) {
      setState(() => _error = '空间名称不能为空');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.save(value);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact =
        MaterialWindowClass.fromWidth(MediaQuery.sizeOf(context).width) ==
        MaterialWindowClass.compact;
    final label = widget.field.label;
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(NeuRadius.button),
      borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
    );
    final form = SingleChildScrollView(
      padding: const EdgeInsets.all(NeuSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('修改$label', style: theme.textTheme.titleLarge),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _saving ? null : () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const SizedBox(height: NeuSpacing.lg),
          TextField(
            controller: _controller,
            autofocus: true,
            readOnly: _saving,
            minLines: 1,
            maxLines: widget.field == _SpaceField.topic ? 4 : 1,
            decoration: InputDecoration(
              labelText: label,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              fillColor: theme.colorScheme.surface,
              enabledBorder: border,
              focusedBorder: border.copyWith(
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 2,
                ),
              ),
              errorText: _error,
              errorMaxLines: 3,
            ),
            onSubmitted: widget.field == _SpaceField.name
                ? (_) => _submit()
                : null,
          ),
          const SizedBox(height: NeuSpacing.sm),
          Text(
            '所有空间成员都能看到这项修改。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: NeuSpacing.xl),
          OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: NeuSpacing.sm,
            children: [
              FilledButton.tonal(
                onPressed: _saving ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: _saving ? null : _submit,
                child: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!compact) return Dialog(child: SizedBox(width: 520, child: form));
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Material(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(materialSurfaceRadius),
          ),
          clipBehavior: Clip.antiAlias,
          child: SafeArea(top: false, child: form),
        ),
      ),
    );
  }
}
