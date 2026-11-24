import 'dart:async';
import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

AxInputDelivery _delivery() => AxInputDelivery(
      maxConcurrentUploads: 2,
      pollInterval: const Duration(milliseconds: 5),
      retryDelay: Duration.zero,
    );

const _files = [
  AxPendingInputUpload(fileId: 'a', name: 'a.txt'),
  AxPendingInputUpload(fileId: 'b', name: 'b.txt'),
  AxPendingInputUpload(fileId: 'c', name: 'c.txt'),
];

void main() {
  test('uploads in parallel, bounded, and follows delivery', () async {
    final delivery = _delivery();
    var active = 0, maxActive = 0;
    final uploaded = <String>[];
    var polls = 0;
    await delivery.start(
      workRequestId: 'wr',
      files: _files,
      upload: (fileId) async {
        active++;
        if (active > maxActive) maxActive = active;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        uploaded.add(fileId);
        active--;
      },
      reportUploadFailure: (_, __) async => fail('no failure expected'),
      loadDelivery: () async {
        polls++;
        return [
          for (final id in uploaded)
            AxDeliveredInputState(
                fileId: id, state: polls > 2 ? 'delivered' : 'uploaded')
        ];
      },
    );
    expect(maxActive, 2);
    expect(uploaded.toSet(), {'a', 'b', 'c'});
    expect(delivery.progress('wr')!.map((file) => file.state),
        everyElement(AxInputState.delivered));
    expect(delivery.summary('wr'), isNull);
  });

  test('restarts a failed upload and reports a final failure', () async {
    final delivery = _delivery();
    final attempts = <String, int>{};
    final reported = <String>[];
    await delivery.start(
      workRequestId: 'wr',
      files: _files.take(2).toList(),
      upload: (fileId) async {
        attempts[fileId] = (attempts[fileId] ?? 0) + 1;
        // a succeeds on its second whole-file attempt; b never does.
        if (fileId == 'b' || attempts[fileId]! < 2) {
          throw StateError('network');
        }
      },
      reportUploadFailure: (fileId, _) async => reported.add(fileId),
      loadDelivery: () async => [
        const AxDeliveredInputState(fileId: 'a', state: 'delivered'),
        const AxDeliveredInputState(
            fileId: 'b',
            state: 'failed',
            errorMessage: 'b.txt could not be uploaded'),
      ],
    );
    expect(attempts, {'a': 2, 'b': 3});
    expect(reported, ['b']);
    final summary = delivery.summary('wr')!;
    expect(summary, contains('Files could not be delivered'));
    expect(summary, contains('✓ a.txt — ready'));
    expect(summary, contains('✗ b.txt'));
  });

  test('shows CLI-like progress while files move', () async {
    final delivery = _delivery();
    final gate = Completer<void>();
    unawaited(delivery.start(
      workRequestId: 'wr',
      files: _files.take(2).toList(),
      upload: (fileId) => fileId == 'a' ? Future.value() : gate.future,
      reportUploadFailure: (_, __) async {},
      loadDelivery: () async => [
        const AxDeliveredInputState(
            fileId: 'a', state: 'uploaded', deliveryAttempts: 1),
      ],
    ));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
        delivery.summary('wr'),
        'Delivering files to the Worker (0/2 ready)…\n'
        '↓ a.txt — downloading to the Worker (attempt 2)\n'
        '↑ b.txt — uploading');
    gate.complete();
    delivery.clear();
  });

  test('accepts the request with a manifest, then uploads each file', () async {
    final calls = <String>[];
    Map<String, dynamic>? created;
    final uploaded = Completer<http.Request>();
    final source = AxApiClient(
        baseUrl: 'https://cloud.test',
        client: MockClient((request) async {
          calls.add('${request.method} ${request.url.path}');
          if (request.url.path == '/threads/thread/work-requests') {
            created = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
                jsonEncode({
                  'workRequest': {
                    'id': 'wr-1',
                    'input': {
                      'attachments': [
                        {'kind': 'file', 'fileId': 'wrf-1', 'name': 'a.txt'}
                      ]
                    }
                  }
                }),
                202);
          }
          if (request.method == 'PUT') {
            if (!uploaded.isCompleted) uploaded.complete(request);
            return http.Response(
                jsonEncode({'fileId': 'wrf-1', 'state': 'uploaded'}), 200);
          }
          return http.Response(
              jsonEncode({
                'workRequest': {
                  'status': 'queued',
                  'inputs': [
                    {'fileId': 'wrf-1', 'state': 'delivered'}
                  ]
                }
              }),
              200);
        }));
    final id = await source.createWorkRequest(
        threadId: 'thread',
        workflowId: 'direct',
        prompt: 'Go',
        attachments: [
          {
            'kind': 'file',
            'name': 'a.txt',
            'mediaType': 'text/plain',
            'sizeBytes': 5,
            'contentBase64': base64Encode(utf8.encode('hello')),
          }
        ]);
    expect(id, 'wr-1');
    // Nothing was uploaded before acceptance, and no bytes were submitted.
    expect(calls.first, 'POST /threads/thread/work-requests');
    final manifest = (created!['input'] as Map)['attachments'] as List;
    expect(manifest.single, {
      'kind': 'file',
      'name': 'a.txt',
      'mediaType': 'text/plain',
      'sizeBytes': 5,
      'delivery': 'upload',
    });
    final put = await uploaded.future;
    expect(put.url.path, '/work-requests/wr-1/inputs/wrf-1');
    expect(utf8.decode(put.bodyBytes), 'hello');
    AxInputDelivery.instance.clear();
  });
}
