import 'package:syntila_app/src/ax/attachment_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('admits every file within the count and size limits', () {
    final admission = admitAttachments(existing: 0, candidates: [
      (name: 'a.txt', sizeBytes: 1),
      (name: 'b.png', sizeBytes: 25000000),
    ]);
    expect(admission.accepted, [0, 1]);
    expect(admission.notice, isNull);
  });

  test('skips files over the plan limit individually and keeps the rest', () {
    final admission = admitAttachments(existing: 0, candidates: [
      (name: 'big.mov', sizeBytes: 25000001),
      (name: 'ok.txt', sizeBytes: 5),
    ]);
    expect(admission.accepted, [1]);
    expect(admission.notice,
        'Skipped 1 file: "big.mov" is too large (over 25 MB per file).');
  });

  test('the per-file limit comes from the account, in decimal units', () {
    final policy = AxAttachmentPolicy.instance..reset();
    addTearDown(policy.reset);
    expect(policy.maxFileBytes, 25000000);
    policy.maxFileBytes = 100000000; // as Cloud reports for Syntila Plus
    final admission = admitAttachments(existing: 0, candidates: [
      (name: 'exact', sizeBytes: 100000000),
      (name: 'over', sizeBytes: 100000001),
    ]);
    expect(admission.accepted, [0]);
    expect(admission.skipped.single, contains('too large (over 100 MB'));
  });

  test('tells "storage is full" apart from "file too large"', () {
    final admission = admitAttachments(
      existing: 0,
      maxFileBytes: 25000000,
      availableBytes: 30000000,
      candidates: [
        (name: 'a', sizeBytes: 20000000),
        (name: 'b', sizeBytes: 20000000),
        (name: 'c', sizeBytes: 26000000),
      ],
    );
    expect(admission.accepted, [0]);
    expect(admission.skipped, [
      '"b" does not fit: storage is full',
      '"c" is too large (over 25 MB per file)',
    ]);
  });

  test('fills only the remaining slots and summarises long skip lists', () {
    final admission = admitAttachments(existing: 7, candidates: [
      for (var i = 0; i < 8; i++) (name: 'f$i', sizeBytes: 1),
    ]);
    expect(admission.accepted, [0, 1, 2]);
    expect(admission.skipped, hasLength(5));
    expect(admission.notice, startsWith('Skipped 5 files: "f3" exceeds'));
    expect(admission.notice, endsWith('and 2 more.'));
  });

  test('a full request admits nothing', () {
    final admission = admitAttachments(
        existing: maxAttachmentCount, candidates: [(name: 'x', sizeBytes: 1)]);
    expect(admission.accepted, isEmpty);
    expect(admission.skipped, hasLength(1));
  });
}
