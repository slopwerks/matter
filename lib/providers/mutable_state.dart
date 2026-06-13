import 'package:flutter_riverpod/flutter_riverpod.dart';

class MutableState<T> extends Notifier<T> {
  MutableState(this._initialValue);

  final T _initialValue;

  @override
  T build() => _initialValue;

  set value(T value) => state = value;
}
