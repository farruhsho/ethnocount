import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/domain/entities/purchase.dart';
import 'package:ethnocount/domain/entities/enums.dart';

void main() {
  group('Purchase Entity Logic Tests (Logistics / Accountant Audit)', () {
    test('cashAmount sums only cash lines in the purchase currency', () {
      final payments = [
        PurchasePayment(
          accountId: 'a1',
          accountName: 'Cash Desk',
          amount: 500.0,
          currency: 'USD',
          accountType: AccountType.cash,
          percentage: 50,
        ),
        PurchasePayment(
          accountId: 'a2',
          accountName: 'Bank Card',
          amount: 300.0,
          currency: 'USD',
          accountType: AccountType.card,
          percentage: 30,
        ),
        PurchasePayment(
          accountId: 'a3',
          accountName: 'Other Cash',
          amount: 200.0,
          currency: 'USD',
          accountType: AccountType.cash,
          percentage: 20,
        ),
      ];

      final purchase = Purchase(
        id: 'p1',
        transactionCode: 'TX-1',
        branchId: 'b1',
        description: 'Test Goods',
        totalAmount: 1000.0,
        currency: 'USD',
        payments: payments,
        createdBy: 'user',
        createdAt: DateTime.now(),
      );

      expect(purchase.cashAmount, 700.0);
      expect(purchase.amountInPurchaseCurrency, 1000.0);
    });

    test('cashAmount is currency-aware — excludes foreign-currency cash lines', () {
      final payments = [
        PurchasePayment(
          accountId: 'a1',
          accountName: 'Main',
          amount: 500.0,
          currency: 'USD',
          accountType: AccountType.cash,
          percentage: 100,
        ),
        PurchasePayment(
          accountId: 'a2',
          accountName: 'Alt',
          amount: 10000.0,
          currency: 'UZS',
          accountType: AccountType.cash,
          percentage: 0,
        ),
      ];

      final purchase = Purchase(
        id: 'p2',
        transactionCode: 'TX-2',
        branchId: 'b1',
        description: 'Mixed Currencies',
        totalAmount: 500.0,
        currency: 'USD',
        payments: payments,
        createdBy: 'user',
        createdAt: DateTime.now(),
      );

      // Only the USD cash line counts — 10000 UZS is excluded.
      expect(purchase.cashAmount, 500.0);
      expect(purchase.amountInPurchaseCurrency, 500.0);
    });

    test('legacy payments without accountType contribute 0 to cashAmount', () {
      final payments = [
        PurchasePayment(
          accountId: 'a1',
          accountName: 'Unknown',
          amount: 250.0,
          currency: 'USD',
          percentage: 100,
        ),
      ];
      final purchase = Purchase(
        id: 'p3',
        transactionCode: 'TX-3',
        branchId: 'b1',
        description: 'Legacy',
        totalAmount: 250.0,
        currency: 'USD',
        payments: payments,
        createdBy: 'user',
        createdAt: DateTime.now(),
      );
      expect(purchase.cashAmount, 0.0);
      expect(purchase.amountInPurchaseCurrency, 250.0);
    });
  });
}
