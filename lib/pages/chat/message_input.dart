/// Compatibility entry for the chat composer. Implementation modules live in
/// composer/; existing callers keep the same widget, state, providers and send API.
library;

export 'composer/composer_input.dart'
    show MessageInput, MessageInputState, InputPanelMode;
export 'composer/composer_draft_controller.dart'
    show
        messageDraftProvider,
        editingDraftProvider,
        editingSendInFlightProvider;
export 'composer/composer_send.dart' show sendDraftText;
