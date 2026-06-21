import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/core/extensions/number_x.dart';

/// Покрывает форматирование чисел/денег: разделитель тысяч — пробел,
/// десятичный — точка. Эти функции рисуют все суммы в UI, поэтому
/// регрессия здесь = неверно показанные деньги.
void main() {
  group('formatNumberSpaced', () {
    test('тысячи разделяются пробелом, 2 знака по умолчанию', () {
      expect(formatNumberSpaced(1234567.89), '1 234 567.89');
    });

    test('decimals: 0 округляет и убирает дробную часть', () {
      expect(formatNumberSpaced(1234.4, decimals: 0), '1 234');
      expect(formatNumberSpaced(1234.6, decimals: 0), '1 235');
    });

    test('маленькие числа без разделителя', () {
      expect(formatNumberSpaced(0.5), '0.50');
    });
  });

  group('NumberX.formatCurrency', () {
    test('без символа', () {
      expect((1000000).formatCurrency(), '1 000 000.00');
    });

    test('с символом-префиксом', () {
      expect((1234.5).formatCurrency('\$'), '\$1 234.50');
    });
  });

  group('NumberX.formatCurrencyNoDecimals', () {
    test('округляет до целого', () {
      expect((1234.4).formatCurrencyNoDecimals(), '1 234');
      expect((1234.6).formatCurrencyNoDecimals(), '1 235');
    });
  });

  group('NumberX.withCurrency', () {
    test('добавляет код валюты после суммы', () {
      expect((1234.56).withCurrency('UZS'), '1 234.56 UZS');
    });
  });

  group('NumberX.signed', () {
    test('положительное со знаком +', () {
      expect((2500).signed, '+2 500.00');
    });

    test('отрицательное со знаком - (модуль форматируется)', () {
      expect((-2500).signed, '-2 500.00');
    });

    test('ноль считается неотрицательным → +', () {
      expect((0).signed, '+0.00');
    });
  });

  group('NumberX.percentage', () {
    test('один знак после запятой и %', () {
      expect((45.2).percentage, '45.2%');
    });
  });
}
