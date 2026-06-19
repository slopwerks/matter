import '../src/rust/api/matrix.dart' as rust;

int compareChatMessages(rust.ChatMessage a, rust.ChatMessage b) {
  final aTime = int.tryParse(a.timestamp) ?? 0;
  final bTime = int.tryParse(b.timestamp) ?? 0;
  final timestampOrder = aTime.compareTo(bTime);
  if (timestampOrder != 0) return timestampOrder;
  return a.id.compareTo(b.id);
}
