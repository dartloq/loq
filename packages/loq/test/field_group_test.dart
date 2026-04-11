import 'package:loq/loq.dart';
import 'package:test/test.dart';

void main() {
  group('FieldGroup', () {
    test('stores fields', () {
      const group = FieldGroup({'a': 1, 'b': 'two'});
      expect(group.fields, {'a': 1, 'b': 'two'});
    });

    test('toString uses brace notation', () {
      const group = FieldGroup({'x': 1, 'y': 2});
      expect(group.toString(), '{x=1, y=2}');
    });

    test('can be nested in other FieldGroups', () {
      const outer = FieldGroup({
        'inner': FieldGroup({'a': 1}),
      });
      expect(outer.fields['inner'], isA<FieldGroup>());
    });
  });
}
