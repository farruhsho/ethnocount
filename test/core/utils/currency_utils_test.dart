import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';

/// Покрывает разбивку остатков по валютам — критично, чтобы НЕ смешивать
/// валюты в одной сумме (USD + RUB + UZS должны оставаться раздельными),
/// а также корректность порядка отображения и правил округления.
void main() {
  group('CurrencyUtils.formatBalanceBreakdown', () {
    test('пустая карта → "0"', () {
      expect(CurrencyUtils.formatBalanceBreakdown({}), '0');
    });

    test('только нулевые значения → "0"', () {
      expect(CurrencyUtils.formatBalanceBreakdown({'USD': 0.0}), '0');
    });

    test('соблюдает порядок USD → RUB → UZS и правила знаков', () {
      final result = CurrencyUtils.formatBalanceBreakdown({
        'UZS': 120000000.0,
        'USD': 5000.0,
        'RUB': 19000.0,
      });
      // UZS/KZT/KGS — без копеек; остальные с 2 знаками.
      expect(result, '5 000.00 USD, 19 000.00 RUB, 120 000 000 UZS');
    });

    test('отрицательный остаток отображается со знаком минус', () {
      expect(
        CurrencyUtils.formatBalanceBreakdown({'USD': -100.0}),
        '-100.00 USD',
      );
    });

    test('неизвестная валюта идёт после известных, 2 знака', () {
      expect(
        CurrencyUtils.formatBalanceBreakdown({'XYZ': 100.0, 'USD': 50.0}),
        '50.00 USD, 100.00 XYZ',
      );
    });
  });

  group('CurrencyUtils lookups', () {
    test('flag/name/symbol для известной валюты', () {
      expect(CurrencyUtils.flag('USD'), '🇺🇸');
      expect(CurrencyUtils.name('RUB'), 'Российский рубль');
      expect(CurrencyUtils.symbol('USD'), '\$');
    });

    test('fallback для неизвестной валюты', () {
      expect(CurrencyUtils.flag('XXX'), '🏳️');
      expect(CurrencyUtils.name('XXX'), 'XXX');
      expect(CurrencyUtils.symbol('XXX'), 'XXX');
    });

    test('display = флаг + код', () {
      expect(CurrencyUtils.display('USD'), '🇺🇸 USD');
    });

    test('format = символ + сумма с 2 знаками', () {
      expect(CurrencyUtils.format(1234.5, 'USD'), '\$ 1234.50');
    });
  });
}
