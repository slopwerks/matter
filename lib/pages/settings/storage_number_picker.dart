import 'package:flutter/material.dart';

Future<int?> pickStorageNumber(
  BuildContext context,
  String title,
  int current,
  Map<int, String> presets, {
  String unit = 'MiB',
  String? zeroLabel,
}) => showDialog<int>(
  context: context,
  builder: (_) => _StorageNumberDialog(
    title: title,
    current: current,
    presets: presets,
    unit: unit,
    zeroLabel: zeroLabel,
  ),
);

const storageCachePresets = {
  0: '不限制',
  256: '256 MiB',
  512: '512 MiB',
  1024: '1 GiB',
  2048: '2 GiB',
  5120: '5 GiB',
};

class _StorageNumberDialog extends StatefulWidget {
  const _StorageNumberDialog({
    required this.title,
    required this.current,
    required this.presets,
    required this.unit,
    this.zeroLabel,
  });
  final String title;
  final int current;
  final Map<int, String> presets;
  final String unit;
  final String? zeroLabel;
  @override
  State<_StorageNumberDialog> createState() => _StorageNumberDialogState();
}

class _StorageNumberDialogState extends State<_StorageNumberDialog> {
  late final _controller = TextEditingController(text: '${widget.current}');
  late int _value = widget.current;
  late List<int> _values = _valuesIncluding(_value);
  bool _invalid = false;

  List<int> _valuesIncluding(int value) =>
      {0, ...widget.presets.keys, value}.toList()..sort();

  String _label(int value) => value == 0
      ? widget.zeroLabel ??
            widget.presets[0] ??
            (widget.unit == '天' ? '永久保留' : '不限制')
      : widget.presets[value] ?? '$value ${widget.unit}';

  String _tickLabel(int value) {
    if (value == 0) return '0';
    final label = _label(value);
    final suffix = ' ${widget.unit}';
    return label.endsWith(suffix)
        ? label.substring(0, label.length - suffix.length)
        : label;
  }

  void _input(String text) {
    final value = int.tryParse(text);
    setState(() {
      _invalid = value == null || value < 0;
      if (!_invalid) {
        _value = value!;
        _values = _valuesIncluding(_value);
      }
    });
  }

  void _slide(double position) {
    final value = _values[position.round()];
    setState(() {
      _value = value;
      _invalid = false;
      // Keep stops fixed during a drag, including the last custom input.
      _controller.value = TextEditingValue(
        text: '$value',
        selection: TextSelection.collapsed(offset: '$value'.length),
      );
    });
  }

  void _submit(String text) {
    final value = int.tryParse(text);
    if (value != null && value >= 0) {
      Navigator.pop(context, value);
    } else {
      setState(() => _invalid = true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _tickLabels() => SizedBox(
    height: MediaQuery.textScalerOf(context).scale(20),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final style = Theme.of(context).textTheme.bodySmall;
          final painter = TextPainter(
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          );
          var labelWidth = 0.0;
          for (final value in _values) {
            painter.text = TextSpan(text: _tickLabel(value), style: style);
            painter.layout();
            if (painter.width > labelWidth) labelWidth = painter.width;
          }
          painter.dispose();
          final count = (constraints.maxWidth / (labelWidth + 8) + 1)
              .floor()
              .clamp(2, _values.length);
          final indices = [
            for (var i = 0; i < count; i++)
              (i * (_values.length - 1) / (count - 1)).round(),
          ];
          return Stack(
            children: [
              for (final index in indices)
                Align(
                  alignment: AlignmentDirectional(
                    index * 2 / (_values.length - 1) - 1,
                    0,
                  ),
                  child: Text(_tickLabel(_values[index]), style: style),
                ),
            ],
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: SizedBox(
      width: 320,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: _values.indexOf(_value).toDouble(),
            max: (_values.length - 1).toDouble(),
            divisions: _values.length - 1,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            label: _label(_value),
            semanticFormatterCallback: (position) =>
                _label(_values[position.round()]),
            onChanged: _slide,
          ),
          _tickLabels(),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '数值',
              suffixText: widget.unit,
              helperText: '0 表示${_label(0)}',
              helperMaxLines: 2,
              errorText: _invalid ? '请输入 0 或正整数' : null,
              errorMaxLines: 2,
            ),
            onChanged: _input,
            onSubmitted: _submit,
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _invalid ? null : () => _submit(_controller.text),
        child: const Text('确定'),
      ),
    ],
  );
}
