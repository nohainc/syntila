import 'dart:convert';

import 'package:web/web.dart' as web;

const _key = 'syntila-plan-decisions-v1';

List<String> readPlanDecisions() {
  try {
    final raw = web.window.localStorage.getItem(_key);
    final decoded = raw == null ? null : jsonDecode(raw);
    return decoded is List ? decoded.whereType<String>().toList() : [];
  } catch (_) {
    return [];
  }
}

void writePlanDecisions(List<String> ids) {
  try {
    web.window.localStorage.setItem(_key, jsonEncode(ids));
  } catch (_) {
    // Storage can be disabled or full; the decision lasts for this session.
  }
}
