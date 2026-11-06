import 'package:syntila_cli_worker_engine/src/mcp_schema_validation.dart';
import 'package:test/test.dart';

void main() {
  test('validates local references and rejects invalid values', () async {
    final schema = {
      'type': 'object',
      r'$defs': {
        'value': {'type': 'integer'},
      },
      'properties': {
        'count': {r'$ref': r'#/$defs/value'},
      },
      'required': ['count'],
    };
    expect(
      await validateMcpSchema(schema, {'count': 3}),
      McpSchemaResult.valid,
    );
    expect(
      await validateMcpSchema(schema, {'count': 'bad'}),
      McpSchemaResult.invalid,
    );
  });

  test(
    'refuses remote references, invalid schemas, and exhausted budgets',
    () async {
      expect(
        await validateMcpSchema({r'$ref': 'https://example.com/schema'}, {}),
        McpSchemaResult.unsupported,
      );
      expect(
        await validateMcpSchema({'type': 'not-a-type'}, {}),
        McpSchemaResult.unsupported,
      );
      expect(
        await validateMcpSchema({'type': 'object'}, {}, budget: Duration.zero),
        McpSchemaResult.unsupported,
      );
    },
  );
}
