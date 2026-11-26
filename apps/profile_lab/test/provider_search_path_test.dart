import 'dart:io';

import 'package:syntila_profile_lab/profile_lab_test_sandbox.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Finder PATH gains the Connect service provider directories', () {
    final path = providerSearchPath({'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'});
    if (Platform.isMacOS) {
      expect(
        path,
        '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin',
      );
    }
  });

  test('keeps the host PATH order and adds no duplicates', () {
    final path = providerSearchPath({'PATH': '/custom:/opt/homebrew/bin'});
    expect(path.split(':').take(2), ['/custom', '/opt/homebrew/bin']);
    expect(
      path.split(':').where((entry) => entry == '/opt/homebrew/bin'),
      hasLength(1),
    );
  });
}
