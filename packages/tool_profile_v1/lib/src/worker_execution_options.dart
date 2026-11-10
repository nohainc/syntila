import 'model_selection_mapping.dart';

/// Generic selection rules; provider argument mapping remains inside the Profile.
class ProfileExecutionOptions {
  ProfileExecutionOptions(this.model);
  final Map<String, Object?> model;
  Map<String, Object?> get declaration => model['executionOptions'] is Map
      ? Map<String, Object?>.from(model['executionOptions'] as Map)
      : const {};
  bool get modelSwitchSupported => declaration['modelSwitchSupported'] != false;
  List<String> effortsFor(String? modelId) {
    if (declaration['effortSupported'] == false) return const [];
    modelId ??= declaration['defaultModelId'] as String?;
    final catalog = model['catalog'];
    if (catalog is List) {
      for (final entry in catalog) {
        if (entry is Map &&
            entry['id'] == modelId &&
            entry.containsKey('supportedReasoningEfforts')) {
          return (entry['supportedReasoningEfforts'] as List).cast<String>();
        }
      }
    }
    return (model['supportedReasoningEfforts'] as List? ?? const [])
        .cast<String>();
  }

  bool acceptsEffort(String? modelId, String? effort) =>
      effort == null || effortsFor(modelId).contains(effort);
  String mapEffort(String effort) {
    final mapping = declaration['effortMapping'];
    return mapping is Map && mapping[effort] is String
        ? mapping[effort] as String
        : effort;
  }

  void validate({required bool durableSessions}) {
    void fail() =>
        throw const FormatException('Invalid Profile execution options');
    bool validEffortProbe(Object? raw) {
      if (raw == null) return true;
      if (raw is! Map ||
          raw.keys.any((key) =>
              !const {'arguments', 'timeoutMs', 'format'}.contains(key)) ||
          raw['format'] != 'use_one_of' ||
          raw['timeoutMs'] is! int ||
          (raw['timeoutMs'] as int) < 100 ||
          (raw['timeoutMs'] as int) > 10000) return false;
      final args = raw['arguments'];
      return args is List &&
          args.isNotEmpty &&
          args.length <= 32 &&
          args.every((v) =>
              v is String &&
              v.isNotEmpty &&
              v.length <= 256 &&
              !RegExp(r'[\x00-\x1f\x7f]').hasMatch(v)) &&
          args.any((v) => (v as String).contains('{{model}}'));
    }

    List<String> values(Object? raw, {int limit = 16}) {
      if (raw == null) return const [];
      if (raw is! List ||
          raw.length > limit ||
          raw.any((v) => v is! String || v.trim().isEmpty || v.length > 64))
        fail();
      final result = (raw as List).cast<String>();
      if (result.toSet().length != result.length) fail();
      return result;
    }

    if (model['selectionMode'] != null &&
        !const {'separate', 'combined'}.contains(model['selectionMode']))
      fail();
    final selections = parseModelSelectionMapping(model['selectionMapping']);
    final derivesEffortVariants = model['discovery'] is Map &&
        (model['discovery'] as Map)['effortVariants'] != null;
    if ((selections.isNotEmpty || derivesEffortVariants) &&
        (model['selectionMode'] != 'combined' ||
            model['supported'] != true ||
            model['discovery'] == null ||
            declaration['effortSupported'] == false)) fail();
    final discovery = model['discovery'];
    if (discovery != null) {
      if (discovery is! Map ||
          discovery.keys.any((key) => !const {
                'schemaVersion',
                'arguments',
                'timeoutMs',
                'format',
                'idPrefix',
                'effortVariants',
                'excludeIds',
                'effortProbe'
              }.contains(key)) ||
          !validEffortProbe(discovery['effortProbe']) ||
          (selections.isNotEmpty && derivesEffortVariants) ||
          !validEffortVariants(discovery['effortVariants']) ||
          discovery['schemaVersion'] != 1 ||
          !const {
            'tsv',
            'codex_app_server',
            'clap_possible_values',
            'copilot_sdk_rpc',
            'claude_models_api',
            'indented_list'
          }.contains(discovery['format']) ||
          (discovery['excludeIds'] != null &&
              (discovery['excludeIds'] is! List ||
                  (discovery['excludeIds'] as List).length > 128 ||
                  (discovery['excludeIds'] as List).any((id) =>
                      id is! String || id.isEmpty || id.length > 160))) ||
          discovery['timeoutMs'] is! int ||
          (discovery['timeoutMs'] as int) < 100 ||
          (discovery['timeoutMs'] as int) > 10000 ||
          discovery['idPrefix'] is! String ||
          !RegExp(r'^(?:[A-Za-z0-9][A-Za-z0-9._-]{0,63})?$')
              .hasMatch(discovery['idPrefix'] as String) ||
          discovery['arguments'] is! List ||
          (discovery['arguments'] as List).isEmpty ||
          (discovery['arguments'] as List).length > 32 ||
          (discovery['arguments'] as List).any((v) =>
              v is! String ||
              v.isEmpty ||
              v.length > 256 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(v))) fail();
    }
    final allowlist = model['allowlist'];
    if (allowlist != null &&
        (allowlist is! List ||
            allowlist.length > 128 ||
            allowlist
                .any((id) => id is! String || id.isEmpty || id.length > 160)))
      fail();
    final global = values(model['supportedReasoningEfforts']);
    final supported = <String>{
      ...global,
      ...selections.expand((m) => m.variants.map((v) => v.effort))
    };
    final catalog = model['catalog'];
    if (catalog != null && (catalog is! List || catalog.length > 128)) fail();
    final ids = <String>{};
    for (final raw in catalog as List? ?? const []) {
      if (raw is! Map ||
          raw['id'] is! String ||
          (raw['id'] as String).isEmpty ||
          (raw['id'] as String).length > 160 ||
          raw['name'] is! String ||
          (raw['name'] as String).isEmpty ||
          (raw['name'] as String).length > 256 ||
          !ids.add(raw['id'] as String)) fail();
      final entry = raw as Map;
      final efforts = entry.containsKey('supportedReasoningEfforts')
          ? values(entry['supportedReasoningEfforts'])
          : global;
      supported.addAll(efforts);
      final defaultEffort =
          entry['defaultReasoningEffort'] ?? model['defaultReasoningEffort'];
      if (defaultEffort != null &&
          (defaultEffort is! String ||
              ((efforts.isNotEmpty ||
                      entry.containsKey('defaultReasoningEffort')) &&
                  !efforts.contains(defaultEffort)))) fail();
    }
    final defaultEffort = model['defaultReasoningEffort'];
    if (defaultEffort != null &&
        (defaultEffort is! String || !global.contains(defaultEffort))) fail();
    if (!model.containsKey('executionOptions')) return;
    if (model['executionOptions'] is! Map) fail();
    final options = declaration;
    if (options.keys.any((key) => !const {
              'schemaVersion',
              'discovery',
              'modelSwitchSupported',
              'effortSupported',
              'defaultModelId',
              'effortMapping'
            }.contains(key)) ||
        options['schemaVersion'] != 1 ||
        options['discovery'] != 'profile_catalog' ||
        options['modelSwitchSupported'] is! bool ||
        options['effortSupported'] is! bool) fail();
    if (options['modelSwitchSupported'] == true &&
        (model['supported'] != true || !durableSessions)) fail();
    final defaultModel = options['defaultModelId'];
    if (defaultModel != null &&
        (defaultModel is! String ||
            model['supported'] != true ||
            !ids.contains(defaultModel) ||
            (model['unknownModelPolicy'] == 'profile_allowlist' &&
                !(model['allowlist'] as List? ?? const [])
                    .contains(defaultModel)))) fail();
    final mapping = options['effortMapping'];
    if (mapping != null &&
        (mapping is! Map ||
            mapping.length > 128 ||
            mapping.entries.any((e) =>
                !supported.contains(e.key) ||
                e.value is! String ||
                (e.value as String).isEmpty ||
                (e.value as String).length > 256))) fail();
    if (options['effortSupported'] == false &&
        (supported.isNotEmpty || (mapping is Map && mapping.isNotEmpty)))
      fail();
    if (options['effortSupported'] == true && supported.isEmpty) fail();
  }
}

/// Declares how a discovery line names its effort, so no model list is signed.
///
/// The effort comes from the parenthesized label suffix (`Name (High)`); the
/// native ID must equal `<family><separator><effort>`.
bool validEffortVariants(Object? raw) =>
    raw == null ||
    (raw is Map &&
        raw.length == 2 &&
        raw['source'] == 'label_parenthesized_suffix' &&
        raw['separator'] is String &&
        RegExp(r'^[-_.:]$').hasMatch(raw['separator'] as String));
