import 'dart:async';
import 'dart:convert';

import 'package:syntila_app/src/ax/ax_data.dart';
import 'package:syntila_app/src/ax/ax_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syntila_app/src/ax/sync/ax_idempotency.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ax_fixture_data.dart';
import 'package:syntila_app/src/ax/ax_stores.dart';

class _JsonClient extends http.BaseClient {
  _JsonClient(this.body, {this.statusCode = 201});

  final Map<String, dynamic> body;
  final int statusCode;
  http.BaseRequest? lastRequest;
  String? lastBody;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      statusCode,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

class _ApiResponseClient extends http.BaseClient {
  _ApiResponseClient(this.responses);

  final Map<String, Map<String, dynamic>> responses;
  final requests = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url.path);
    final body = responses[request.url.path] ?? const <String, dynamic>{};
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(jsonEncode(body))),
      200,
      request: request,
      headers: const {'content-type': 'application/json'},
    );
  }
}

void main() {
  test('overlapping request details share a read and later reads refresh',
      () async {
    var calls = 0;
    final response = Completer<http.Response>();
    final api = AxApiClient(
        baseUrl: 'https://cloud.test',
        client: MockClient((request) {
          calls++;
          return response.future;
        }));
    final first = api.loadWorkRequest(workRequestId: 'r');
    final second = api.loadWorkRequest(workRequestId: 'r');
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    response.complete(http.Response(
        jsonEncode({
          'workRequest': {'id': 'r', 'status': 'running'}
        }),
        200));
    await Future.wait([first, second]);
    await api.loadWorkRequest(workRequestId: 'r');
    expect(calls, 2);
  });
  test('retry sends side-effect confirmation only after explicit approval',
      () async {
    final client = _JsonClient({});
    final api = AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    await api.retryWorkRequestStep(workRequestId: 'r', stepKind: 'verify');
    expect(jsonDecode(client.lastBody!), {'stepKind': 'verify'});
    await api.retryWorkRequestStep(
        workRequestId: 'r', stepKind: 'verify', confirmSideEffects: true);
    expect(jsonDecode(client.lastBody!),
        {'stepKind': 'verify', 'confirmSideEffects': true});
  });
  test('context recovery sends explicit reset approval and fresh session',
      () async {
    final client = _JsonClient({});
    final api = AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    await api.retryWorkRequestStep(
        workRequestId: 'r',
        stepKind: 'implement',
        sessionStrategy: 'fresh',
        clearAiHistory: true);
    expect(jsonDecode(client.lastBody!), {
      'stepKind': 'implement',
      'sessionStrategy': 'fresh',
      'clearAiHistory': true
    });
  });
  test('context recovery can ask the Worker to compact its session', () async {
    final client = _JsonClient({});
    final api = AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    await api.retryWorkRequestStep(
        workRequestId: 'r',
        stepKind: 'implement',
        sessionStrategy: 'resume',
        compactContext: true);
    expect(jsonDecode(client.lastBody!), {
      'stepKind': 'implement',
      'sessionStrategy': 'resume',
      'contextResolution': 'compact'
    });
  });
  test('clear history uses the exact server cutoff', () async {
    const cutoff = '2026-10-21T10:00:00.000Z';
    final api = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: _JsonClient({'aiHistoryClearedAt': cutoff}));
    expect(await api.clearThreadWorkHistory(threadId: 'thread-1'), cutoff);
  });

  test('clear history preserves the server error detail', () async {
    final client = _JsonClient({'error': 'Cancel active Work Requests first'},
        statusCode: 409);
    final api = AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    await expectLater(
      api.clearThreadWorkHistory(threadId: 'thread-1'),
      throwsA(isA<AxApiException>().having((error) => error.toString(),
          'message', contains('Cancel active Work Requests first'))),
    );
    expect(client.lastRequest!.url.path,
        '/api/threads/thread-1/work-history/clear');
  });

  test('preserves the current account session identity for profile security',
      () {
    final session = AxSession.fromJson({
      'authenticated': true,
      'sessionId': 'session-current',
      'user': {
        'id': 'user-1',
        'displayName': 'Vitalii',
        'email': 'vitalii@example.test',
      },
    });
    final security = AxAccountSecurity.fromJson([
      {'id': 'account-1', 'providerId': 'github', 'accountId': 'gh-1'},
    ], [
      {
        'id': 'session-current',
        'token': 'session-token',
        'createdAt': '2026-10-01T10:00:00Z',
        'expiresAt': '2026-10-15T10:00:00Z',
      },
    ]);

    expect(session.sessionId, 'session-current');
    expect(security.sessions.single.id, 'session-current');
    expect(security.sessions.single.token, 'session-token');
  });

  test('uses authenticated profile APIs for name and email updates', () async {
    final nameClient =
        _JsonClient(const <String, dynamic>{'status': true}, statusCode: 200);
    final nameApi = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: nameClient,
    );
    await nameApi.updateDisplayName(displayName: 'New Name');
    expect(nameClient.lastRequest?.url.path, '/api/auth/update-user');
    expect(jsonDecode(nameClient.lastBody!), {'name': 'New Name'});

    final emailClient = _JsonClient(const <String, dynamic>{
      'sent': true,
      'stage': 'new',
      'email': 'new@example.test',
    }, statusCode: 200);
    final emailApi = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: emailClient,
    );
    final step =
        await emailApi.requestEmailChangeCode(newEmail: 'new@example.test');
    expect(
        emailClient.lastRequest?.url.path, '/api/auth/change-email/send-code');
    expect(step.stage, 'new');
    expect(step.email, 'new@example.test');
    expect(jsonDecode(emailClient.lastBody!), {'newEmail': 'new@example.test'});

    await emailApi.verifyNewEmailCode(code: '123456');
    expect(
        emailClient.lastRequest?.url.path, '/api/auth/change-email/verify-new');
    expect(jsonDecode(emailClient.lastBody!), {'code': '123456'});

    final confirmClient = _JsonClient(
        const <String, dynamic>{'status': true, 'email': 'new@example.test'},
        statusCode: 200);
    final confirmApi = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: confirmClient,
    );
    expect(await confirmApi.confirmEmailChange(code: '654321'),
        'new@example.test');
    expect(
        confirmClient.lastRequest?.url.path, '/api/auth/change-email/confirm');

    final rejectApi = AxApiClient(
      baseUrl: 'https://cloud.test/api',
      client: _JsonClient(const <String, dynamic>{
        'message': 'That verification code is not valid.'
      }, statusCode: 400),
    );
    await expectLater(
        rejectApi.verifyNewEmailCode(code: '000000'),
        throwsA(isA<AxApiException>().having((error) => error.message,
            'message', 'That verification code is not valid.')));

    final deleteClient =
        _JsonClient(const <String, dynamic>{'success': true}, statusCode: 200);
    await AxApiClient(baseUrl: 'https://cloud.test/api', client: deleteClient)
        .deleteAccount(confirmEmail: 'me@example.test');
    expect(deleteClient.lastRequest?.url.path, '/api/auth/delete-user');
    expect(jsonDecode(deleteClient.lastBody!),
        {'confirmEmail': 'me@example.test'});
  });

  test('Space and Thread API paths consume only current product envelopes',
      () async {
    final client = _ApiResponseClient({
      '/api/spaces': {
        'spaces': [
          {'id': 'S', 'name': 'Team'}
        ]
      },
      '/api/spaces/S': {
        'space': {'id': 'S', 'name': 'Team'}
      },
      '/api/spaces/S/threads': {
        'threads': [
          {'id': 'T', 'spaceId': 'S', 'name': 'Work'}
        ]
      },
    });
    final api = AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    expect((await api.loadSpaces()).single.id, 'S');
    expect((await api.loadSpace(spaceId: 'S')).id, 'S');
    expect((await api.loadSpaceThreads(spaceId: 'S')).single.id, 'T');
    expect(client.requests,
        ['/api/spaces', '/api/spaces/S', '/api/spaces/S/threads']);
    final stale = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: _JsonClient({
          'project': {'id': 'S'}
        }));
    await expectLater(
        stale.loadSpace(spaceId: 'S'), throwsA(isA<AxApiException>()));
  });

  test('canonical history loader preserves complete text and scoped pagination',
      () async {
    final text = 'x' * 26000;
    final client = _JsonClient({
      'conversationId': 'C',
      'historyRevision': 5,
      'throughSequence': 4,
      'nextCursor': {'afterSequence': 3, 'throughSequence': 4},
      'entries': [
        {
          'id': 'H',
          'conversationId': 'C',
          'sequence': 3,
          'kind': 'worker_response',
          'eventType': 'message.worker_created',
          'text': text,
          'metadata': {'modelId': 'model-x'},
          'occurredAt': 'now',
          'recordedAt': 'now'
        }
      ]
    }, statusCode: 200);
    final source =
        AxApiClient(baseUrl: 'https://cloud.test/api', client: client);
    final page = await source.loadConversationHistory(
        threadId: 'W',
        conversationId: 'C',
        afterSequence: 2,
        throughSequence: 4,
        limit: 1);
    expect(page.entries.single.text, text);
    expect(page.nextCursor!['throughSequence'], 4);
    expect(
        client.lastRequest!.url.path, '/api/threads/W/conversations/C/history');
    expect(client.lastRequest!.url.queryParameters['afterSequence'], '2');
  });

  test(
      'accepted execution configuration survives history copies and cache projection',
      () {
    final config = {
      'schemaVersion': 1,
      'workerId': 'worker-a',
      'profileId': 'profile-a',
      'profileReleaseVersion': 3,
      'modelId': null,
      'effort': null,
      'workflowId': 'chat',
      'workflowVersion': 1
    };
    final request =
        AxWorkRequest.fromJson({'id': 'turn-a', 'executionConfig': config});
    expect(request.executionConfig!.toJson(), config);
    expect(request.copyWith(status: 'completed').executionConfig!.toJson(),
        config);
    expect(
        AxWorkRequest.fromJson({'id': 'historical'}).executionConfig, isNull);
  });

  test(
      'workflow policy metadata fails closed and stays outside execution snapshots',
      () {
    final unknown = AxBuiltinWorkflow.fromJson({'id': 'future', 'steps': []});
    expect(unknown.executionPolicy.userSelectsModel, isFalse);
    expect(unknown.composerBindingId, isNull);
    final workflow = AxBuiltinWorkflow.fromJson({
      'id': 'future',
      'steps': [],
      'executionPolicy': {
        'userSelectsWorker': false,
        'userSelectsModel': true,
        'userSelectsEffort': false,
        'multiStep': true,
        'multiWorker': true,
        'automaticContinuation': true,
        'requiresApprovalBetweenSteps': true,
      },
      'composerBindingId': null,
    });
    expect(workflow.executionPolicy.userSelectsModel, isTrue);
    expect(workflow.executionPolicy.userSelectsEffort, isFalse);
    expect(workflow.executionPolicy.multiStep, isTrue);
    expect(workflow.executionPolicy.multiWorker, isTrue);
    expect(workflow.executionPolicy.automaticContinuation, isTrue);
    expect(workflow.executionPolicy.requiresApprovalBetweenSteps, isTrue);
    expect(workflow.snapshot.containsKey('executionPolicy'), isFalse);
    expect(workflow.snapshot.containsKey('composerBindingId'), isFalse);
  });
  test(
      'Chat defaults omit model and effort overrides and send the plain workflow ID',
      () async {
    final client = _JsonClient({
      'workRequest': {'id': 'request-default'}
    });
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    await api.createWorkRequest(
        threadId: 'stream', workflowId: 'chat', prompt: 'Hello');
    final body = jsonDecode(client.lastBody!) as Map;
    expect(body['workflowId'], 'chat');
    expect(body.containsKey('model'), false);
    expect(body.containsKey('reasoningEffort'), false);
    expect((body['input'] as Map)['originalRequest'], 'Hello');
  });
  for (final withSelection in [false, true]) {
    test(
        'file manifest, response-loss retry and post-acceptance upload (selection: $withSelection)',
        () async {
      final uploads = <http.Request>[];
      final submissions = <http.Request>[];
      final api = AxApiClient(
        baseUrl: 'https://syntila.test/api',
        client: MockClient((request) async {
          if (request.method == 'PUT') {
            uploads.add(request);
            return http.Response(
                jsonEncode({'fileId': 'wrf-1', 'state': 'uploaded'}), 200);
          }
          if (request.method == 'GET') {
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
          }
          submissions.add(request);
          if (submissions.length == 1) {
            throw http.ClientException('response lost');
          }
          return http.Response(
              jsonEncode({
                'workRequest': {
                  'id': 'saved-request',
                  'input': {
                    'attachments': [
                      {'kind': 'file', 'fileId': 'wrf-1', 'name': 'note.txt'}
                    ]
                  }
                }
              }),
              201);
        }),
      );
      addTearDown(AxInputDelivery.instance.clear);
      final attachments = List<Map<String, dynamic>>.unmodifiable([
        freezeAxMutationInput({
          'kind': 'file',
          'name': 'note.txt',
          'mediaType': 'text/plain',
          'sizeBytes': 5,
          'contentBase64': base64Encode(utf8.encode('hello')),
        }) as Map<String, dynamic>,
      ]);
      Future<String> send() => withSelection
          ? api.createWorkRequestWithSelection(
              threadId: 'thread',
              workflowId: 'direct',
              prompt: 'Read this',
              attachments: attachments,
              idempotencyKey: 'retry-operation-0001',
              executionSelection: const {'workerId': 'worker'})
          : api.createWorkRequest(
              threadId: 'thread',
              workflowId: 'direct',
              prompt: 'Read this',
              attachments: attachments,
              idempotencyKey: 'retry-operation-0001');
      await expectLater(send(), throwsA(isA<http.ClientException>()));
      // Nothing is uploaded for a request that was not confirmed.
      expect(uploads, isEmpty);
      expect(await send(), 'saved-request');
      expect(submissions[1].body, submissions[0].body);
      expect(submissions[1].headers['Idempotency-Key'], 'retry-operation-0001');
      final submitted =
          (jsonDecode(submissions.last.body)['input']['attachments'] as List)
              .single as Map;
      expect(submitted, {
        'kind': 'file',
        'name': 'note.txt',
        'mediaType': 'text/plain',
        'sizeBytes': 5,
        'delivery': 'upload',
      });
      expect(attachments.single.containsKey('fileId'), isFalse);
      for (var i = 0; i < 50 && uploads.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(uploads.single.url.path,
          '/api/work-requests/saved-request/inputs/wrf-1');
      expect(uploads.single.bodyBytes, utf8.encode('hello'));
    });
  }

  test('Work submission exposes the server reason for a 400', () async {
    final client =
        _JsonClient({'error': 'Unsupported workflowId'}, statusCode: 400);
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    expect(
        () => api.createWorkRequest(
            threadId: 'stream', workflowId: 'chat', prompt: 'Hello'),
        throwsA(isA<AxApiException>().having(
            (e) => e.message, 'reason', contains('Unsupported workflowId'))));
  });

  test('Work eligibility preserves structured 422 issues', () async {
    final client = _JsonClient({
      'eligible': false,
      'issues': [
        {
          'code': 'space_workspace_grant_missing',
          'message':
              'Work: select this Worker\'s Workspace in the Space Workflows tab.'
        }
      ]
    }, statusCode: 422);
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    expect(
        await api.validateWorkRequestEligibility(
            threadId: 'thread', workflowId: 'full_cycle'),
        ['Work: select this Worker\'s Workspace in the Space Workflows tab.']);
  });

  test('Workspace list reads aggregate grant counts with one HTTP request',
      () async {
    final client = _ApiResponseClient({
      '/api/workspaces': {
        'workspaces': [
          {'id': 'owned', 'name': 'Owned'},
          {'id': 'legacy', 'name': 'Legacy'},
          {'id': 'empty', 'name': 'Empty'},
        ]
      }
    });
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    final values = await api.loadWorkspaces();
    expect(values.map((w) => w.workerCount), [0, 0, 0]);
    expect(client.requests, ['/api/workspaces']);
  });
  test('single Work Request details retain identity and authored result',
      () async {
    final client = _JsonClient({
      'workRequest': {
        'id': 'r',
        'conversationId': 'conversation-r',
        'status': 'completed',
        'originalRequest': '# Prompt',
        'workflowId': 'direct',
        'workflowVersion': 2,
        'createdAt': '2026-10-06T00:00:00Z'
      },
      'result': {'text': '# Result'},
      'steps': []
    });
    final api = AxApiClient(baseUrl: 'https://example.test', client: client);
    final result = await api.loadWorkRequest(workRequestId: 'r');
    expect(client.lastRequest!.url.path, '/work-requests/r');
    expect(result.id, 'r');
    expect(result.conversationId, 'conversation-r');
    expect(result.text, '# Result');
    expect(result.originalRequest, '# Prompt');
    await expectLater(api.loadWorkRequest(workRequestId: 'other'),
        throwsA(isA<AxApiException>()));
  });

  test('Work history HTTP loads only one bounded page with typed cursors',
      () async {
    final client = _JsonClient({
      'workRequests': [
        {
          'id': 'b',
          'createdAt': '2026-10-06T02:00:00Z',
          'prompt': '# Exact Markdown'
        },
        {'id': 'a', 'createdAt': '2026-10-06T01:00:00Z'}
      ],
      'nextCursor': {'createdAt': '2026-10-06T01:00:00Z', 'id': 'a'}
    });
    final api = AxApiClient(baseUrl: 'https://example.test', client: client);
    final page = await api.loadThreadWorkRequestPage(
        threadId: 'w',
        limit: 40,
        beforeCreatedAt: '2026-10-07T00:00:00Z',
        beforeId: 'id+/=',
        activeOnly: true);
    expect(client.lastRequest!.url.queryParameters, {
      'limit': '40',
      'beforeCreatedAt': '2026-10-07T00:00:00Z',
      'beforeId': 'id+/=',
      'activeOnly': 'true'
    });
    expect(page.requests.map((r) => r.id), ['a', 'b']);
    expect(page.requests.last.prompt, '# Exact Markdown');
    expect(page.nextCursor!.id, 'a');
    expect(() => page.requests.clear(), throwsUnsupportedError);
    await expectLater(
        api.loadThreadWorkRequestPage(threadId: 'w', beforeId: 'a'),
        throwsArgumentError);
    await expectLater(api.loadThreadWorkRequestPage(threadId: 'w', limit: 101),
        throwsArgumentError);
  });
  for (final body in [
    <String, dynamic>{
      'workRequests': [],
      'nextCursor': {'id': 'x'}
    },
    <String, dynamic>{
      'workRequests': [null]
    },
    <String, dynamic>{
      'workRequests': [
        {'id': 'x'}
      ]
    },
  ]) {
    test('Work history rejects malformed page $body', () async {
      final api = AxApiClient(
          baseUrl: 'https://example.test', client: _JsonClient(body));
      await expectLater(api.loadThreadWorkRequestPage(threadId: 'w'),
          throwsA(isA<AxApiException>()));
    });
  }

  test(
      'Discussion paging uses bounded query parameters and exposes server cursors',
      () async {
    final client = _JsonClient({
      'schemaVersion': 1,
      'messages': [
        {
          'id': 'm1',
          'threadId': 'w',
          'authorUserId': 'u',
          'body': '  **source**\n',
          'createdAt': '2026-10-06T00:00:00.000Z'
        }
      ],
      'nextCursor': 'older',
      'newestCursor': 'newest'
    }, statusCode: 200);
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    final page = await api.loadDiscussionPage(
        threadId: 'w', limit: 30, before: 'cursor+/=');
    expect(client.lastRequest!.url.path, '/api/threads/w/discussion-messages');
    expect(client.lastRequest!.url.queryParameters,
        {'limit': '30', 'before': 'cursor+/='});
    expect(page.messages.single.body, '  **source**\n');
    expect(page.nextCursor, 'older');
    expect(page.newestCursor, 'newest');
    expect(() => page.messages.clear(), throwsUnsupportedError);
    await expectLater(
        api.loadDiscussionPage(threadId: 'w', limit: 0), throwsArgumentError);
    await expectLater(
        api.loadDiscussionPage(threadId: 'w', before: 'a', after: 'b'),
        throwsArgumentError);
  });
  test(
      'Discussion envelope error identifies incompatible schema without message content',
      () async {
    final api = AxApiClient(
        baseUrl: 'https://syntila.test/api',
        client: _JsonClient({
          'messages': [
            {'body': 'Private Chat'}
          ]
        }, statusCode: 200));
    await expectLater(
        api.loadDiscussionPage(threadId: 'w'),
        throwsA(isA<AxApiException>().having(
            (error) => error.message,
            'message',
            allOf(contains('expected schemaVersion 1, received missing'),
                isNot(contains('Private Chat'))))));
  });
  for (final response in [
    <String, dynamic>{'messages': []},
    {'schemaVersion': 1, 'messages': [], 'nextCursor': 4},
    {
      'schemaVersion': 1,
      'messages': ['invalid']
    },
    {
      'schemaVersion': 1,
      'messages': [
        {'id': 'm1', 'threadId': 'different'}
      ]
    }
  ]) {
    test('Discussion paging rejects malformed or cross-Thread data $response',
        () async {
      final api = AxApiClient(
          baseUrl: 'https://syntila.test/api',
          client: _JsonClient(response, statusCode: 200));
      await expectLater(api.loadDiscussionPage(threadId: 'w'),
          throwsA(isA<AxApiException>()));
    });
  }

  test('focused Space loader uses the detail endpoint without bootstrap reads',
      () async {
    final client = _ApiResponseClient({
      '/api/spaces/p1': {
        'space': {
          'id': 'p1',
          'name': 'Details',
          'settings': {'instructions': 'Detailed instructions'},
          'threads': [
            {'id': 'w1', 'spaceId': 'p1'}
          ]
        }
      }
    });
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    final space = await api.loadSpace(spaceId: 'p1');
    expect(space.instructions, 'Detailed instructions');
    expect(space.threads, isEmpty);
    expect(client.requests, ['/api/spaces/p1']);
  });

  for (final response in [
    <String, dynamic>{},
    {'space': []},
    {
      'space': {'id': 'different', 'name': 'Wrong Space'}
    }
  ]) {
    test('focused Space loader rejects malformed/mismatched response $response',
        () async {
      final client = _ApiResponseClient({'/api/spaces/p1': response});
      final api =
          AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
      await expectLater(
          api.loadSpace(spaceId: 'p1'), throwsA(isA<AxApiException>()));
    });
  }

  test(
      'canonical inventory readiness determines availability without legacy status',
      () {
    final inventory = <String, dynamic>{
      'workerId': 'worker-chatgpt',
      'workerTypeId': 'chatgpt',
      'workspaceId': 'workspace-test',
      'displayName': 'ChatGPT',
      'activationState': 'enabled',
      'readinessState': 'ready'
    };
    final ready = AxWorker.fromJson(inventory);
    expect(ready.isReady, isTrue);
    expect(ready.status, 'ready');
    expect(
        AxWorker.fromJson({...inventory, 'activationState': 'disabled'})
            .isReady,
        isFalse);
    expect(
        AxWorker.fromJson({
          ...inventory,
          'readinessState': 'worker_runtime_unavailable',
          'readinessIssueCode': 'tool_profile_unavailable'
        }).isReady,
        isFalse);
  });
  test('read errors preserve the server diagnostic and HTTP status', () async {
    final api = AxApiClient(
        baseUrl: 'https://cloud.test/api',
        client: _JsonClient({'error': 'ambiguous column name: updated_at'},
            statusCode: 400));
    await expectLater(
        api.loadSpaceThreads(spaceId: 'space-test'),
        throwsA(isA<AxApiException>()
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.message, 'message',
                contains('ambiguous column name: updated_at'))));
  });
  test('reads canonical execution error details for Ax tasks', () {
    final task = AxTask.fromJson({
      'id': 'task-error',
      'title': 'Implement feature',
      'phase': 'Execution',
      'status': 'failed',
      'worker': 'ChatGPT',
      'detail': 'Implement feature',
      'progress': 0,
      'dependencies': <String>[],
      'errorCode': 'authentication_required',
      'errorMessage': 'Sign in to the configured provider on this computer.',
    });

    expect(task.status, TaskStatus.failed);
    expect(task.errorCode, 'authentication_required');
    expect(task.errorMessage,
        'Sign in to the configured provider on this computer.');
  });

  test('approves desktop sign-in without a comparison code', () async {
    final client = _JsonClient(const <String, dynamic>{}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    await api.approveDesktopAuthIntent(intentId: 'intent-a');

    expect(client.lastRequest?.method, 'POST');
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/approve',
    );
    expect(jsonDecode(client.lastBody!), isEmpty);
  });

  test('reads non-secret desktop sign-in status for browser cleanup', () async {
    final client = _JsonClient({
      'status': 'denied',
      'clientName': 'Syntila Profile Lab',
      'audience': 'syntila.profile-lab.management',
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    expect(
      await api.loadDesktopAuthIntentStatus(intentId: 'intent-a'),
      const AxDesktopAuthIntentStatus(
        status: 'denied',
        clientName: 'Syntila Profile Lab',
        audience: 'syntila.profile-lab.management',
      ),
    );
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/browser-status',
    );
  });

  test('cancels desktop sign-in from the authenticated browser', () async {
    final client = _JsonClient(const <String, dynamic>{}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    await api.denyDesktopAuthIntent(intentId: 'intent-a');
    expect(client.lastRequest?.method, 'POST');
    expect(
      client.lastRequest?.url.path,
      '/api/desktop-auth/intents/intent-a/deny',
    );
  });

  test('loads and clears the Cloud session boundary', () async {
    final client = _JsonClient({
      'authenticated': true,
      'user': {
        'id': 'user-1',
        'displayName': 'User One',
        'email': 'user@example.test',
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    final session = await api.loadSession();
    expect(session.authenticated, isTrue);
    expect(session.viewer?.email, 'user@example.test');
    expect(client.lastRequest?.url.path, '/api/session');

    api.sessionToken = 'fixture-session';
    await api.logout();
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-out');
    expect(client.lastRequest?.headers['content-type'], 'application/json');
    expect(
        client.lastRequest?.headers['authorization'], 'Bearer fixture-session');
    expect(jsonDecode(client.lastBody!), isEmpty);
    expect(api.sessionToken, isNull);
  });

  test('failed logout preserves the session for retry', () async {
    final api = AxApiClient(
        baseUrl: 'https://syntila.test/api',
        client: _JsonClient({}, statusCode: 503));
    api.sessionToken = 'fixture-session';
    await expectLater(api.logout(), throwsA(isA<AxApiException>()));
    expect(api.sessionToken, 'fixture-session');
  });

  test('populates focused stores from the Cloud read model', () async {
    final store = AxStore(const AxFixtureDataSource());
    final snapshot = await store.loadBootstrapState();

    expect(snapshot.workspaceId, isNull);
    expect(store.spaces.items.first.id, 'space-auth');
    expect(store.runs.current?.id, 'run-fixture');
    expect(store.workspaces.items.single.id, 'workspace-macbook');
    expect(store.workspaces.items, hasLength(1));
  });

  test('preserves a session viewer when a snapshot omits viewer data',
      () async {
    final store = AxStore(const AxFixtureDataSource());
    store.auth.viewer = const AxViewer(
      id: 'user-1',
      displayName: 'User One',
      email: 'user@example.test',
    );

    store.auth.replace(null);

    expect(store.auth.viewer?.id, 'user-1');
  });

  test('returns the created Space from the Cloud response', () async {
    final client = _JsonClient({
      'space': {
        'id': 'space-created',
        'workspaceId': 'workspace-1',
        'name': 'Authentication redesign',
        'description': 'Improve the sign-in flow',
        'updatedAt': '2026-09-23T00:00:00Z',
      },
    });
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    final space = await api.createSpace(
      name: 'Authentication redesign',
      description: 'Improve the sign-in flow',
    );

    expect(space.id, 'space-created');
    expect(space.name, 'Authentication redesign');
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/spaces');
  });

  test('Space color update and clear are sent as settings patches', () async {
    final client = _JsonClient({
      'space': {
        'id': 'space-1',
        'name': 'Space',
        'settings': <String, dynamic>{}
      },
    }, statusCode: 200);
    final api =
        AxApiClient(baseUrl: 'https://syntila.test/api', client: client);
    await api.updateSpace(spaceId: 'space-1', settings: {'color': 'Blue'});
    expect(
        (jsonDecode(client.lastBody!) as Map)['settings'], {'color': 'Blue'});
    await api.updateSpace(spaceId: 'space-1', settings: {'color': null});
    expect((jsonDecode(client.lastBody!) as Map)['settings'], {'color': null});
  });

  test('persists Space instructions through the explicit update field',
      () async {
    final client = _JsonClient({
      'space': {
        'id': 'space-1',
        'name': 'Space',
        'description': '',
        'instructions': 'Use the team conventions.',
        'settings': {'instructions': 'Use the team conventions.'},
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    final space = await api.updateSpace(
      spaceId: 'space-1',
      instructions: 'Use the team conventions.',
    );

    final payload = jsonDecode(client.lastBody!) as Map<String, dynamic>;
    expect(payload['instructions'], 'Use the team conventions.');
    expect((payload['settings'] as Map)['instructions'],
        'Use the team conventions.');
    expect(space.instructions, 'Use the team conventions.');
  });

  test('composes AX state from current Space and Workspace APIs', () async {
    final client = _ApiResponseClient({
      '/api/session': {
        'authenticated': true,
        'user': {
          'id': 'user-1',
          'displayName': 'User One',
          'email': 'user@example.test',
        },
      },
      '/api/spaces': {
        'spaces': [
          {'id': 'space-1', 'name': 'Space One', 'lastActivity': 'today'},
        ],
      },
      '/api/workspaces': {'workspaces': []},
      '/api/spaces/space-1': {
        'space': {
          'id': 'space-1',
          'name': 'Space One',
          'lastActivity': 'today',
        },
      },
      '/api/spaces/space-1/threads': {
        'threads': [
          {
            'id': 'thread-1',
            'spaceId': 'space-1',
            'name': 'Authentication',
            'lead': 'Owner',
            'status': 'active',
            'brief': 'Improve authentication.',
            'primaryWorkspace': 'Workspace One',
            'queueStatus': 'Idle',
          },
        ],
      },
    });
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    final state = await api.loadBootstrapState(workspaceId: 'workspace-1');

    expect(state.viewer?.id, 'user-1');
    expect(state.spaces.single.threads, isEmpty);
    expect(client.requests, contains('/api/spaces'));
    expect(client.requests, isNot(contains('/api/spaces/space-1')));
    expect(client.requests, isNot(contains('/api/spaces/space-1/threads')));
    expect(client.requests, contains('/api/workspaces'));
    expect(client.requests, contains('/api/session'));
  });

  test('parses Workspace runtime facts', () {
    final snapshot = AxSnapshot.fromJson({
      'workspaceId': 'workspace-1',
      'workspaces': [
        {
          'id': 'workspace-runtime-1',
          'name': 'Build Workspace',
          'hostname': 'mac.local',
          'status': 'online',
          'appVersion': '4.0.0',
          'workerCount': 2,
          'platform': 'macos',
        },
      ],
      'workers': [
        {'id': 'obsolete-worker'},
      ],
    });

    expect(snapshot.workspaces, hasLength(1));
    expect(snapshot.workspaces.single.name, 'Build Workspace');
    expect(snapshot.workspaces.single.appVersion, '4.0.0');
    expect(snapshot.workspaces.single.platform, 'macos');
  });

  test('parses only the safe Workspace Worker projection', () {
    final worker = AxWorker.fromJson({
      'id': 'worker-codex',
      'workspaceId': 'workspace-1',
      'workspaceName': 'Build Mac',
      'workerTypeId': 'chatgpt',
      'displayName': 'ChatGPT',
      'status': 'ready',
      'readinessState': 'ready',
      'localConcurrencyLimit': 2,
      'capabilities': ['code'],
      'name': 'must-not-be-retained',
      'apiKey': 'must-not-be-retained',
    });

    expect(worker.workspaceId, 'workspace-1');
    expect(worker.workerTypeId, 'chatgpt');
    expect(worker.localConcurrencyLimit, 2);
    expect(worker.attentionReasonCode, isNull);
  });

  test('uses Workspace management routes for rename and invitations', () async {
    final client = _JsonClient({
      'workspace': {
        'id': 'workspace-1',
        'name': 'Updated Workspace',
        'slug': 'updated-workspace',
        'status': 'active',
        'role': 'owner',
      },
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    final workspace = await api.updateWorkspace(
        workspaceId: 'workspace-1', name: 'Updated Workspace');
    expect(workspace.name, 'Updated Workspace');
    expect(client.lastRequest?.method, 'PATCH');
    expect(client.lastRequest?.url.path, '/api/workspaces/workspace-1');

    await api.inviteWorkspaceMember(
        workspaceId: 'workspace-1',
        email: 'member@example.test',
        role: 'member');
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path,
        '/api/workspaces/workspace-1/invitations');
    expect(jsonDecode(client.lastBody!)['email'], 'member@example.test');
  });

  test('does not send obsolete Workspace security headers', () async {
    final client = _JsonClient({
      'workspaceId': 'workspace-2',
      'spaces': [],
      'workspaces': [],
      'tasks': [],
      'findings': [],
      'events': [],
      'artifacts': [],
      'modelCalls': [],
    }, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    await api.loadBootstrapState();

    expect(client.lastRequest?.headers.containsKey('x-syntila-workspace-id'),
        isFalse);
  });

  test('requests sign-up verification code and includes otp in sign-up payload',
      () async {
    final client =
        _JsonClient(const <String, dynamic>{'sent': true}, statusCode: 200);
    final api = AxApiClient(
      baseUrl: 'https://syntila.test/api',
      client: client,
    );

    await api.requestSignUpVerificationCode(
      email: 'newuser@example.com',
      name: 'New User',
    );
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-up/send-code');
    expect(jsonDecode(client.lastBody!), {
      'email': 'newuser@example.com',
      'name': 'New User',
    });

    await api.signUpWithEmail(
      name: 'New User',
      email: 'newuser@example.com',
      password: 'strong-password-123',
      otp: '482910',
    );
    expect(client.lastRequest?.method, 'POST');
    expect(client.lastRequest?.url.path, '/api/auth/sign-up/email');
    final body = jsonDecode(client.lastBody!) as Map<String, dynamic>;
    expect(body['name'], 'New User');
    expect(body['email'], 'newuser@example.com');
    expect(body['password'], 'strong-password-123');
    expect(body['otp'], '482910');
  });
}
