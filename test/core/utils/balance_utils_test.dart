import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/core/utils/balance_utils.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Агрегация остатков филиала по валютам. Главное свойство: суммы одной
/// валюты складываются, разные валюты не смешиваются, нули отбрасываются.
void main() {
  BranchAccount account(String id, String currency) => BranchAccount(
        id: id,
        branchId: 'b1',
        name: 'acc-$id',
        type: AccountType.cash,
        currency: currency,
        createdAt: DateTime(2026),
      );

  group('balanceByCurrency (список счетов + карта остатков)', () {
    test('складывает одинаковую валюту, разделяет разные', () {
      final accounts = [
        account('a1', 'USD'),
        account('a2', 'USD'),
        account('a3', 'RUB'),
      ];
      final balances = {'a1': 100.0, 'a2': 50.0, 'a3': 200.0};
      expect(balanceByCurrency(accounts, balances), {'USD': 150.0, 'RUB': 200.0});
    });

    test('нулевые и отсутствующие остатки отбрасываются', () {
      final accounts = [account('a1', 'USD'), account('a2', 'EUR')];
      final balances = {'a1': 0.0}; // a2 отсутствует
      expect(balanceByCurrency(accounts, balances), <String, double>{});
    });
  });

  group('balanceByCurrencyFromAccounts (карта из аналитики)', () {
    test('агрегирует по валюте из вложенных объектов', () {
      final accounts = {
        'a1': {'balance': 100.0, 'currency': 'USD'},
        'a2': {'balance': 50.0, 'currency': 'USD'},
        'a3': {'balance': 200.0, 'currency': 'RUB'},
      };
      expect(
        balanceByCurrencyFromAccounts(accounts),
        {'USD': 150.0, 'RUB': 200.0},
      );
    });

    test('нулевой баланс пропускается', () {
      final accounts = {
        'a1': {'balance': 0, 'currency': 'EUR'},
      };
      expect(balanceByCurrencyFromAccounts(accounts), <String, double>{});
    });

    test('отсутствующая валюта по умолчанию USD', () {
      final accounts = {
        'a1': {'balance': 10.0},
      };
      expect(balanceByCurrencyFromAccounts(accounts), {'USD': 10.0});
    });
  });
}
