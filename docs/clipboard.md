# Clipboard paste

The chat composer handles keyboard paste and the selection menu through the
same attachment reader. Clipboard access happens only on an explicit paste.

## Routing

1. Prefer copied files to alternative text or image representations. A copied
   text file remains a file attachment; a copied URL remains editor text.
2. Identify attachments using file signatures, native MIME metadata (when
   available), and filename extensions. Images enter the image draft, videos
   use the existing video attachment sender, and other files use the file sender.
3. If no files exist, read clipboard image data, including PNG conversion of
   desktop bitmap formats provided by `pasteboard`.
4. With no attachments, delegate to `EditableText.pasteText` so selection
   replacement, cursor position and ordinary text paste remain native Flutter
   behavior. Rich-text snippets use their plain-text representation.

Pasting never sends immediately. It opens the existing attachment preview or
stages images in the existing composer draft. File errors are reported rather
than silently pasting a path. Folders are rejected. The existing 64 MiB buffered
attachment limit applies; mobile native reads additionally limit the combined
payload to 64 MiB before returning bytes to Dart.

## Platforms

| Platform | File/metadata access |
| --- | --- |
| Linux / Wayland and X11 | `pasteboard` uses GTK clipboard URI targets and file-transfer portal support; Dart reads headers without buffering whole files. |
| Windows | `pasteboard` supplies copied file paths and clipboard bitmap data. |
| macOS | `pasteboard` supplies file URLs and PNG image representations. Sandbox or source-app permissions can still prevent access. |
| Android | The app bridge reads clipboard `content://` and `file://` URIs, resolves display names/MIME with `ContentResolver`, and streams bounded bytes off the UI thread. |
| iOS | The app bridge reads file URLs with scoped access and available image/video/audio/document data using Uniform Type Identifiers. |

This does not add support for keyboard IME rich-content commits, OS share-sheet
intents, remote file downloads, promised files or clipboard formats not exposed
by the platform reader. iOS paste privacy prompts are controlled by the OS.
Other editors, including the standalone Markdown editor, keep their existing
paste behavior.

`mime` is a direct Dart dependency. The existing `pasteboard` plugin is retained
to preserve the project's Swift Package Manager setup. No CocoaPods integration
or new native plugin is introduced.

## Matrix mapping

Clipboard transport does not define a new Matrix event. It feeds the existing
attachment pipeline, which sends `m.room.message` events with `m.image`,
`m.video` or `m.file`, original filenames, and the available `info.mimetype` and
`info.size`. Existing upload and encrypted-room handling remain shared with
picked and dropped attachments. Video dimensions/duration are only included
when already available from that pipeline.

References: [Matrix media messages](https://spec.matrix.org/latest/client-server-api/#mroommessage-msgtypes)
and [content repository](https://spec.matrix.org/latest/client-server-api/#content-repository).

## Verification

Automated routing tests mock clipboard channels and use real temporary files:
text fallback, multiple files, header-based MIME detection, copied text files,
directory rejection, clipboard images, and Android/iOS binary payloads.

On each target, manually paste a screenshot, a copied image file, a video file,
a PDF and multiple files. Confirm preview type, filename, cancellation and
explicit send. Paste text over a selection and confirm cursor placement. On
Android use a document provider URI; on Wayland copy from a file manager; on
iOS check paste privacy denial and file-provider permissions. Inspect a sent
event to confirm `msgtype`, MIME and size, including in an encrypted room.
