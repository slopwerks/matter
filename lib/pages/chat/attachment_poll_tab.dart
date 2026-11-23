import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/max_content_width.dart';
import 'attachment_picker_controls.dart';

const _pollOptionAnimationDuration = Duration(milliseconds: 180);

class AttachmentPollTab extends StatefulWidget {
  final bool isSending;
  final ScrollController? scrollController;
  final Future<void> Function(
    String question,
    List<String> answers,
    bool disclosed,
    int maxSelections,
  )
  onSendPoll;

  const AttachmentPollTab({
    super.key,
    required this.isSending,
    required this.scrollController,
    required this.onSendPoll,
  });

  @override
  State<AttachmentPollTab> createState() => _AttachmentPollTabState();
}

class _AttachmentPollTabState extends State<AttachmentPollTab> {
  final _question = TextEditingController();
  final List<_PollAnswerDraft> _answers = [
    _PollAnswerDraft(0),
    _PollAnswerDraft(1),
  ];
  var _nextAnswerId = 2;
  bool _disclosed = false;
  bool _allowMultiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final answer in _answers) {
      answer.controller.dispose();
    }
    super.dispose();
  }

  bool get _canSend {
    if (_question.text.trim().isEmpty) return false;
    final valid = _validAnswers.length;
    return valid >= 2;
  }

  List<String> get _validAnswers => _answers
      .where((answer) => answer.visible)
      .map((answer) => answer.controller.text.trim())
      .where((answer) => answer.isNotEmpty)
      .toList();

  int get _visibleAnswerCount =>
      _answers.where((answer) => answer.visible).length;

  void _addAnswer() {
    if (widget.isSending || _visibleAnswerCount >= 20) return;
    final answer = _PollAnswerDraft(_nextAnswerId++, visible: false);
    setState(() => _answers.add(answer));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_answers.contains(answer)) return;
      setState(() => answer.visible = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final answerContext = answer.fieldContext;
        if (!mounted || answerContext == null) return;
        unawaited(
          Scrollable.ensureVisible(
            answerContext,
            alignment: 0.25,
            duration: _pollOptionAnimationDuration,
            curve: Curves.easeOutCubic,
          ),
        );
      });
    });
  }

  void _removeAnswer(_PollAnswerDraft answer) {
    if (widget.isSending || !answer.visible || _visibleAnswerCount <= 2) {
      return;
    }
    setState(() => answer.visible = false);
    Future<void>.delayed(_pollOptionAnimationDuration, () {
      if (!mounted) return;
      setState(() => _answers.remove(answer));
      answer.controller.dispose();
    });
  }

  List<Widget> _buildAnswerRows() {
    var visibleIndex = 0;
    return [
      for (final answer in _answers)
        _buildAnswerRow(answer, answer.visible ? visibleIndex++ : 0),
    ];
  }

  Widget _buildAnswerRow(_PollAnswerDraft answer, int index) {
    return AnimatedSize(
      duration: _pollOptionAnimationDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: answer.visible
          ? Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Builder(
                builder: (context) {
                  answer.fieldContext = context;
                  return _PollOptionInput(
                    key: ValueKey('poll-option-${answer.id}'),
                    controller: answer.controller,
                    index: index,
                    enabled: !widget.isSending,
                    showRemoveButton: _visibleAnswerCount > 2,
                    onChanged: (_) => setState(() {}),
                    onRemove: () => _removeAnswer(answer),
                  );
                },
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final question = TextField(
      controller: _question,
      enabled: !widget.isSending,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: const InputDecoration(labelText: '问题'),
      onChanged: (_) => setState(() {}),
    );
    final answers = <Widget>[
      ..._buildAnswerRows(),
      TextButton.icon(
        onPressed: widget.isSending || _visibleAnswerCount >= 20
            ? null
            : _addAnswer,
        icon: Icon(
          Icons.add_rounded,
          color: context.isMaterial ? null : colors.accent,
        ),
        label: Text(
          '添加选项',
          style: context.isMaterial ? null : TextStyle(color: colors.accent),
        ),
      ),
    ];
    final rules = <Widget>[
      SwitchListTile(
        title: Text('公开投票结果', style: Theme.of(context).textTheme.bodyLarge),
        value: _disclosed,
        onChanged: widget.isSending
            ? null
            : (v) => setState(() => _disclosed = v),
        activeThumbColor: context.isMaterial ? null : colors.accent,
      ),
      SwitchListTile(
        title: Text('允许多选', style: Theme.of(context).textTheme.bodyLarge),
        value: _allowMultiple,
        onChanged: widget.isSending
            ? null
            : (v) => setState(() => _allowMultiple = v),
        activeThumbColor: context.isMaterial ? null : colors.accent,
      ),
    ];
    return Stack(
      children: [
        Positioned.fill(
          child: MaxContentWidth(
            maxWidth: context.isMaterial ? 560 : double.infinity,
            child: ListView(
              controller: widget.scrollController,
              padding: const EdgeInsets.fromLTRB(
                16,
                16,
                16,
                attachmentSendBarClearance,
              ),
              children: context.isMaterial
                  ? [
                      MaterialDetailCard(
                        title: '投票内容',
                        description: '填写问题和至少两个选项，最多支持 20 个选项。',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            question,
                            const SizedBox(height: 16),
                            ...answers,
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      MaterialDetailCard(
                        title: '投票规则',
                        child: ListTileTheme.merge(
                          contentPadding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              rules.first,
                              const Divider(height: 1),
                              rules.last,
                            ],
                          ),
                        ),
                      ),
                    ]
                  : [
                      question,
                      const SizedBox(height: 16),
                      ...answers,
                      ...rules,
                    ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: AttachmentSendBar(
            label: '发送',
            isSending: widget.isSending,
            enabled: _canSend,
            onSend: () {
              final answers = _validAnswers;
              unawaited(
                widget.onSendPoll(
                  _question.text.trim(),
                  answers,
                  _disclosed,
                  _allowMultiple ? answers.length : 1,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PollAnswerDraft {
  final int id;
  final TextEditingController controller = TextEditingController();
  BuildContext? fieldContext;
  bool visible;

  _PollAnswerDraft(this.id, {this.visible = true});
}

class _PollOptionInput extends StatelessWidget {
  final TextEditingController controller;
  final int index;
  final bool enabled;
  final bool showRemoveButton;
  final ValueChanged<String> onChanged;
  final VoidCallback? onRemove;

  const _PollOptionInput({
    super.key,
    required this.controller,
    required this.index,
    required this.enabled,
    required this.showRemoveButton,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('poll-option-input-$index'),
            controller: controller,
            enabled: enabled,
            style: Theme.of(context).textTheme.bodyLarge,
            decoration: InputDecoration(hintText: '选项 ${index + 1}'),
            onChanged: onChanged,
          ),
        ),
        AnimatedContainer(
          duration: _pollOptionAnimationDuration,
          curve: Curves.easeOutCubic,
          width: showRemoveButton ? 44 : 0,
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(),
          child: showRemoveButton
              ? Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: SizedBox.square(
                    dimension: 40,
                    child: IconButton(
                      tooltip: '删除选项',
                      icon: Icon(
                        Icons.remove_circle_outline_rounded,
                        color: context.neu.textTertiary,
                      ),
                      onPressed: enabled ? onRemove : null,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                )
              : null,
        ),
      ],
    );
  }
}
