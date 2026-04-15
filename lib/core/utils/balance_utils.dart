import 'package:ethnocount/domain/entities/branch_account.dart';

/// Aggregate account balances by currency (avoids mixing RUB + USD + USDT etc.).
/// Use for branches with multi-currency accounts.
Map<String, double> balanceByCurrency(
  List<BranchAccount> accounts,
  Map<String, double> balances,
) {
  final result = <String, double>{};
  for (final a in accounts) {
    final b = balances[a.id] ?? 0;
    if (b != 0) {
      result[a.currency] = (result[a.currency] ?? 0) + b;
    }
  }
  return result;
}

/// Same for analytics accounts map: {accountId: {balance, currency}}
Map<String, double> balanceByCurrencyFromAccounts(Map<String, dynamic> accounts) {
  final result = <String, double>{};
  for (final e in accounts.entries) {
    final acc = e.value as Map<String, dynamic>?;
    if (acc == null) continue;
    final bal = (acc['balance'] ?? 0).toDouble();
    final cur = acc['currency'] as String? ?? 'USD';
    if (bal != 0) {
      result[cur] = (result[cur] ?? 0) + bal;
    }
  }
  return result;
}
