import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Canonical JSON: keys sorted recursively, no insignificant whitespace.
String canonicalJson(Object? value) {
  Object? norm(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return {for (final k in keys) k: norm(v[k])};
    }
    if (v is List) return v.map(norm).toList();
    return v;
  }

  return jsonEncode(norm(value));
}

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();
