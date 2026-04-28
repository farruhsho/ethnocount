import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';

void main() {
  group('Transfer Entity Financial Math Tests (QA / Accountant Audit)', () {
    test('calculate totalDebitAmount and receiverGetsAmount for fromSender commission', () {
      final transfer = Transfer(
        id: '1',
        fromBranchId: 'b1',
        toBranchId: 'b2',
        fromAccountId: 'a1',
        toAccountId: 'a2',
        amount: 1000, // 1000 USD transfer
        currency: 'USD',
        toCurrency: 'UZS',
        exchangeRate: 12000,
        convertedAmount: 12000000,
        commission: 15, // 15 USD commission
        commissionCurrency: 'USD',
        commissionMode: CommissionMode.fromSender,
        status: TransferStatus.pending,
        createdBy: 'user',
        idempotencyKey: 'key',
        createdAt: DateTime.now(),
      );

      // totalDebitAmount should be amount + commission
      expect(transfer.totalDebitAmount, 1015.0);
      // receiverGetsAmount should be amount
      expect(transfer.receiverGetsAmount, 1000.0);
      // receiverGetsConverted should be 1000 * 12000
      expect(transfer.receiverGetsConverted, 12000000.0);
    });

    test('calculate totalDebitAmount and receiverGetsAmount for fromTransfer commission', () {
      final transfer = Transfer(
        id: '2',
        fromBranchId: 'b1',
        toBranchId: 'b2',
        fromAccountId: 'a1',
        toAccountId: 'a2',
        amount: 1000,
        currency: 'USD',
        toCurrency: 'UZS',
        exchangeRate: 12000,
        convertedAmount: 0,
        commission: 15,
        commissionCurrency: 'USD',
        commissionMode: CommissionMode.fromTransfer,
        status: TransferStatus.pending,
        createdBy: 'user',
        idempotencyKey: 'key',
        createdAt: DateTime.now(),
      );

      // totalDebitAmount should be amount (sender sends exactly 1000, commission taken from it)
      expect(transfer.totalDebitAmount, 1000.0);
      // receiverGetsAmount should be amount - commission (1000 - 15 = 985)
      expect(transfer.receiverGetsAmount, 985.0);
      // receiverGetsConverted should be 985 * 12000 = 11820000
      expect(transfer.receiverGetsConverted, 11820000.0);
    });

    test('calculate totalDebitAmount and receiverGetsAmount for toReceiver commission', () {
      final transfer = Transfer(
        id: '3',
        fromBranchId: 'b1',
        toBranchId: 'b2',
        fromAccountId: 'a1',
        toAccountId: 'a2',
        amount: 1000,
        currency: 'USD',
        toCurrency: 'UZS',
        exchangeRate: 12000,
        convertedAmount: 0,
        commission: 15,
        commissionCurrency: 'USD',
        commissionMode: CommissionMode.toReceiver,
        status: TransferStatus.pending,
        createdBy: 'user',
        idempotencyKey: 'key',
        createdAt: DateTime.now(),
      );

      // totalDebitAmount should be amount
      expect(transfer.totalDebitAmount, 1000.0);
      // According to domain logic, receiverGetsAmount is amount + commission.
      // E.g. transferring debt, adding commission penalty to receiver.
      expect(transfer.receiverGetsAmount, 1015.0);
      // receiverGetsConverted
      expect(transfer.receiverGetsConverted, 1015.0 * 12000);
    });
    
    test('calculate for same currency transfer', () {
      final transfer = Transfer(
        id: '4',
        fromBranchId: 'b1',
        toBranchId: 'b2',
        fromAccountId: 'a1',
        toAccountId: 'a2',
        amount: 500,
        currency: 'USD',
        toCurrency: 'USD', // Same
        exchangeRate: 1.0,
        convertedAmount: 0,
        commission: 10,
        commissionCurrency: 'USD',
        commissionMode: CommissionMode.fromTransfer,
        status: TransferStatus.pending,
        createdBy: 'user',
        idempotencyKey: 'key',
        createdAt: DateTime.now(),
      );

      expect(transfer.totalDebitAmount, 500.0);
      expect(transfer.receiverGetsAmount, 490.0);
      expect(transfer.receiverGetsConverted, 490.0);
    });
  });
}
