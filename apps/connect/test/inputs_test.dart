import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:syntila_connect/syntila_connect.dart';
import 'package:test/test.dart';

const fileA = 'wrf-11111111-2222-3333-4444-555555555555';
const requestId = 'work-request-00000000-0000-0000-0000-000000000001';
const session = SessionGrant(
  sessionId: 'session-1',
  epoch: 1,
  sessionToken: 'token',
  leaseSeconds: 90,
);

String digestOf(String text) => 'sha256:${sha256.convert(utf8.encode(text))}';

/// R2 with one uploaded file; [served] is what the download returns.
class FakeInputCloud implements InputCloud {
  FakeInputCloud(this.served);

  final String served;
  int downloads = 0;

  @override
  Future<Stream<List<int>>> download(
    SessionGrant session,
    String fileId,
  ) async {
    downloads++;
    return Stream.value(utf8.encode(served));
  }
}

Map<String, Object?> payloadFor(String text) => {
  'snapshot': {'workRequestId': requestId},
  'input': {
    'attachments': [
      {'kind': 'text', 'text': 'note'},
      {
        'kind': 'file',
        'fileId': fileA,
        'sizeBytes': utf8.encode(text).length,
        'contentDigest': digestOf(text),
      },
    ],
  },
};

void main() {
  late Directory sandbox;
  late Directory work;
  late InputStore store;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('syntila-inputs-');
    work = await Directory('${sandbox.path}/work').create();
    store = InputStore(Directory('${sandbox.path}/inputs'));
  });
  tearDown(() => sandbox.delete(recursive: true));

  test(
    'downloads a verified file and places it where the prompt says',
    () async {
      final cloud = FakeInputCloud('hello');
      final delivery = InputDelivery(cloud: cloud, store: store);
      await delivery.materialize(work, payloadFor('hello'), session);
      // The second attachment is file-002: numbering follows attachment order.
      final placed = File('${work.path}/.syntila/inputs/$requestId/file-002');
      expect(await placed.readAsString(), 'hello');

      // A retry reuses the file in place; another Step reuses the private copy.
      await delivery.materialize(work, payloadFor('hello'), session);
      final other = await Directory('${sandbox.path}/other-step').create();
      await delivery.materialize(other, payloadFor('hello'), session);
      expect(cloud.downloads, 1);
    },
  );

  test('never keeps a file whose bytes do not match', () async {
    final delivery = InputDelivery(
      cloud: FakeInputCloud('tampered'),
      store: store,
    );
    await expectLater(
      delivery.materialize(work, payloadFor('original'), session),
      throwsA(isA<InputDeliveryException>()),
    );
    expect(await store.has(fileA, 8, digestOf('original')), isFalse);
    expect(
      File('${work.path}/.syntila/inputs/$requestId/file-002').existsSync(),
      isFalse,
    );
  });

  test('without a session a missing file fails the Step', () async {
    final delivery = InputDelivery(
      cloud: FakeInputCloud('hello'),
      store: store,
    );
    await expectLater(
      delivery.materialize(work, payloadFor('hello'), null),
      throwsA(isA<InputDeliveryException>()),
    );
  });

  test('refuses an input folder that is a link', () async {
    final delivery = InputDelivery(
      cloud: FakeInputCloud('hello'),
      store: store,
    );
    final other = await Directory('${sandbox.path}/other').create();
    final linked = await Directory('${sandbox.path}/linked').create();
    await Link('${linked.path}/.syntila').create(other.path);
    await expectLater(
      delivery.materialize(linked, payloadFor('hello'), session),
      throwsA(isA<InputDeliveryException>()),
    );
    expect(other.listSync(), isEmpty);
  });

  test('a request without files needs nothing', () async {
    final delivery = InputDelivery(cloud: FakeInputCloud('x'), store: store);
    await delivery.materialize(work, {
      'input': {'prompt': 'hi'},
    }, null);
    expect(Directory('${work.path}/.syntila').existsSync(), isFalse);
  });
}
