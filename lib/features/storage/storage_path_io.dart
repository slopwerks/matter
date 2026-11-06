import 'dart:io';

import 'package:path/path.dart' as path;

/// macOS/iOS temporary paths can have /var and /private/var aliases. Resolve
/// the existing ancestor even when a transfer's destination is not created yet.
String storagePathKey(String value) {
  final absolute = path.normalize(path.absolute(value));
  var ancestor = absolute;
  final suffix = <String>[];
  while (true) {
    try {
      return path.joinAll([
        File(ancestor).resolveSymbolicLinksSync(),
        ...suffix.reversed,
      ]);
    } on FileSystemException {
      final parent = path.dirname(ancestor);
      if (parent == ancestor) return absolute;
      suffix.add(path.basename(ancestor));
      ancestor = parent;
    }
  }
}
