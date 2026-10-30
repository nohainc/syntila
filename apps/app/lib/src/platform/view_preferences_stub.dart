import 'view_preferences.dart';

ViewPreferencesStore createViewPreferencesStore() {
  String? value;
  return ViewPreferencesStore(read: () => value, write: (next) => value = next);
}
