import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer_part.dart';

/// Audit entry for edits to a transfer before confirmation.
class TransferAmendmentEntry extends Equatable {
  final DateTime at;
  final String userId;
  final String? note;
  /// Field name → { 'from': ..., 'to': ... } (JSON-safe values).
  final Map<String, dynamic> changes;

  const TransferAmendmentEntry({
    required this.at,
    required this.userId,
    this.note,
    this.changes = const {},
  });

  /// Parse from Supabase JSONB array.
  static List<TransferAmendmentEntry> listFromJson(dynamic raw) {
    if (raw is! List) return const [];
    final out = <TransferAmendmentEntry>[];
    for (final e in raw) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final ts = m['at'];
      final at = ts is String
          ? (DateTime.tryParse(ts) ?? DateTime.now())
          : (ts is DateTime ? ts : DateTime.now());
      out.add(TransferAmendmentEntry(
        at: at,
        userId: m['userId'] as String? ?? '',
        note: m['note'] as String?,
        changes: Map<String, dynamic>.from(m['changes'] as Map? ?? {}),
      ));
    }
    return out;
  }

  @override
  List<Object?> get props => [at, userId, note, changes];
}

/// Inter-branch transfer entity with full lifecycle tracking.
class Transfer extends Equatable {
  final String id;

  /// Human-readable unique code, e.g. ELX-2026-000042.
  final String? transactionCode;

  final String fromBranchId;
  final String toBranchId;
  final String fromAccountId;
  final String toAccountId;
  final double amount;
  final String currency;

  /// Split-currency: multiple parts (e.g. 500 USD + 30,000 RUB).
  /// When non-empty, overrides amount/currency/fromAccountId.
  final List<TransferPart>? transferParts;
  final String? toCurrency;
  final double exchangeRate;
  final double convertedAmount;

  /// Computed commission amount in commissionCurrency.
  final double commission;
  final String commissionCurrency;

  /// Type of commission: fixed amount or percentage.
  final CommissionType commissionType;

  /// Raw commission value: if fixed → dollar amount; if percentage → rate (e.g. 1.5 for 1.5%).
  final double commissionValue;

  /// Commission mode: from sender (deduct from transfer) or to receiver (add to receiver).
  final CommissionMode commissionMode;

  /// Когда [commissionMode] == [CommissionMode.fromAccount] — счёт, с
  /// которого фактически списывается комиссия (любой счёт филиала-отправителя).
  /// В остальных режимах null.
  final String? commissionAccountId;

  /// Purpose of payment / назначение платежа.
  final String? description;

  /// Optional client (counterparty) reference.
  final String? clientId;

  // Sender / receiver person info
  final String? senderName;
  final String? senderPhone;
  final String? senderInfo;
  final String? receiverName;
  final String? receiverPhone;
  final String? receiverInfo;

  final TransferStatus status;
  final String createdBy;
  final String? confirmedBy;
  final String? dispatchedBy;
  final String? courierName;
  final String? courierPhone;
  final String? issuedBy;
  final String idempotencyKey;
  final DateTime createdAt;
  final DateTime? confirmedAt;
  final DateTime? dispatchedAt;
  final DateTime? issuedAt;

  /// Edits while status is pending (account/currency/rate/note corrections).
  final List<TransferAmendmentEntry> amendmentHistory;

  /// Cumulative amount that has already been paid out to the recipient,
  /// in receiver currency. Equals [convertedAmount] once status becomes
  /// `issued`; intermediate values mean partial issuance is in progress.
  final double issuedAmount;

  /// ID партнёра (counterparty), через которого выплачен этот перевод.
  /// NULL = обычный перевод. Не-NULL = партнёрский (status сразу
  /// `delivered`) или обычный, прикреплённый позже через
  /// `attach_transfer_to_partner` (миграции 041/042).
  final String? viaCounterpartyId;

  /// Курс приёма (наш дилерский) — «1 base = X currency».
  /// Для cross-currency сделок; NULL = same-currency.
  final double? buyRate;

  /// Курс расчёта с партнёром — «1 base = Y currency». Y < X = spread profit.
  final double? sellRate;

  /// Базовая валюта учёта (обычно USD). NULL = same-currency.
  final String? baseCurrency;

  /// Кэшированный spread profit (валюта = currency). Считается RPC.
  final double? spreadProfit;

  const Transfer({
    required this.id,
    this.transactionCode,
    required this.fromBranchId,
    required this.toBranchId,
    required this.fromAccountId,
    required this.toAccountId,
    required this.amount,
    required this.currency,
    this.transferParts,
    this.toCurrency,
    required this.exchangeRate,
    required this.convertedAmount,
    required this.commission,
    required this.commissionCurrency,
    this.commissionType = CommissionType.fixed,
    this.commissionValue = 0,
    this.commissionMode = CommissionMode.fromSender,
    this.commissionAccountId,
    this.description,
    this.clientId,
    this.senderName,
    this.senderPhone,
    this.senderInfo,
    this.receiverName,
    this.receiverPhone,
    this.receiverInfo,
    required this.status,
    required this.createdBy,
    this.confirmedBy,
    this.dispatchedBy,
    this.courierName,
    this.courierPhone,
    this.issuedBy,
    required this.idempotencyKey,
    required this.createdAt,
    this.confirmedAt,
    this.dispatchedAt,
    this.issuedAt,
    this.amendmentHistory = const [],
    this.issuedAmount = 0,
    this.viaCounterpartyId,
    this.buyRate,
    this.sellRate,
    this.baseCurrency,
    this.spreadProfit,
  });

  /// True если это партнёрский перевод (выплачен через counterparty).
  bool get isPartnerTransfer => viaCounterpartyId != null;

  /// True если для перевода зафиксированы дилерские курсы (есть spread).
  bool get hasDealerRates => buyRate != null && sellRate != null;

  /// Outstanding amount still to be paid out (in receiver currency).
  /// Не доступно к выдаче, пока перевод не достиг курьера или конечной точки.
  double get remainingToIssue {
    if (status == TransferStatus.created) return 0;
    final r = convertedAmount - issuedAmount;
    return r < 0 ? 0 : r;
  }

  /// True if at least one tranche was paid out but not the full amount.
  bool get isPartiallyIssued =>
      (status == TransferStatus.toDelivery || status == TransferStatus.withCourier) &&
      issuedAmount > 0 &&
      issuedAmount < convertedAmount;

  bool get isCreated => status == TransferStatus.created;
  bool get isToDelivery => status == TransferStatus.toDelivery;
  bool get isWithCourier => status == TransferStatus.withCourier;
  bool get isDelivered => status == TransferStatus.delivered;
  bool get isFinal => status.isFinal;

  /// Можно ли редактировать перевод (поправить сумму, телефон, имя и т.д.).
  /// Разрешено пока деньги не ушли курьеру.
  bool get isEditable =>
      status == TransferStatus.created || status == TransferStatus.toDelivery;

  /// Whether this transfer uses split-currency (multiple source parts).
  bool get isSplitCurrency =>
      transferParts != null && transferParts!.isNotEmpty;

  /// Total debit from sender. fromTransfer/toReceiver/fromAccount: amount;
  /// fromSender: amount+commission. Для fromAccount комиссия списывается
  /// со второго счёта — не входит в дебет основного.
  double get totalDebitAmount {
    switch (commissionMode) {
      case CommissionMode.fromSender:
        return amount + commission;
      case CommissionMode.fromTransfer:
      case CommissionMode.toReceiver:
      case CommissionMode.fromAccount:
        return amount;
    }
  }

  /// Display string for split parts, e.g. "500 USD + 30 000 RUB".
  String get splitPartsDisplay {
    if (!isSplitCurrency) return '';
    return transferParts!
        .map((p) => '${p.amount.toStringAsFixed(0)} ${p.currency}')
        .join(' + ');
  }

  /// Amount receiver gets (in sender currency).
  double get receiverGetsAmount {
    switch (commissionMode) {
      case CommissionMode.fromTransfer:
        return amount - commission;
      case CommissionMode.fromSender:
      case CommissionMode.fromAccount:
        return amount;
      case CommissionMode.toReceiver:
        return amount + commission;
    }
  }

  /// Converted amount receiver gets (in receiver currency).
  double get receiverGetsConverted =>
      receiverGetsAmount * exchangeRate;

  @override
  List<Object?> get props => [
        id,
        transactionCode,
        fromBranchId,
        toBranchId,
        amount,
        currency,
        toCurrency,
        status,
        createdAt,
        idempotencyKey,
        amendmentHistory,
        viaCounterpartyId,
        buyRate,
        sellRate,
        baseCurrency,
        spreadProfit,
      ];
}
