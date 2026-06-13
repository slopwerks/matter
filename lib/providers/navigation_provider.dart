import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'mutable_state.dart';

final navigationIndexProvider = NotifierProvider<MutableState<int>, int>(
  () => MutableState(0),
);
