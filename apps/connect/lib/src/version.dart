// Release builds supply the Git-derived version; source runs use this fallback.
const connectVersion = String.fromEnvironment(
  'SYNTILA_CONNECT_VERSION',
  defaultValue: '0.2.2',
);
