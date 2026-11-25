import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_message_bubble.dart';

void main() {
  test('attachment filenames are reduced to portable basenames', () {
    expect(sanitizeAttachmentFilename('../../secret.pdf'), 'secret.pdf');
    expect(sanitizeAttachmentFilename(r'C:\temp\CON.txt'), '_CON.txt');
    expect(sanitizeAttachmentFilename('..'), 'attachment.bin');
    expect(sanitizeAttachmentFilename('bad:name?.zip'), 'bad_name_.zip');
    expect(
      sanitizeAttachmentFilename('invoice\u202Efdp.exe'),
      'invoicefdp.exe',
    );
    expect(sanitizeAttachmentFilename('safe\u2066.txt'), 'safe.txt');
  });
}
