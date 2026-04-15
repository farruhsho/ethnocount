import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/core/utils/formatters.dart';

void main() {
  group('RemoveLeadingZeroFormatter', () {
    final formatter = RemoveLeadingZeroFormatter();

    test('replaces starting zero with typing a natural number', () {
      final oldVal = const TextEditingValue(text: '0');
      final newVal = const TextEditingValue(text: '05');
      
      final result = formatter.formatEditUpdate(oldVal, newVal);
      
      expect(result.text, '5');
    });

    test('replaces multiple leading zeros with typing a natural number', () {
      final oldVal = const TextEditingValue(text: '00');
      final newVal = const TextEditingValue(text: '005');
      
      final result = formatter.formatEditUpdate(oldVal, newVal);
      
      expect(result.text, '5');
    });

    test('does not modify 0. or 0, inputs', () {
      final oldVal = const TextEditingValue(text: '0');
      final newValDot = const TextEditingValue(text: '0.');
      final newValComma = const TextEditingValue(text: '0,');
      
      final resultDot = formatter.formatEditUpdate(oldVal, newValDot);
      final resultComma = formatter.formatEditUpdate(oldVal, newValComma);
      
      expect(resultDot.text, '0.');
      expect(resultComma.text, '0,');
    });
    
    test('does not modify natural numbers', () {
      final oldVal = const TextEditingValue(text: '15');
      final newVal = const TextEditingValue(text: '150');
      
      final result = formatter.formatEditUpdate(oldVal, newVal);
      
      expect(result.text, '150');
    });
  });
}
