import 'dart:convert';

/// Unpadded base64url, the encoding the server uses for keys, signatures and
/// pairing material.
String toBase64Url(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

List<int> fromBase64Url(String text) {
  final padding = (4 - text.length % 4) % 4;
  return base64Url.decode(text + '=' * padding);
}
