import 'package:web/web.dart' as web;

import 'ax_thread_view_state_store_base.dart';
import 'ax_thread_view_state_store_kv.dart';

AxThreadViewStateStore createAxThreadViewStateStore() =>
    KeyValueAxThreadViewStateStore(_LocalStorage());

/// Browser-local persistence for Thread view state. Cloud never sees this.
class _LocalStorage implements AxKeyValueStorage {
  web.Storage get _storage => web.window.localStorage;

  @override
  String? get(String key) => _storage.getItem(key);

  @override
  void set(String key, String value) => _storage.setItem(key, value);

  @override
  void remove(String key) => _storage.removeItem(key);

  @override
  List<String> keys() => [
        for (var i = 0; i < _storage.length; i++)
          if (_storage.key(i) case final key?) key,
      ];
}
