import 'package:web/web.dart' as web;

import 'view_preferences.dart';

const _key = 'syntila-view-v1';

ViewPreferencesStore createViewPreferencesStore() => ViewPreferencesStore(
      read: () => web.window.localStorage.getItem(_key),
      write: (value) => web.window.localStorage.setItem(_key, value),
    );
