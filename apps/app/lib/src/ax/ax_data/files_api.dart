part of '../ax_data.dart';

mixin _FilesApi on _AxApiClientCore implements AxUserFilesDataSource {
  @override
  Future<AxUserFilesPage> loadUserFiles({String? before}) async {
    final body = await _getJson(Uri.parse('$baseUrl/files')
        .replace(queryParameters: before == null ? null : {'before': before}));
    final usage = body['usage'];
    return AxUserFilesPage(
      files: (body['files'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => AxUserFile.fromJson(Map<String, dynamic>.from(item)))
          .toList(),
      usage: AxStorageUsage.fromJson(
          usage is Map ? Map<String, dynamic>.from(usage) : const {}),
      nextCursor: body['nextCursor']?.toString(),
    );
  }

  @override
  Future<List<int>> downloadUserFile(String fileId) async {
    final response = await client.get(
      Uri.parse('$baseUrl/files/${Uri.encodeComponent(fileId)}'),
      headers: _headers(),
    );
    if (response.statusCode != 200) {
      throw AxApiException('Downloading the file failed',
          statusCode: response.statusCode);
    }
    return response.bodyBytes;
  }

  @override
  Future<void> syncUserFiles() async {
    Map<String, String>? params;
    do {
      final response = await client.post(
        Uri.parse('$baseUrl/files/sync').replace(queryParameters: params),
        headers: _headers(),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AxApiException('Synchronizing files failed',
            statusCode: response.statusCode);
      }
      final body = jsonDecode(response.body) as Map;
      final next = body['next'] as Map?;
      params =
          next?.map((key, value) => MapEntry(key.toString(), value.toString()));
    } while (params != null);
  }

  @override
  Future<AxStorageUsage> deleteUserFile(String fileId) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/files/${Uri.encodeComponent(fileId)}'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Deleting the file failed',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final usage = body is Map ? body['usage'] : null;
    if (usage is! Map) throw const AxApiException('File response is malformed');
    return AxStorageUsage.fromJson(Map<String, dynamic>.from(usage));
  }
}
