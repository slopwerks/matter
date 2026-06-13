import 'package:intl/intl.dart';

DateTime? chatTimestampToLocal(String value) {
  final milliseconds = int.tryParse(value);
  if (milliseconds == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(
    milliseconds,
    isUtc: true,
  ).toLocal();
}

String formatMessageTime(String value) {
  final dateTime = chatTimestampToLocal(value);
  return dateTime == null ? value : DateFormat('HH:mm').format(dateTime);
}

String chatDateKey(String value) {
  final dateTime = chatTimestampToLocal(value);
  if (dateTime == null) return value;
  return '${dateTime.year}-${dateTime.month}-${dateTime.day}';
}

String formatChatDate(String value, {DateTime? now}) {
  final dateTime = chatTimestampToLocal(value);
  if (dateTime == null) return value;

  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final date = _dateOnly(dateTime);
  final difference = today.difference(date).inDays;

  if (difference == 0) return '今天';
  if (difference == 1) return '昨天';
  if (date.year == today.year) return DateFormat('M月d日').format(date);
  return DateFormat('yyyy年M月d日').format(date);
}

String formatChatListTime(String value, {DateTime? now}) {
  final dateTime = chatTimestampToLocal(value);
  if (dateTime == null) return value;

  final today = _dateOnly((now ?? DateTime.now()).toLocal());
  final date = _dateOnly(dateTime);
  final difference = today.difference(date).inDays;

  if (difference == 0) return DateFormat('HH:mm').format(dateTime);
  if (difference == 1) return '昨天';
  if (date.year == today.year) return DateFormat('M/d').format(date);
  return DateFormat('yyyy/M/d').format(date);
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
