import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'linux_ime_model.dart';

/// Keeps Flutter's editable/Actions/undo stack, replacing only Linux's IME.
class LinuxImeScope extends StatefulWidget {
  const LinuxImeScope({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.readOnly,
    required this.child,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool readOnly;
  final Widget child;

  @override
  State<LinuxImeScope> createState() => _LinuxImeScopeState();
}

class _LinuxImeScopeState extends State<LinuxImeScope> {
  LinuxImeControl? _control;

  @override
  void initState() {
    super.initState();
    // Registered before EditableText's listener, so its connection attaches
    // to our control on both pointer and programmatic focus.
    widget.focusNode.addListener(_focusChanged);
    _focusChanged();
  }

  @override
  void didUpdateWidget(LinuxImeScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode ||
        oldWidget.controller != widget.controller) {
      oldWidget.focusNode.removeListener(_focusChanged);
      _control?.uninstall();
      _control = null;
      widget.focusNode.addListener(_focusChanged);
    }
    _focusChanged();
  }

  void _focusChanged() {
    final enabled =
        !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.linux &&
        !widget.readOnly &&
        widget.focusNode.hasFocus;
    if (enabled) {
      _control ??= LinuxImeControl(widget.controller, widget.focusNode);
      _control!.install();
    } else {
      _control?.uninstall();
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_focusChanged);
    _control?.uninstall();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class LinuxImeControl with TextInputControl {
  LinuxImeControl(this.controller, this.focusNode);

  final TextEditingController controller;
  final FocusNode focusNode;
  static const _channel = MethodChannel('moe.aks.matter/linux_ime');
  static LinuxImeControl? _owner;
  static int _nextEpoch = 0;
  TextInputClient? _client;
  late LinuxImeModel _model;
  int _epoch = 0;
  bool _ready = false;
  bool _publishing = false;
  Matrix4? _transform;
  Rect? _caret;

  void install() {
    if (identical(_owner, this)) return;
    _owner?.uninstall();
    _owner = this;
    _channel.setMethodCallHandler(_event);
    TextInput.setInputControl(this);
  }

  void uninstall() {
    if (!identical(_owner, this)) return;
    _stop();
    _owner = null;
    _channel.setMethodCallHandler(null);
    TextInput.restorePlatformInputControl();
  }

  @override
  void attach(TextInputClient client, TextInputConfiguration configuration) {
    // A different field must never be edited through a stale composer scope.
    if (client is! EditableTextState ||
        client.widget.controller != controller ||
        client.widget.focusNode != focusNode) {
      uninstall();
      // setInputControl does not attach an already attached client.
      client.connectionClosed();
      return;
    }
    if (_client != null) _stop();
    _client = client;
    controller.addListener(_controllerChanged);
    _model = LinuxImeModel(controller.value);
    _epoch = ++_nextEpoch;
    _ready = false;
    unawaited(_activate(_epoch));
  }

  Future<void> _activate(int epoch) async {
    // The previous platform GtkIMContext must have no text client.
    await SystemChannels.textInput.invokeMethod<void>('TextInput.clearClient');
    if (!identical(_owner, this) || _client == null || epoch != _epoch) return;
    _ready = true;
    _send('focus', {'active': true});
    _sendState();
    _sendCaret();
  }

  @override
  void show() {
    if (_client != null) return;
    final editable = focusNode.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editable != null && !editable.widget.readOnly) {
      attach(editable, editable.textInputConfiguration);
    }
  }

  @override
  void detach(TextInputClient client) {
    if (identical(client, _client)) _stop(detaching: true);
  }

  void _stop({bool detaching = false}) {
    if (_client == null) return;
    if (_model.composing) {
      _model.cancel();
      if (detaching) {
        // EditableText may already be disposing its renderer. Restore the
        // draft without invoking that client or its selection overlay.
        _publishing = true;
        try {
          controller.value = _model.value;
        } finally {
          _publishing = false;
        }
      } else {
        _publish();
      }
    }
    if (_ready) _send('focus', {'active': false});
    _ready = false;
    controller.removeListener(_controllerChanged);
    _client = null;
    _epoch = ++_nextEpoch;
  }

  void _controllerChanged() => setEditingState(controller.value);

  @override
  void setEditingState(TextEditingValue value) {
    if (_client == null || _publishing || value == _model.value) return;
    final hadPreedit = _model.composing;
    _model.synchronize(value);
    if (hadPreedit) {
      // Rotate the session before resetting GTK: queued preedit/end callbacks
      // must not overwrite a pointer selection, paste, undo or a restored draft.
      _epoch = ++_nextEpoch;
      if (_ready) _send('focus', {'active': true});
    }
    if (_model.value != value) _publish();
    _sendState();
  }

  Future<void> _event(MethodCall call) async {
    if (call.method != 'event' ||
        !_ready ||
        _client == null ||
        !identical(_owner, this)) {
      return;
    }
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    if (args['epoch'] != _epoch) return;
    switch (args['type']) {
      case 'start':
        _model.start();
      case 'preedit':
        _model.preedit(args['text'] as String, args['cursor'] as int);
      case 'commit':
        _model.commit(args['text'] as String);
      case 'end':
      case 'blur':
        _model.cancel();
      case 'delete':
        if (!_model.deleteSurrounding(
          args['offset'] as int,
          args['count'] as int,
        )) {
          throw StateError('GTK requested an invalid surrounding-text range');
        }
      default:
        throw StateError('Unknown GTK IME event: ${args['type']}');
    }
    _publish();
    _sendState();
  }

  void _publish() {
    _publishing = true;
    try {
      _client?.updateEditingValue(_model.value);
    } finally {
      _publishing = false;
    }
  }

  void _send(String method, Map<String, Object> args) {
    unawaited(_channel.invokeMethod<void>(method, {'epoch': _epoch, ...args}));
  }

  void _sendState() {
    if (!_ready) return;
    final value = _model.value;
    final offset = value.selection.isValid
        ? value.selection.extentOffset
        : value.text.length;
    _send('state', {
      'text': value.text,
      'cursor': utf8.encode(value.text.substring(0, offset)).length,
    });
  }

  @override
  void setEditableSizeAndTransform(Size editableBoxSize, Matrix4 transform) {
    _transform = Matrix4.copy(transform);
    _sendCaret();
  }

  @override
  void setCaretRect(Rect rect) {
    _caret = rect;
    _sendCaret();
  }

  void _sendCaret() {
    if (!_ready || _transform == null || _caret == null) return;
    final rect = MatrixUtils.transformRect(_transform!, _caret!);
    _send('cursor', {
      'x': rect.left,
      'y': rect.top,
      'width': rect.width,
      'height': rect.height,
    });
  }
}
