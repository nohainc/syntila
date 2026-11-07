import 'package:flutter_test/flutter_test.dart';
import 'package:syntila_app/src/ax/ax_models.dart';

void main() {
  test('isSupport is read from the server and defaults to false', () {
    final base = {'id': 's', 'name': 'Syntila Support', 'kind': 'direct'};
    expect(AxSpace.fromJson({...base, 'isSupport': true}).isSupport, isTrue);
    expect(AxSpace.fromJson(base).isSupport, isFalse);
    expect(
        AxSpace.fromJson({...base, 'isSupport': true})
            .copyWith(name: 'x')
            .isSupport,
        isTrue);
  });
}
