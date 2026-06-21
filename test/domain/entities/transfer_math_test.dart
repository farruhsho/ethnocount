import 'package:flutter_test/flutter_test.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Дополняет transfer_test.dart: проверяет режим комиссии fromAccount,
/// остаток к выдаче (remainingToIssue), признак частичной выдачи,
/// дилерские/партнёрские флаги и редактируемость. Эти геттеры управляют
/// тем, сколько денег спишется и выдастся — регрессия здесь = денежная
/// ошибка.
void main() {
  Transfer build({
    double amount = 1000,
    double commission = 15,
    CommissionMode mode = CommissionMode.fromSender,
    double exchangeRate = 12000,
    double convertedAmount = 12000000,
    double issuedAmount = 0,
    TransferStatus status = TransferStatus.created,
    String? viaCounterpartyId,
    double? buyRate,
    double? sellRate,
  }) {
    return Transfer(
      id: 't',
      fromBranchId: 'b1',
      toBranchId: 'b2',
      fromAccountId: 'a1',
      toAccountId: 'a2',
      amount: amount,
      currency: 'USD',
      toCurrency: 'UZS',
      exchangeRate: exchangeRate,
      convertedAmount: convertedAmount,
      commission: commission,
      commissionCurrency: 'USD',
      commissionMode: mode,
      status: status,
      createdBy: 'user',
      idempotencyKey: 'key',
      createdAt: DateTime(2026),
      issuedAmount: issuedAmount,
      viaCounterpartyId: viaCounterpartyId,
      buyRate: buyRate,
      sellRate: sellRate,
    );
  }

  group('CommissionMode.fromAccount', () {
    test('комиссия НЕ входит в дебет основного счёта', () {
      final t = build(mode: CommissionMode.fromAccount);
      expect(t.totalDebitAmount, 1000.0); // не 1015
      expect(t.receiverGetsAmount, 1000.0);
      expect(t.receiverGetsConverted, 12000000.0);
    });
  });

  group('remainingToIssue', () {
    test('в статусе created ничего нельзя выдать', () {
      final t = build(status: TransferStatus.created, issuedAmount: 0);
      expect(t.remainingToIssue, 0.0);
    });

    test('к выдаче = converted - issued', () {
      final t = build(
        status: TransferStatus.toDelivery,
        convertedAmount: 1000,
        issuedAmount: 400,
      );
      expect(t.remainingToIssue, 600.0);
    });

    test('переплата не даёт отрицательного остатка', () {
      final t = build(
        status: TransferStatus.withCourier,
        convertedAmount: 1000,
        issuedAmount: 1200,
      );
      expect(t.remainingToIssue, 0.0);
    });
  });

  group('isPartiallyIssued', () {
    test('частично выдан в статусе toDelivery', () {
      final t = build(
        status: TransferStatus.toDelivery,
        convertedAmount: 1000,
        issuedAmount: 400,
      );
      expect(t.isPartiallyIssued, isTrue);
    });

    test('ничего не выдано → не частично', () {
      final t = build(status: TransferStatus.toDelivery, issuedAmount: 0);
      expect(t.isPartiallyIssued, isFalse);
    });

    test('в финальном статусе delivered → не частично', () {
      final t = build(
        status: TransferStatus.delivered,
        convertedAmount: 1000,
        issuedAmount: 500,
      );
      expect(t.isPartiallyIssued, isFalse);
    });
  });

  group('дилерские / партнёрские флаги', () {
    test('isPartnerTransfer по наличию viaCounterpartyId', () {
      expect(build(viaCounterpartyId: 'cp1').isPartnerTransfer, isTrue);
      expect(build().isPartnerTransfer, isFalse);
    });

    test('hasDealerRates требует оба курса', () {
      expect(build(buyRate: 12000, sellRate: 11800).hasDealerRates, isTrue);
      expect(build(buyRate: 12000).hasDealerRates, isFalse);
      expect(build().hasDealerRates, isFalse);
    });
  });

  group('isEditable', () {
    test('created и toDelivery редактируемы', () {
      expect(build(status: TransferStatus.created).isEditable, isTrue);
      expect(build(status: TransferStatus.toDelivery).isEditable, isTrue);
    });

    test('withCourier и delivered не редактируемы', () {
      expect(build(status: TransferStatus.withCourier).isEditable, isFalse);
      expect(build(status: TransferStatus.delivered).isEditable, isFalse);
    });
  });
}
