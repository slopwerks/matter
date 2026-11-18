import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';
import 'timeline/timeline_bubble_frame.dart'
    show
        enabledNeuBubbleShadows,
        messageBubbleFill,
        neuBubbleShape,
        timelineBubbleBorderRadius;

typedef PollVoteCallback = Future<void> Function(List<String> answerIds);
typedef PollEndCallback = Future<void> Function();
typedef PollRefreshCallback = Future<void> Function();

/// Renders a poll and keeps vote/end operations serial and optimistic.
class PollMessageBubble extends ConsumerStatefulWidget {
  final String roomId;
  final String pollStartEventId;
  final rust.PollInfo poll;
  final bool isMe;
  final Widget metadata;
  final double maxWidth;
  final PollVoteCallback? onVote;
  final PollEndCallback? onEnd;
  final PollRefreshCallback? onRefresh;

  const PollMessageBubble({
    super.key,
    required this.roomId,
    required this.pollStartEventId,
    required this.poll,
    required this.isMe,
    required this.metadata,
    this.maxWidth = 280,
    this.onVote,
    this.onEnd,
    this.onRefresh,
  });

  @override
  ConsumerState<PollMessageBubble> createState() => _PollMessageBubbleState();
}

class _PollMessageBubbleState extends ConsumerState<PollMessageBubble> {
  late Set<String> _selected;
  Set<String>? _optimisticVote;
  bool _submitting = false;
  bool _endedLocally = false;

  @override
  void initState() {
    super.initState();
    _selected = Set<String>.of(widget.poll.myAnswerIds);
  }

  @override
  void didUpdateWidget(covariant PollMessageBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pollStartEventId != widget.pollStartEventId) {
      _selected = Set<String>.of(widget.poll.myAnswerIds);
      _optimisticVote = null;
      _endedLocally = widget.poll.ended;
    } else if (widget.poll.ended) {
      _endedLocally = true;
    }
    final oldRemoteVote = Set<String>.of(oldWidget.poll.myAnswerIds);
    final remoteVote = Set<String>.of(widget.poll.myAnswerIds);
    if (_optimisticVote != null && _setsEqual(_optimisticVote!, remoteVote)) {
      _optimisticVote = null;
    }
    if (!_submitting &&
        _optimisticVote == null &&
        !_setsEqual(oldRemoteVote, remoteVote)) {
      _selected = remoteVote;
    }
  }

  int _countFor(String id) {
    var count = 0;
    for (final result in widget.poll.results) {
      if (result.answerId == id) {
        count = result.count;
        break;
      }
    }
    final optimisticVote = _optimisticVote;
    if (optimisticVote == null) return count;
    final remoteVote = widget.poll.myAnswerIds.toSet();
    if (remoteVote.contains(id) && !optimisticVote.contains(id)) count--;
    if (!remoteVote.contains(id) && optimisticVote.contains(id)) count++;
    return count < 0 ? 0 : count;
  }

  int get _totalVoters {
    final optimisticVote = _optimisticVote;
    if (optimisticVote == null) return widget.poll.totalVoters;
    final remoteHasVoted = widget.poll.myAnswerIds.isNotEmpty;
    if (!remoteHasVoted && optimisticVote.isNotEmpty) {
      return widget.poll.totalVoters + 1;
    }
    return widget.poll.totalVoters;
  }

  Set<String> get _committedVote =>
      _optimisticVote ?? Set<String>.of(widget.poll.myAnswerIds);

  Future<void> _selectAnswer(String answerId) async {
    if (_submitting || widget.poll.ended || _endedLocally) return;
    final previous = Set<String>.of(_selected);
    final next = Set<String>.of(previous);
    if (widget.poll.maxSelections > 1) {
      if (next.contains(answerId)) {
        if (next.length == 1) return;
        next.remove(answerId);
      } else if (next.length < widget.poll.maxSelections) {
        next.add(answerId);
      } else {
        return;
      }
    } else {
      next
        ..clear()
        ..add(answerId);
    }
    if (next.isEmpty || _setsEqual(next, previous)) return;

    if (widget.poll.maxSelections > 1) {
      setState(() => _selected = next);
      return;
    }
    await _submitVote(next, rollbackSelection: previous);
  }

  Future<void> _submitVote(
    Set<String> vote, {
    required Set<String> rollbackSelection,
  }) async {
    if (_submitting || vote.isEmpty || widget.poll.ended || _endedLocally) {
      return;
    }

    setState(() {
      _selected = vote;
      _submitting = true;
    });
    var succeeded = false;
    try {
      if (widget.onVote != null) {
        await widget.onVote!(vote.toList());
      } else {
        await rust.sendPollResponse(
          roomId: widget.roomId,
          pollStartEventId: widget.pollStartEventId,
          answerIds: vote.toList(),
        );
      }
      succeeded = true;
      if (mounted) setState(() => _optimisticVote = Set<String>.of(vote));
    } catch (error) {
      if (!mounted) return;
      setState(() => _selected = rollbackSelection);
      _showError('投票失败: $error');
      return;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (succeeded) await _refreshBestEffort();
  }

  Future<void> _endPoll() async {
    if (_submitting || widget.poll.ended || _endedLocally || !widget.isMe) {
      return;
    }
    setState(() => _submitting = true);
    var succeeded = false;
    try {
      if (widget.onEnd != null) {
        await widget.onEnd!();
      } else {
        await rust.endPoll(
          roomId: widget.roomId,
          pollStartEventId: widget.pollStartEventId,
        );
      }
      succeeded = true;
      if (mounted) setState(() => _endedLocally = true);
    } catch (error) {
      if (mounted) _showError('结束投票失败: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (succeeded) await _refreshBestEffort();
  }

  Future<void> _refreshBestEffort() async {
    try {
      if (widget.onRefresh != null) {
        await widget.onRefresh!();
      } else {
        await refreshMessages(ref, widget.roomId);
      }
    } catch (_) {
      // Sync will eventually reconcile a successfully sent response.
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  bool _setsEqual(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final material = context.isMaterial;
    final scheme = theme.colorScheme;
    final foreground = widget.isMe
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final supporting = widget.isMe ? foreground : scheme.onSurfaceVariant;
    final poll = widget.poll;
    final ended = poll.ended || _endedLocally;
    final reveal = poll.disclosed || ended;
    final multi = poll.maxSelections > 1;
    final totalVoters = _totalVoters;
    final canSubmitMulti =
        multi &&
        !ended &&
        !_submitting &&
        _selected.isNotEmpty &&
        !_setsEqual(_selected, _committedVote);
    final shape = material
        ? RoundedRectangleBorder(
            borderRadius: timelineBubbleBorderRadius(
              context,
              isMe: widget.isMe,
              isFirst: true,
              isLast: true,
            ),
          )
        : neuBubbleShape(context, BorderRadius.circular(NeuRadius.content));
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Container(
        decoration: ShapeDecoration(
          shape: shape,
          color: material
              ? messageBubbleFill(context, isMe: widget.isMe)
              : widget.isMe
              ? colors.accent.withValues(alpha: 0.18)
              : colors.card,
          shadows: material
              ? const []
              : enabledNeuBubbleShadows(context, colors),
        ),
        child: ClipPath.shape(
          shape: shape,
          child: Stack(
            children: [
              Material(
                type: MaterialType.transparency,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.poll_rounded,
                            color: material ? supporting : colors.accent,
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '投票',
                            style: material
                                ? textTheme.labelMedium?.copyWith(
                                    color: supporting,
                                  )
                                : textTheme.bodySmall,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        poll.question,
                        style: textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: material ? foreground : null,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final answer in poll.answers)
                        _PollAnswerRow(
                          answer: answer,
                          multi: multi,
                          selected: _selected.contains(answer.id),
                          count: _countFor(answer.id),
                          totalVoters: totalVoters,
                          reveal: reveal,
                          enabled: !ended && !_submitting,
                          materialForeground: material ? foreground : null,
                          materialSupporting: material ? supporting : null,
                          onTap: () => _selectAnswer(answer.id),
                        ),
                      const SizedBox(height: 6),
                      Text(
                        '$totalVoters 人已投票${ended ? ' · 已结束' : ''}',
                        style: textTheme.labelSmall?.copyWith(
                          color: material ? supporting : null,
                        ),
                      ),
                      if (multi && !ended) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: NeuButton(
                            accent: true,
                            onPressed: canSubmitMulti
                                ? () => _submitVote(
                                    Set<String>.of(_selected),
                                    rollbackSelection: Set<String>.of(
                                      _selected,
                                    ),
                                  )
                                : null,
                            icon: const Icon(
                              Icons.how_to_vote_rounded,
                              size: 18,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: const Text('提交投票'),
                          ),
                        ),
                      ],
                      if (widget.isMe && !ended) ...[
                        const SizedBox(height: 4),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _submitting ? null : _endPoll,
                            icon: const Icon(
                              Icons.stop_circle_outlined,
                              size: 16,
                            ),
                            label: const Text('结束投票'),
                            style: TextButton.styleFrom(
                              foregroundColor: material
                                  ? supporting
                                  : colors.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (_submitting)
                const Positioned(
                  right: 10,
                  top: 10,
                  child: SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              widget.metadata,
            ],
          ),
        ),
      ),
    );
  }
}

class _PollAnswerRow extends StatelessWidget {
  final rust.PollAnswerInfo answer;
  final bool multi;
  final bool selected;
  final int count;
  final int totalVoters;
  final bool reveal;
  final bool enabled;
  final Color? materialForeground;
  final Color? materialSupporting;
  final VoidCallback onTap;

  const _PollAnswerRow({
    required this.answer,
    required this.multi,
    required this.selected,
    required this.count,
    required this.totalVoters,
    required this.reveal,
    required this.enabled,
    required this.materialForeground,
    required this.materialSupporting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final fraction = totalVoters > 0 && reveal
        ? (count / totalVoters).clamp(0.0, 1.0)
        : 0.0;
    final control = Icon(
      multi
          ? selected
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded
          : selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
      size: 18,
      color: materialSupporting ?? colors.accent,
    );
    final resultFill = FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: fraction,
      child: ColoredBox(
        color:
            materialSupporting?.withValues(alpha: selected ? .18 : .10) ??
            colors.accent.withValues(alpha: selected ? .28 : .16),
        child: SizedBox(
          height: materialSupporting == null ? 32 : double.infinity,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              if (reveal)
                if (materialSupporting != null)
                  Positioned.fill(child: resultFill)
                else
                  resultFill,
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(
                  children: [
                    control,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        answer.text,
                        style: textTheme.bodyMedium?.copyWith(
                          color: materialForeground ?? colors.text,
                        ),
                      ),
                    ),
                    if (reveal)
                      Text(
                        '$count',
                        style: textTheme.bodySmall?.copyWith(
                          color: materialSupporting ?? colors.textTertiary,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
