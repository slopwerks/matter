import 'dart:convert';

import 'package:crypto/crypto.dart';

String storageAccountKey(String userId, String homeserver) =>
    sha256.convert(utf8.encode(jsonEncode([userId, homeserver]))).toString();
