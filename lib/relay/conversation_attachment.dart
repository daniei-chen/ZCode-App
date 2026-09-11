import 'dart:typed_data';

/// A file explicitly selected by the user for one conversation input.
///
/// Keeping bytes in memory makes the upload scope unambiguous: nothing is
/// scanned or uploaded until the user presses Send.
class ConversationAttachment {
  const ConversationAttachment({
    required this.fileName,
    required this.mime,
    required this.bytes,
  });

  final String fileName;
  final String mime;
  final Uint8List bytes;

  int get size => bytes.length;
}
