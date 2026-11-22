part of '../ax_data.dart';

mixin _ThreadApi on _AxApiClientCore implements AxThreadReadDataSource {
  final _workRequestReads = <(String, int), Future<Map<String, dynamic>>>{};

  Future<Map<String, dynamic>> _readWorkRequest(String id) async {
    final key = (id, _readGeneration);
    final pending = _workRequestReads[key];
    if (pending != null) return pending;
    final read = _getJson(Uri.parse('$baseUrl/work-requests/$id'));
    _workRequestReads[key] = read;
    try {
      return await read;
    } finally {
      if (identical(_workRequestReads[key], read)) {
        _workRequestReads.remove(key);
      }
    }
  }

  @override
  Future<List<AxThread>> loadSpaceThreads({
    required String spaceId,
  }) async {
    final body = await _getJson(Uri.parse('$baseUrl/spaces/$spaceId/threads'),
        conditional: true);
    final list = body['threads'];
    return (list as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxThread.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<AxThread> createThread({
    required String spaceId,
    required String name,
    String? idempotencyKey,
  }) async {
    // One key for both attempts: the retry must replay, not create again.
    final key = idempotencyKey ?? newAxIdempotencyKey();
    final response = await _retryOnceIfBusy(() => client.post(
          Uri.parse('$baseUrl/spaces/$spaceId/threads'),
          headers: {
            ..._headers(contentType: 'application/json'),
            'Idempotency-Key': key
          },
          body: jsonEncode({'name': name}),
        ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Thread creation failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final thread = body is Map ? (body['thread']) : null;
    if (thread is! Map) {
      throw const AxApiException('Thread creation response is malformed');
    }
    return AxThread.fromJson(Map<String, dynamic>.from(thread));
  }

  @override
  Future<void> markThreadRead(String threadId) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/read'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Marking Thread read failed',
          statusCode: response.statusCode);
    }
  }

  Future<List<AxThreadReadState>> loadThreadReadStates(String threadId) async {
    final body = await _getJson(Uri.parse(
        '$baseUrl/threads/${Uri.encodeComponent(threadId)}/read-states'));
    return [
      for (final item in (body['readStates'] as List? ?? const []))
        if (item is Map)
          if (AxThreadReadState.fromJson(Map<String, dynamic>.from(item))
              case final state?)
            state,
    ];
  }

  Future<bool> loadShareReadReceipts() async {
    final body = await _getJson(Uri.parse('$baseUrl/me/privacy'));
    return body['shareReadReceipts'] != false;
  }

  Future<void> setShareReadReceipts(bool share) async {
    final response = await client.put(Uri.parse('$baseUrl/me/privacy'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'shareReadReceipts': share}));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Saving read receipts failed',
          statusCode: response.statusCode);
    }
  }

  Future<void> setPinned(
      {required String kind, required String id, required bool pinned}) async {
    final uri = Uri.parse(
        '$baseUrl/pins/${Uri.encodeComponent(kind)}/${Uri.encodeComponent(id)}');
    final response = pinned
        ? await client.put(uri, headers: _headers())
        : await client.delete(uri, headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Updating the pin failed',
          statusCode: response.statusCode);
    }
  }

  Future<void> setPinOrder(
      {required String kind,
      required List<String> ids,
      String? spaceId}) async {
    final response = await client.put(
      Uri.parse('$baseUrl/pins/order'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(
          {'kind': kind, 'ids': ids, if (spaceId != null) 'spaceId': spaceId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Reordering pins failed',
          statusCode: response.statusCode);
    }
  }

  Future<List<Map<String, dynamic>>> loadNotificationFeed() async {
    final body = await _getJson(Uri.parse('$baseUrl/notifications'));
    return (body['notifications'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> markNotificationsRead({List<String>? ids}) async {
    // The server takes at most 500 ids per call; null marks all.
    const chunk = 200;
    final batches = ids == null
        ? const <List<String>?>[null]
        : [
            for (var i = 0; i < ids.length; i += chunk)
              ids.sublist(i, i + chunk > ids.length ? ids.length : i + chunk),
          ];
    for (final batch in batches) {
      final response = await client.post(
        Uri.parse('$baseUrl/notifications/read'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({if (batch != null) 'ids': batch}),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AxApiException('Marking notifications read failed',
            statusCode: response.statusCode);
      }
    }
  }

  @override
  Future<AxThread> updateThread({
    required String threadId,
    String? name,
    String? status,
    Map<String, dynamic>? workConfig,
    Map<String, dynamic>? metadata,
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/threads/$threadId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        if (name != null) 'name': name,
        if (status != null) 'status': status,
        if (workConfig != null) 'workConfig': workConfig,
        if (metadata != null) 'metadata': metadata,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message when the server response is not JSON.
      }
      throw AxApiException(
        'Thread update failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final thread = body is Map ? (body['thread']) : null;
    if (thread is! Map) {
      throw const AxApiException('Thread update response is malformed');
    }
    return AxThread.fromJson(Map<String, dynamic>.from(thread));
  }

  @override
  Future<void> deleteThread({required String threadId}) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/threads/$threadId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Thread deletion failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> clearThreadChatHistory({required String threadId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/chat/clear'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message for non-JSON responses.
      }
      throw AxApiException(
        'Clear chat history failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<String?> clearThreadWorkHistory({required String threadId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-history/clear'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep the status-only message for non-JSON responses.
      }
      throw AxApiException(
        'Clear work history failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final cutoff = body is Map ? body['aiHistoryClearedAt'] : null;
    if (cutoff is! String || DateTime.tryParse(cutoff) == null) {
      throw const AxApiException('Malformed AI History cutoff');
    }
    return cutoff;
  }

  /// Sends one picked file (raw bytes, or multipart with its JPEG preview).
  /// Shared by Work inputs and discussion uploads.
  Future<http.Response> _sendFileUpload(
      String method, Uri url, Map<String, dynamic> attachment) async {
    final encoded = attachment['contentBase64'];
    if (encoded is! String) {
      throw const AxApiException('Attached file content is missing');
    }
    final preview = attachment['previewImage'];
    final mediaType =
        attachment['mediaType']?.toString() ?? 'application/octet-stream';
    // A multipart body (the only way to carry a preview) is buffered by Cloud,
    // so only files within the Free size use it. Larger files go as a raw
    // streamed body, without a preview.
    if (preview is String &&
        (attachment['sizeBytes'] as int? ?? 0) <=
            AxAttachmentPolicy.freeFileBytes) {
      final request = http.MultipartRequest(method, url)
        ..headers.addAll(_headers())
        ..fields['mediaType'] = mediaType
        ..fields['previewImage'] = preview
        ..files.add(http.MultipartFile.fromBytes('file', base64Decode(encoded),
            filename: attachment['name']?.toString() ?? 'Attachment'));
      return http.Response.fromStream(await client.send(request));
    }
    final request = http.Request(method, url)
      ..headers.addAll(_headers(contentType: mediaType))
      ..bodyBytes = base64Decode(encoded);
    return http.Response.fromStream(await client.send(request));
  }

  /// Runs [send] until it succeeds, restarting the whole file each time.
  /// Client errors other than timeouts and throttling are final.
  Future<http.Response> _uploadWithRetries(
      Future<http.Response> Function() send,
      {int attempts = 3}) async {
    for (var attempt = 1;; attempt++) {
      http.Response? response;
      Object? failure;
      try {
        response = await send();
      } on AxApiException {
        rethrow;
      } on Object catch (error) {
        failure = error;
      }
      if (response != null) {
        final code = response.statusCode;
        final retryable = code >= 500 || code == 408 || code == 429;
        if ((code >= 200 && code < 300) || !retryable || attempt >= attempts) {
          return response;
        }
      } else if (attempt >= attempts) {
        throw AxApiException('File upload failed: $failure');
      }
      await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
    }
  }

  static String _uploadFailure(http.Response response) {
    dynamic body;
    try {
      body = jsonDecode(response.body);
    } on FormatException {
      body = null;
    }
    final detail =
        body is Map && body['error'] is String ? ': ${body['error']}' : '';
    return 'File upload failed (${response.statusCode})$detail';
  }

  /// Uploads picked discussion files to Cloud storage, in parallel, and
  /// returns file references. An in-memory cache reuses uploads for retries
  /// of the same picked file, retaining a stable file reference and
  /// idempotent request body.
  Future<List<Map<String, dynamic>>> _uploadWorkRequestFiles(
      String threadId, List<Map<String, dynamic>> attachments,
      {bool discussion = false}) async {
    return Future.wait(attachments.map((attachment) async {
      if (attachment['kind'] != 'file') return attachment;
      // A cheap identity for the picked file: never serialize its bytes.
      final content = attachment['contentBase64']?.toString() ?? '';
      final uploadKey = jsonEncode([
        threadId,
        attachment['name'],
        attachment['mediaType'],
        attachment['sizeBytes'],
        content.length,
        content.hashCode,
        attachment['fileId'],
      ]);
      var fileId = attachment['fileId'] is String
          ? attachment['fileId'] as String
          : _uploadedWorkFiles[uploadKey];
      if (fileId == null) {
        final name = Uri.encodeQueryComponent(
            attachment['name']?.toString() ?? 'Attachment');
        final url = Uri.parse(
            '$baseUrl/threads/$threadId/work-request-files?name=$name${discussion ? "&purpose=discussion" : ""}');
        final response = await _uploadWithRetries(
            () => _sendFileUpload('POST', url, attachment));
        dynamic body;
        try {
          body = jsonDecode(response.body);
        } on FormatException {
          body = null;
        }
        final file = body is Map ? body['file'] : null;
        if (response.statusCode < 200 ||
            response.statusCode >= 300 ||
            file is! Map ||
            file['fileId'] is! String) {
          throw AxApiException(_uploadFailure(response),
              statusCode: response.statusCode);
        }
        fileId = file['fileId'] as String;
        // Bound the in-memory cache; it is never persisted and clears on auth change.
        if (_uploadedWorkFiles.length >= 20) {
          _uploadedWorkFiles.remove(_uploadedWorkFiles.keys.first);
        }
        _uploadedWorkFiles[uploadKey] = fileId;
      }
      return <String, dynamic>{
        'kind': 'file',
        'name': attachment['name'],
        'mediaType': attachment['mediaType'],
        'sizeBytes': attachment['sizeBytes'],
        'fileId': fileId,
      };
    }));
  }

  // Shared Thread request queue.

  Future<Map<String, dynamic>> _queuedRequestBody({
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    required List<Map<String, dynamic>> attachments,
    required Map<String, dynamic> executionSelection,
    required AxReplyReference? replyTo,
  }) async =>
      {
        'workflowId': workflowId,
        'workflowVersion': workflowVersion,
        ...await _executionFields(executionSelection),
        'input': {
          'originalRequest': prompt,
          'attachments': _workRequestManifest(attachments),
          if (replyTo != null) 'replyTo': replyTo.target,
        },
        // Display only: Cloud builds the reply snapshot from the target.
        if (replyTo != null) 'replyReference': replyTo.toJson(),
      };

  Future<AxThreadQueue> _queueCall(String method, String threadId,
      {String path = '', Map<String, dynamic>? body}) async {
    final request = http.Request(
        method,
        Uri.parse(
            '$baseUrl/threads/${Uri.encodeComponent(threadId)}/queue$path'))
      ..headers.addAll(
          _headers(contentType: body == null ? null : 'application/json'));
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(await client.send(request));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          detail = decoded['error'] as String;
        }
      } on FormatException {
        /* Keep the status-only message. */
      }
      throw AxApiException(
          detail.isEmpty
              ? 'Request queue update failed (${response.statusCode})'
              : detail,
          statusCode: response.statusCode);
    }
    return AxThreadQueue.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  Future<AxThreadQueue> loadThreadQueue(String threadId) =>
      _queueCall('GET', threadId);

  Future<AxThreadQueue> enqueueThreadRequest({
    required String threadId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
    List<String>? beforeItemIds,
    List<String>? afterItemIds,
  }) async =>
      _queueCall('POST', threadId, body: {
        'request': await _queuedRequestBody(
            workflowId: workflowId,
            workflowVersion: workflowVersion,
            prompt: prompt,
            attachments: attachments,
            executionSelection: executionSelection,
            replyTo: replyTo),
        if (beforeItemIds != null) 'beforeItemIds': beforeItemIds,
        if (afterItemIds != null) 'afterItemIds': afterItemIds,
      });

  Future<AxThreadQueue> updateThreadQueueItem({
    required String threadId,
    required String itemId,
    required String workflowId,
    required int workflowVersion,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    AxReplyReference? replyTo,
  }) async =>
      _queueCall('PUT', threadId,
          path: '/${Uri.encodeComponent(itemId)}',
          body: {
            'request': await _queuedRequestBody(
                workflowId: workflowId,
                workflowVersion: workflowVersion,
                prompt: prompt,
                attachments: attachments,
                executionSelection: executionSelection,
                replyTo: replyTo),
          });

  Future<AxThreadQueue> removeThreadQueueItem(String threadId, String itemId) =>
      _queueCall('DELETE', threadId, path: '/${Uri.encodeComponent(itemId)}');

  Future<AxThreadQueue> stopThreadQueuePhases(String threadId, String itemId) =>
      _queueCall('POST', threadId,
          path: '/${Uri.encodeComponent(itemId)}/stop-phases');

  Future<AxThreadQueue> sendThreadQueueItemNow(
          String threadId, String itemId) =>
      _queueCall('POST', threadId,
          path: '/${Uri.encodeComponent(itemId)}/send-now');

  Future<AxThreadQueue> setThreadQueuePaused(String threadId, bool paused) =>
      _queueCall('POST', threadId, path: paused ? '/pause' : '/resume');

  /// Input Delivery v1 manifest entries: picked files are uploaded after the
  /// request is accepted, so only their metadata is submitted.
  static List<Map<String, dynamic>> _workRequestManifest(
          List<Map<String, dynamic>> attachments) =>
      [
        for (final attachment in attachments)
          if (attachment['kind'] == 'file' &&
              attachment['fileId'] == null &&
              attachment['contentBase64'] is String)
            {
              'kind': 'file',
              'name': attachment['name'],
              'mediaType': attachment['mediaType'],
              'sizeBytes': attachment['sizeBytes'],
              'delivery': 'upload',
            }
          else
            attachment,
      ];

  /// Starts uploading the accepted request's files in the background and
  /// follows their delivery to the Workspace.
  void _startInputDelivery(
      Object? workRequest, List<Map<String, dynamic>> attachments) {
    if (workRequest is! Map) return;
    final id = workRequest['id'];
    final input = workRequest['input'];
    final accepted = input is Map ? input['attachments'] : null;
    if (id is! String || accepted is! List) return;
    final uploads = <AxPendingInputUpload>[];
    final local = <String, Map<String, dynamic>>{};
    for (var index = 0;
        index < attachments.length && index < accepted.length;
        index++) {
      final picked = attachments[index];
      final saved = accepted[index];
      if (picked['kind'] != 'file' ||
          picked['contentBase64'] is! String ||
          picked['fileId'] != null ||
          saved is! Map ||
          saved['fileId'] is! String) {
        continue;
      }
      final fileId = saved['fileId'] as String;
      local[fileId] = picked;
      uploads.add(AxPendingInputUpload(
          fileId: fileId, name: picked['name']?.toString() ?? 'Attachment'));
    }
    if (uploads.isEmpty) return;
    unawaited(AxInputDelivery.instance.start(
      workRequestId: id,
      files: uploads,
      upload: (fileId) async {
        final response = await _uploadWithRetries(
            () => _sendFileUpload(
                'PUT',
                Uri.parse('$baseUrl/work-requests/$id/inputs/$fileId'),
                local[fileId]!),
            attempts: 1);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw AxApiException(_uploadFailure(response),
              statusCode: response.statusCode);
        }
      },
      reportUploadFailure: (fileId, message) async {
        await client.post(
          Uri.parse('$baseUrl/work-requests/$id/inputs/$fileId/failed'),
          headers: _headers(contentType: 'application/json'),
          body: jsonEncode({'message': message}),
        );
      },
      loadDelivery: () async {
        final body = await _readWorkRequest(id);
        final request = body['workRequest'];
        if (request is! Map) return null;
        final status = request['status'];
        final inputs = request['inputs'];
        if (inputs is! List) return null;
        final states = [
          for (final item in inputs)
            if (item is Map && item['fileId'] is String)
              AxDeliveredInputState(
                fileId: item['fileId'] as String,
                state: item['state']?.toString() ?? '',
                deliveryAttempts: item['deliveryAttempts'] is int
                    ? item['deliveryAttempts'] as int
                    : 0,
                errorMessage: item['errorMessage'] as String?,
              )
        ];
        // A request that ended stops tracking after this update.
        return status == 'cancelled' ? null : states;
      },
    ));
  }

  @override
  Future<String> createWorkRequest({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
  }) async {
    final submissionId = idempotencyKey ?? newAxIdempotencyKey();
    AxWorkLatencyTrace.instance.submitted(submissionId);
    final picked = attachments;
    final response = await _retryOnceIfBusy(() => client.post(
          Uri.parse('$baseUrl/threads/$threadId/work-requests'),
          headers: {
            ..._headers(contentType: 'application/json'),
            'Idempotency-Key': submissionId
          },
          body: jsonEncode({
            'workflowId': workflowId,
            'input': {
              'originalRequest': prompt,
              'attachments': _workRequestManifest(picked)
            },
          }),
        ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      AxWorkLatencyTrace.instance.failed(submissionId);
      if (response.statusCode == 422) {
        try {
          final body = jsonDecode(response.body);
          if (body is Map && body['issues'] is List) {
            final name = body['workflowName']?.toString() ?? workflowId;
            final messages = (body['issues'] as List)
                .whereType<Map>()
                .map((issue) => issue['message'])
                .whereType<String>()
                .toList(growable: false);
            if (messages.isNotEmpty) {
              throw AxApiException(
                'Cannot run $name\n${messages.map((message) => '• $message').join('\n')}',
                statusCode: 422,
              );
            }
          }
        } on AxApiException {
          rethrow;
        } on FormatException {
          // Fall through to the status-only error below.
        }
      }
      String detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
      } on FormatException {
        /* Preserve status when the server returns no JSON. */
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    AxWorkLatencyTrace.instance.accepted(submissionId, request['id'] as String);
    _startInputDelivery(request, picked);
    return request['id'] as String;
  }

  @override
  Future<String> createWorkRequestWithSelection({
    required String threadId,
    required String workflowId,
    required String prompt,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
    String? idempotencyKey,
    Map<String, dynamic>? replyTo,
  }) async {
    final submissionId = idempotencyKey ?? newAxIdempotencyKey();
    AxWorkLatencyTrace.instance.submitted(submissionId);
    final picked = attachments;
    final executionFields = await _executionFields(executionSelection);
    final response = await _retryOnceIfBusy(() => client.post(
          Uri.parse('$baseUrl/threads/$threadId/work-requests'),
          headers: {
            ..._headers(contentType: 'application/json'),
            'Idempotency-Key': submissionId
          },
          body: jsonEncode({
            'workflowId': workflowId,
            ...executionFields,
            'input': {
              'originalRequest': prompt,
              'attachments': _workRequestManifest(picked),
              if (replyTo != null) 'replyTo': replyTo,
            },
          }),
        ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      AxWorkLatencyTrace.instance.failed(submissionId);
      var detail = '';
      String? code;
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['error'] is String) {
          detail = ': ${body['error']}';
        }
        if (body is Map && body['code'] is String) {
          code = body['code'] as String;
        }
      } on FormatException {
        /* Preserve status when the server returns no JSON. */
      }
      if (code == spaceFolderRequiredCode ||
          code == workerNotOnFolderDeviceCode) {
        // The reason is the message: it tells the person what to do next.
        throw AxApiException(
          (jsonDecode(response.body) as Map)['error'] as String,
          statusCode: response.statusCode,
          code: code,
        );
      }
      throw AxApiException(
        'Work request failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
        code: code,
      );
    }
    final body = jsonDecode(response.body);
    final request = body is Map ? body['workRequest'] : null;
    if (request is! Map || request['id'] is! String) {
      throw const AxApiException('Work request response is malformed');
    }
    AxWorkLatencyTrace.instance.accepted(submissionId, request['id'] as String);
    _startInputDelivery(request, picked);
    return request['id'] as String;
  }

  @override
  Future<List<String>> validateWorkRequestEligibility({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests/validate'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        'attachments': attachments
            .map((attachment) => {
                  'kind': attachment['kind'],
                  'mediaType': attachment['mediaType'],
                })
            .toList(growable: false),
      }),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const AxApiException('Work eligibility response is malformed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // The Cloud validator returns structured eligibility issues for 422.
      // Preserve those messages so the Work composer can tell the user what
      // needs to be fixed (for example, selecting a Workspace or restoring a
      // Worker grant) instead of reducing the response to a status code.
      if (decoded is Map && decoded['issues'] is List) {
        final messages = (decoded['issues'] as List)
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .where((message) => message.trim().isNotEmpty)
            .toList(growable: false);
        if (messages.isNotEmpty) return messages;
      }
      throw AxApiException(
        _eligibilityFailureMessage(response.statusCode, decoded),
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map) {
      throw const AxApiException('Work eligibility response is malformed');
    }
    final issues = decoded['issues'];
    if (issues is! List) return const [];
    return issues
        .whereType<Map>()
        .map((issue) => issue['message'])
        .whereType<String>()
        .toList(growable: false);
  }

  @override
  Future<List<String>> validateWorkRequestEligibilityWithSelection({
    required String threadId,
    required String workflowId,
    List<Map<String, dynamic>> attachments = const [],
    Map<String, dynamic> executionSelection = const {},
  }) async {
    final executionFields = await _executionFields(executionSelection);
    final response = await client.post(
      Uri.parse('$baseUrl/threads/$threadId/work-requests/validate'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'workflowId': workflowId,
        ...executionFields,
        'attachments': attachments
            .map((attachment) => {
                  'kind': attachment['kind'],
                  'mediaType': attachment['mediaType'],
                })
            .toList(growable: false),
      }),
    );
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const AxApiException('Work eligibility response is malformed');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (decoded is Map && decoded['issues'] is List) {
        final messages = (decoded['issues'] as List)
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .where((message) => message.trim().isNotEmpty)
            .toList(growable: false);
        if (messages.isNotEmpty) return messages;
      }
      throw AxApiException(
          _eligibilityFailureMessage(response.statusCode, decoded),
          statusCode: response.statusCode);
    }
    final issues = decoded is Map ? decoded['issues'] : null;
    return issues is List
        ? issues
            .whereType<Map>()
            .map((issue) => issue['message'])
            .whereType<String>()
            .toList(growable: false)
        : const [];
  }

  @override
  Future<AxConversationHistoryPage> loadConversationHistory(
      {required String threadId,
      required String conversationId,
      String? cursor,
      int limit = 50}) async {
    final uri = Uri.parse(
            '$baseUrl/threads/${Uri.encodeComponent(threadId)}/conversations/${Uri.encodeComponent(conversationId)}/history')
        .replace(queryParameters: {
      'limit': '$limit',
      if (cursor != null) 'cursor': cursor,
    });
    final body = await _getJson(uri);
    final page = AxConversationHistoryPage.fromJson(body);
    if (page.conversationId != conversationId) {
      throw const AxApiException('Malformed Conversation history scope');
    }
    return page;
  }

  @override
  Future<AxWorkRequestStatus> loadWorkRequest({
    required String workRequestId,
  }) async {
    final body = await _readWorkRequest(workRequestId);
    final request = body['workRequest'];
    final result = body['result'];
    final resultMap = result is Map
        ? Map<String, dynamic>.from(result)
        : const <String, dynamic>{};
    final requestMap = request is Map
        ? Map<String, dynamic>.from(request)
        : const <String, dynamic>{};
    final steps = (body['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorkRequestStep.fromJson(
              Map<String, dynamic>.from(item),
            ))
        .toList(growable: false);
    final activityHistory = (requestMap['activities'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
    if (requestMap['id'] != workRequestId || requestMap['status'] is! String) {
      throw const AxApiException('Malformed Work Request detail');
    }
    return AxWorkRequestStatus(
      id: requestMap['id'] as String,
      conversationId: requestMap['conversationId'] as String?,
      workflowRun: requestMap['workflowRun'] is Map
          ? AxWorkflowRun.fromJson(
              Map<String, dynamic>.from(requestMap['workflowRun'] as Map))
          : null,
      turns: List.unmodifiable((requestMap['turns'] as List? ?? const [])
          .whereType<Map>()
          .map((item) =>
              AxConversationTurn.fromJson(Map<String, dynamic>.from(item)))),
      executionConfig: requestMap['executionConfig'] is Map
          ? AxTurnExecutionConfig.fromJson(
              Map<String, dynamic>.from(requestMap['executionConfig'] as Map))
          : null,
      threadId: (requestMap['threadId']) as String?,
      status: requestMap['status']?.toString() ?? 'unknown',
      isPhased: requestMap['isPhased'] == true,
      text: resultMap['text']?.toString(),
      errorCode: body['errorCode']?.toString(),
      errorMessage: body['errorMessage']?.toString(),
      error: body['errorCode'] is String
          ? 'Run failed (${body['errorCode']}).'
          : null,
      workflowId: requestMap['workflowId']?.toString(),
      workflowVersion: requestMap['workflowVersion'] as int?,
      workflowName: requestMap['workflowName']?.toString(),
      requestedByUserId: requestMap['requestedByUserId']?.toString(),
      requestedByName: requestMap['requestedByName']?.toString(),
      originalRequest: requestMap['originalRequest']?.toString(),
      replyTo: AxReplyReference.fromJson(requestMap['replyTo']),
      attachments: AxWorkAttachment.fromList(requestMap['attachments']),
      createdAt: requestMap['createdAt']?.toString(),
      steps: steps,
      activityHistory: activityHistory,
      executionPhase: requestMap['executionPhase']?.toString(),
    );
  }

  @override
  Future<void> retryWorkRequestStep({
    required String workRequestId,
    required String stepKind,
    String? stepId,
    String? sessionStrategy,
    bool clearAiHistory = false,
    bool compactContext = false,
    bool confirmSideEffects = false,
    bool partial = false,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/retry'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'stepKind': stepKind,
        // Selects one Research v2 researcher or the synthesis.
        if (stepId != null && stepId != stepKind) 'stepId': stepId,
        if (sessionStrategy != null) 'sessionStrategy': sessionStrategy,
        if (confirmSideEffects) 'confirmSideEffects': true,
        // Research v2: synthesize the reports that succeeded.
        if (partial) 'partial': true,
        if (clearAiHistory) 'clearAiHistory': true,
        if (compactContext) 'contextResolution': 'compact',
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final body = jsonDecode(response.body);
        if (body is Map) {
          final issues = body['issues'];
          final messages = issues is List
              ? issues
                  .whereType<Map>()
                  .map((issue) => issue['message'])
                  .whereType<String>()
                  .toList()
              : <String>[];
          final message = messages.isNotEmpty
              ? messages.join(' ')
              : body['message'] ?? body['error'];
          if (message is String) detail = ': $message';
        }
      } on Object {/* Keep status when the response is not JSON. */}
      throw AxApiException(
        'Step retry failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<void> cancelWorkRequest({required String workRequestId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/cancel'),
      headers: _headers(contentType: 'application/json'),
      body: '{}',
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Run cancellation failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<Map<String, dynamic>> approvePlan({
    required String workRequestId,
    String verificationMode = 'none',
    Map<String, dynamic>? implementer,
    Map<String, dynamic>? verifier,
  }) async {
    final response = await client.post(
      Uri.parse('$baseUrl/work-requests/$workRequestId/approve-plan'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'verificationMode': verificationMode,
        if (implementer != null) 'implementer': implementer,
        if (verifier != null) 'verifier': verifier,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        'Plan approval failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    return decoded is Map<String, dynamic>
        ? decoded
        : (decoded is Map ? Map<String, dynamic>.from(decoded) : const {});
  }

  @override
  Future<AxIssueReport?> loadIssueReport({
    required String requestId,
    String? assignmentId,
  }) async {
    final uri = Uri.parse('$baseUrl/issue-reports').replace(queryParameters: {
      'requestId': requestId,
      if (assignmentId != null && assignmentId.isNotEmpty)
        'assignmentId': assignmentId,
    });
    final body = await _getJson(uri);
    final report = body['report'];
    return report is Map
        ? AxIssueReport.fromJson(Map<String, dynamic>.from(report))
        : null;
  }

  @override
  Future<AxIssueReport> reportIssue({required String requestId}) async {
    final response = await client.post(
      Uri.parse('$baseUrl/issue-reports'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'requestId': requestId}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
        "Couldn't send the report. Try again.",
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(response.body);
    final report = decoded is Map ? decoded['report'] : null;
    if (report is! Map) {
      throw const AxApiException('Issue report response is malformed');
    }
    return AxIssueReport.fromJson(Map<String, dynamic>.from(report));
  }

  @override
  Future<AxWorkRequestPage> loadThreadWorkRequestPage(
      {required String threadId,
      int limit = 50,
      String? beforeCreatedAt,
      String? beforeId,
      bool activeOnly = false}) async {
    if (limit < 1 ||
        limit > 100 ||
        (beforeCreatedAt == null) != (beforeId == null) ||
        beforeCreatedAt == '' ||
        beforeId == '') {
      throw ArgumentError('Invalid Work history page parameters');
    }
    final uri = Uri.parse('$baseUrl/threads/$threadId/work-requests')
        .replace(queryParameters: {
      'limit': '$limit',
      if (activeOnly) 'activeOnly': 'true',
      if (beforeCreatedAt != null && beforeId != null)
        'cursor': AxWorkRequestCursor(createdAt: beforeCreatedAt, id: beforeId)
            .toWire(),
    });
    final body = await _getJson(uri);
    final raw = body['workRequests'];
    final rawCursor = body['nextCursor'];
    final cursor =
        rawCursor is String ? AxWorkRequestCursor.fromWire(rawCursor) : null;
    if (raw is! List ||
        raw.any((v) => v is! Map) ||
        (rawCursor != null && cursor == null)) {
      throw const AxApiException('Malformed Work history page');
    }
    final records = raw
        .map((v) => AxWorkRequest.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    if (records.any((v) => v.id.isEmpty || v.createdAt.isEmpty)) {
      throw const AxApiException('Malformed Work Request');
    }
    final clearedAt = body['aiHistoryClearedAt'];
    return AxWorkRequestPage(
        aiHistoryClearedAt: clearedAt is String ? clearedAt : null,
        requests: records.reversed,
        nextCursor: cursor);
  }

  @override
  Future<AxDiscussionPage> loadDiscussionPage(
      {required String threadId,
      int limit = 50,
      String? before,
      String? after}) async {
    if (limit < 1 || limit > 100 || (before != null && after != null)) {
      throw ArgumentError('Invalid Discussion page parameters');
    }
    final uri = Uri.parse('$baseUrl/threads/$threadId/discussion-messages')
        .replace(queryParameters: {
      'limit': '$limit',
      if (before != null) 'cursor': before,
      if (after != null) 'after': after
    });
    final body = await _getJson(uri);
    if (body['schemaVersion'] != 1 ||
        body['messages'] is! List ||
        (body['nextCursor'] != null && body['nextCursor'] is! String) ||
        (body['newestCursor'] != null && body['newestCursor'] is! String)) {
      final invalid = <String>[
        if (body['schemaVersion'] != 1)
          'expected schemaVersion 1, received ${body['schemaVersion'] ?? "missing"}',
        if (body['messages'] is! List) 'messages must be a list',
        if (body['nextCursor'] != null && body['nextCursor'] is! String)
          'nextCursor must be a string or null',
        if (body['newestCursor'] != null && body['newestCursor'] is! String)
          'newestCursor must be a string or null',
      ];
      throw AxApiException(
          'Discussion page response is malformed: ${invalid.join("; ")}');
    }
    final messages = (body['messages'] as List).map((item) {
      if (item is! Map) {
        throw const AxApiException('Discussion message is malformed');
      }
      final message =
          AxDiscussionMessage.fromJson(Map<String, dynamic>.from(item));
      if (message.id.isEmpty || message.threadId != threadId) {
        throw const AxApiException(
            'Discussion message identity does not match');
      }
      return message;
    });
    return AxDiscussionPage(
        messages: messages,
        nextCursor: body['nextCursor'] as String?,
        newestCursor: body['newestCursor'] as String?);
  }

  @override
  Future<List<int>> downloadThreadFile(String threadId, String fileId) async {
    final response = await client.get(
        Uri.parse('$baseUrl/threads/$threadId/files/$fileId'),
        headers: _headers());
    if (response.statusCode != 200) {
      throw AxApiException('File download failed (${response.statusCode})');
    }
    return response.bodyBytes;
  }

  @override
  Future<AxDiscussionMessage> sendDiscussionMessage({
    required String threadId,
    required String text,
    List<String> references = const [],
    List<Map<String, dynamic>> attachments = const [],
    String? idempotencyKey,
    Map<String, dynamic>? replyTo,
  }) async {
    attachments =
        await _uploadWorkRequestFiles(threadId, attachments, discussion: true);
    final key = idempotencyKey ?? newAxIdempotencyKey();
    final response = await _retryOnceIfBusy(() => client.post(
          Uri.parse('$baseUrl/threads/$threadId/discussion-messages'),
          headers: {
            ..._headers(contentType: 'application/json'),
            'Idempotency-Key': key
          },
          body: jsonEncode({
            'body': text,
            'attachments': attachments,
            'references': references,
            if (replyTo != null) 'replyTo': replyTo,
          }),
        ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message submission failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException('Discussion message response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<AxDiscussionMessage> loadDiscussionMessage(
      {required String messageId}) async {
    final response = await client.get(
        Uri.parse(
            '$baseUrl/discussion-messages/${Uri.encodeComponent(messageId)}'),
        headers: _headers());
    if (response.statusCode != 200) {
      throw AxApiException(
          'Discussion message loading failed (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map || message['id'] != messageId) {
      throw const AxApiException('Discussion message response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<AxDiscussionMessage> editDiscussionMessage({
    required String messageId,
    required String text,
    List<String> references = const [],
  }) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/discussion-messages/$messageId'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'body': text,
        'references': references,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message edit failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
    final body = jsonDecode(response.body);
    final message = body is Map ? body['message'] : null;
    if (message is! Map) {
      throw const AxApiException(
          'Discussion message edit response is malformed');
    }
    return AxDiscussionMessage.fromJson(Map<String, dynamic>.from(message));
  }

  @override
  Future<void> deleteDiscussionMessage({
    required String messageId,
  }) async {
    final response = await client.delete(
      Uri.parse('$baseUrl/discussion-messages/$messageId'),
      headers: _headers(),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      var detail = '';
      try {
        final errorBody = jsonDecode(response.body);
        if (errorBody is Map && errorBody['error'] is String) {
          detail = ': ${errorBody['error']}';
        }
      } on Object {
        // Keep status-only message
      }
      throw AxApiException(
        'Discussion message delete failed (${response.statusCode})$detail',
        statusCode: response.statusCode,
      );
    }
  }

  @override
  Future<List<AxWorker>> loadWorkspaceWorkerInventory() async {
    // Members also receive the Workers their Workspace owner shares with them.
    final body = await _getJson(
        Uri.parse('$baseUrl/workspace-workers?includeShared=true'));
    return (body['workers'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => AxWorker.fromJson(Map<String, dynamic>.from(item)))
        .toList();
  }

  @override
  Future<bool> workerIdentityEnabled() async {
    final features = await _getJson(Uri.parse('$baseUrl/features'));
    return (features['flags'] as List? ?? const []).contains('worker_identity');
  }

  @override
  Future<bool> workersUxEnabled() async {
    final features = await _getJson(Uri.parse('$baseUrl/features'));
    return (features['flags'] as List? ?? const []).contains('workers_ux');
  }

  bool? _workersUxCache;
  DateTime? _workersUxCachedAt;

  Future<bool> _workersUxCached() async {
    final at = _workersUxCachedAt;
    if (_workersUxCache != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _workersUxCache!;
    }
    final enabled = await workersUxEnabled();
    _workersUxCache = enabled;
    _workersUxCachedAt = DateTime.now();
    return enabled;
  }

  /// Execution fields of a Work Request body. With Workers UX on, the
  /// composer's selection is a Worker ID and travels as `workerId`; no
  /// Workspace selection is sent (ADR-035). Otherwise the legacy selection.
  Future<Map<String, dynamic>> _executionFields(
      Map<String, dynamic> selection) async {
    if (selection.isEmpty) return const {};
    final steps = selection['steps'];
    final researcherCount = selection['researcherCount'];
    if ((steps is Map && steps.isNotEmpty) || researcherCount is int) {
      // Per-step choices travel as Worker bindings keyed by step. Implement's
      // request only runs the plan step; implement and verify are chosen when
      // the plan is approved (see approvePlan). Research binds every step.
      if (!await _workersUxCached()) return const {};
      final implement = steps is Map && steps.containsKey('plan');
      final entries = steps is Map ? steps.entries : const <MapEntry>[];
      // Research binds each researcher by number, so the count must match.
      final bound = entries
          .map((entry) =>
              RegExp(r'^research-(\d+)$').firstMatch(entry.key.toString()))
          .whereType<RegExpMatch>()
          .map((match) => int.parse(match.group(1)!))
          .fold<int>(0, (a, b) => a > b ? a : b);
      final count =
          researcherCount is int ? researcherCount : (bound > 0 ? bound : null);
      return {
        if (count != null) 'researcherCount': count,
        'workerBindings': {
          for (final entry in entries)
            if ((!implement || entry.key == 'plan') &&
                entry.value is Map &&
                (entry.value as Map)['workerId'] is String &&
                ((entry.value as Map)['workerId'] as String).isNotEmpty)
              entry.key.toString(): {
                'workerId': (entry.value as Map)['workerId'],
                for (final key in const ['model', 'reasoningEffort'])
                  if ((entry.value as Map)[key] is String &&
                      ((entry.value as Map)[key] as String).isNotEmpty)
                    key: (entry.value as Map)[key],
              },
        },
      };
    }
    final workerId = selection['workerId'];
    if (workerId is String && workerId.isNotEmpty && await _workersUxCached()) {
      String? text(String key) {
        final value = selection[key];
        return value is String && value.isNotEmpty ? value : null;
      }

      return {
        'workerId': workerId,
        if (text('model') != null) 'model': text('model'),
        if (text('reasoningEffort') != null)
          'reasoningEffort': text('reasoningEffort'),
      };
    }
    return {'executionSelection': selection};
  }

  @override
  Future<List<String>> loadEligibleWorkerIds(
      String threadId, String workflowId) async {
    final uri = Uri.parse(
            '$baseUrl/threads/${Uri.encodeComponent(threadId)}/eligible-workers')
        .replace(queryParameters: {'workflowId': workflowId});
    final body = await _getJson(uri);
    final ids = body['workerIds'];
    if (ids is! List || ids.any((id) => id is! String)) {
      throw const AxApiException('Eligible Worker response is malformed');
    }
    return ids.cast<String>();
  }

  @override
  Future<List<WorkerInstance>> loadWorkerInstances() async {
    if (!await workerIdentityEnabled()) return const [];
    return parseWorkerInstances(await _getJson(Uri.parse('$baseUrl/workers')));
  }

  @override
  Future<List<({String id, String name})>> loadWorkerTypes() async {
    final body = await _getJson(Uri.parse('$baseUrl/workers/catalog'));
    return [
      for (final item in (body['workers'] as List? ?? const []))
        if (item is Map &&
            item['workerTypeId'] is String &&
            item['displayName'] is String &&
            item['lifecycleState'] == 'active' &&
            item['visibilityState'] == 'visible')
          (
            id: item['workerTypeId'] as String,
            name: item['displayName'] as String
          )
    ];
  }

  @override
  Future<void> createWorkerInstance(String typeId, String name) async {
    final response = await client.post(Uri.parse('$baseUrl/workers'),
        headers: _headers(contentType: 'application/json'),
        body: jsonEncode({'workerTypeId': typeId, 'name': name}));
    if (response.statusCode != 201) {
      throw AxApiException('Could not add Worker (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> updateWorkerInstance(
      String id, Map<String, Object?> changes) async {
    final response = await client.patch(
      Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode(changes),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Could not update Worker (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> removeWorkerInstance(String id) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException('Could not remove Worker (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<McpWorkerPinState> loadMcpWorkerPin(String id) async =>
      McpWorkerPinState.fromJson(await _getJson(
          Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/mcp-pin')));

  @override
  Future<void> setMcpWorkerPin(String id, McpWorkerVersion version) async {
    final response = await client.put(
      Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/mcp-pin'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'version': version.version,
        'manifestDigest': version.manifestDigest,
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not pin the MCP Worker (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<void> clearMcpWorkerPin(String id) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/mcp-pin'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not clear the MCP Worker (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<AxWorkerSpaceAccess> loadWorkerSpaceAccess(
      String workerId, String spaceId) async {
    final uri = Uri.parse(
            '$baseUrl/workers/${Uri.encodeComponent(workerId)}/space-access')
        .replace(queryParameters: {'spaceId': spaceId});
    return AxWorkerSpaceAccess.fromJson(await _getJson(uri));
  }

  @override
  Future<AxWorkerSpaceAccess> saveWorkerSpaceAccess(
    String workerId,
    String spaceId,
    List<AxWorkerSpaceMemberAccess> members,
  ) async {
    final response = await client.put(
      Uri.parse(
          '$baseUrl/workers/${Uri.encodeComponent(workerId)}/space-access'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({
        'spaceId': spaceId,
        'members': [for (final m in members) m.toUpdateJson()],
      }),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not save Space member access (${response.statusCode})',
          statusCode: response.statusCode);
    }
    return AxWorkerSpaceAccess.fromJson(
        Map<String, dynamic>.from(jsonDecode(response.body) as Map));
  }

  @override
  Future<AxWorkerMemberModelAccess> loadWorkerMemberModelAccess(
      String workerId) async {
    final json = await _getJson(Uri.parse(
        '$baseUrl/workers/${Uri.encodeComponent(workerId)}/member-model-access'));
    return AxWorkerMemberModelAccess.fromJson(json['modelAccess']);
  }

  @override
  Future<AxWorkerMemberModelAccess> saveWorkerMemberModelAccess(
      String workerId, AxWorkerMemberModelAccess access) async {
    final response = await client.put(
      Uri.parse(
          '$baseUrl/workers/${Uri.encodeComponent(workerId)}/member-model-access'),
      headers: _headers(contentType: 'application/json'),
      body: jsonEncode({'modelAccess': access.toJson()}),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not save member model access (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
    return AxWorkerMemberModelAccess.fromJson(body['modelAccess']);
  }

  @override
  Future<void> requestWorkerModelsRefresh(String id) async {
    final response = await client.post(
        Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/models/refresh'),
        headers: _headers(contentType: 'application/json'),
        body: '{}');
    if (response.statusCode != 202) {
      var detail = '';
      try {
        final error = jsonDecode(response.body);
        if (error is Map && error['error'] is String) {
          detail = ': ${error['error']}';
        }
      } on FormatException {
        // Not a JSON error body.
      }
      throw AxApiException(
          'Could not refresh models (${response.statusCode})$detail',
          statusCode: response.statusCode);
    }
  }

  @override
  Future<String> pairWorkerInstance(String id) async {
    final response = await client.post(
        Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/pairing'),
        headers: _headers(contentType: 'application/json'),
        body: '{}');
    if (response.statusCode != 201) {
      throw AxApiException(
          'Could not create pairing code (${response.statusCode})',
          statusCode: response.statusCode);
    }
    final body = jsonDecode(response.body);
    final challenge = body is Map ? body['challenge'] : null;
    if (challenge is! Map ||
        challenge['challengeId'] is! String ||
        challenge['secret'] is! String ||
        challenge['workerId'] != id) {
      throw const AxApiException('Pairing response is malformed');
    }
    final server = backendBaseUrl.replaceFirst(RegExp(r'/api/?$'), '');
    final payload = jsonEncode({
      's': server,
      'w': id,
      'c': challenge['challengeId'],
      'k': challenge['secret']
    });
    return 'syntila-pair:v1:${base64Url.encode(utf8.encode(payload)).replaceAll('=', '')}';
  }

  @override
  Future<void> revokeWorkerCredential(String id) async {
    final response = await client.delete(
        Uri.parse('$baseUrl/workers/${Uri.encodeComponent(id)}/credential'),
        headers: _headers());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AxApiException(
          'Could not revoke Worker credential (${response.statusCode})',
          statusCode: response.statusCode);
    }
  }
}

/// A 422 eligibility error reads like `implement: Select a Worker ...`; users
/// only need the final sentence. Other failures keep the status prefix.
String _eligibilityFailureMessage(int statusCode, Object? decoded) {
  final error = decoded is Map && decoded['error'] is String
      ? (decoded['error'] as String).trim()
      : '';
  if (statusCode == 422 && error.isNotEmpty) {
    return error.substring(error.lastIndexOf(': ') + 1).trim();
  }
  return 'Work eligibility check failed ($statusCode)'
      '${error.isEmpty ? '' : ': $error'}';
}
