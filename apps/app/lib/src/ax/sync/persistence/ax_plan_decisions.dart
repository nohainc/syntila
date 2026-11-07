import 'ax_plan_decisions_stub.dart'
    if (dart.library.js_interop) 'ax_plan_decisions_web.dart' as platform;

/// Plan responses the user already approved, revised or cancelled. Their
/// approval card never shows again; kept across reloads on this browser.
class AxPlanDecisions {
  AxPlanDecisions._();

  static const _limit = 500;
  static List<String>? _ids;

  static List<String> get _decided => _ids ??= platform.readPlanDecisions();

  static bool isDecided(String requestId) => _decided.contains(requestId);

  static void markDecided(String requestId) {
    final ids = _decided;
    if (ids.contains(requestId)) return;
    ids.add(requestId);
    if (ids.length > _limit) ids.removeRange(0, ids.length - _limit);
    platform.writePlanDecisions(ids);
  }
}
