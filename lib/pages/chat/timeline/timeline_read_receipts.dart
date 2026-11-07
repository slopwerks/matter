import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/chat_provider.dart';
import '../../../src/rust/api/matrix.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/app_avatar.dart';
import '../../../widgets/sheets.dart';

/// Shared by text metadata and media overlays, retaining the 15dp slot even
/// when there is no other member. The host decides whether to show this slot.
class TimelineReadIndicator extends StatelessWidget {
  const TimelineReadIndicator({
    super.key,
    required this.message,
    required this.roomId,
    required this.color,
  });

  final ChatMessage message;
  final String roomId;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final others = message.totalMembers - 1;
    if (others <= 0) return const SizedBox.square(dimension: 15);
    final count = message.readers.length;
    return Tooltip(
      message: count == 0 ? '尚未已读' : '已读 $count/$others，点击查看',
      child: GestureDetector(
        key: ValueKey('message-read-receipt:${message.id}'),
        onTap: count > 0
            ? () => showNeuSheet(
                context: context,
                child: _ReadReceiptsSheet(message: message, roomId: roomId),
              )
            : null,
        behavior: HitTestBehavior.opaque,
        child: Icon(
          count == 0 ? Icons.done_rounded : Icons.done_all_rounded,
          size: 15,
          color: color,
        ),
      ),
    );
  }
}

class _ReadReceiptsSheet extends StatelessWidget {
  const _ReadReceiptsSheet({required this.message, required this.roomId});

  final ChatMessage message;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '已读 ${message.readers.length}',
                  style: textTheme.titleMedium,
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Icon(
                  Icons.close_rounded,
                  color: colors.textTertiary,
                  size: 22,
                ),
              ),
            ],
          ),
        ),
        if (message.readers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('暂无已读', style: textTheme.bodyMedium)),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 8),
            itemCount: message.readers.length,
            itemBuilder: (context, index) =>
                _ReadReceiptRow(reader: message.readers[index], roomId: roomId),
          ),
      ],
    );
  }
}

/// Matrix stores one receipt position per user, not a per-message read time.
/// Show who read, without inventing when they read this particular message.
class _ReadReceiptRow extends ConsumerStatefulWidget {
  const _ReadReceiptRow({required this.reader, required this.roomId});
  final MessageReader reader;
  final String roomId;

  @override
  ConsumerState<_ReadReceiptRow> createState() => _ReadReceiptRowState();
}

class _ReadReceiptRowState extends ConsumerState<_ReadReceiptRow> {
  String? _avatarUrl;

  @override
  void initState() {
    super.initState();
    _resolveAvatar();
  }

  Future<void> _resolveAvatar() async {
    final url = await resolveMxcUrlAvatar(ref, widget.reader.avatarUrl);
    if (mounted && url != _avatarUrl) setState(() => _avatarUrl = url);
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    child: Row(
      children: [
        AppAvatar(
          fallback: widget.reader.displayName,
          size: 40,
          radius: NeuRadius.content,
          url: _avatarUrl,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            widget.reader.displayName,
            style: Theme.of(context).textTheme.bodyLarge
                ?.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}
