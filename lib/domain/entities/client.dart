import 'package:equatable/equatable.dart';

/// A client account — money the client entrusts to Ethno Logistics.
class Client extends Equatable {
  final String id;

  /// Human-readable unique code, e.g. CL-2026-000001.
  final String clientCode;

  final String name;
  final String phone;
  final String country;
  final String currency;
  /// Один обслуживающий филиал (деньги клиента на этом филиале).
  final String? branchId;
  /// Валюты кошелька клиента (основная + дополнительные для нескольких остатков).
  final List<String> walletCurrencies;
  /// Telegram chat_id группы клиента (для уведомлений). Может быть пусто.
  final String? telegramChatId;
  final bool isActive;
  final String createdBy;
  final DateTime createdAt;

  const Client({
    required this.id,
    required this.clientCode,
    required this.name,
    required this.phone,
    required this.country,
    required this.currency,
    this.branchId,
    this.walletCurrencies = const [],
    this.telegramChatId,
    this.isActive = true,
    required this.createdBy,
    required this.createdAt,
  });

  /// Строка для списка: валюты кошелька.
  String get walletCurrenciesDisplay =>
      walletCurrencies.isNotEmpty ? walletCurrencies.join(' · ') : currency;

  /// Counterparty ID — display alias in CNT-XXXX format.
  /// Backward-compatible: maps from existing clientCode patterns.
  String get counterpartyId {
    if (clientCode.startsWith('CNT-')) return clientCode;
    // Extract numeric suffix from any code format (e.g. CL-2026-000001 → 1)
    final digits = clientCode.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return 'CNT-0000';
    final num = int.tryParse(digits) ?? 0;
    return 'CNT-${num.toString().padLeft(4, '0')}';
  }

  @override
  List<Object?> get props =>
      [id, clientCode, name, phone, country, currency, branchId,
       walletCurrencies, telegramChatId, isActive];
}

/// A single client transaction (deposit or debit).
class ClientTransaction extends Equatable {
  final String id;
  final String clientId;
  final String type; // 'deposit' | 'debit'
  final double amount;
  final String currency;
  final String? description;
  final String createdBy;
  /// display_name сотрудника, оформившего операцию (резолвится из public.users).
  final String? createdByName;
  /// Код операции (ETH-TX-YYYY-NNNNNN) — может отсутствовать у старых записей.
  final String? transactionCode;
  /// Остаток клиента в этой валюте сразу после операции.
  final double? balanceAfter;
  final DateTime createdAt;

  /// Если ненулевое — операция является частью конвертации валют.  Обе ноги
  /// (debit + deposit) получают одинаковый conversionId, в UI их можно
  /// отобразить как одну строку «Конвертация USD → RUB».
  final String? conversionId;

  /// JSON-метаданные конвертации (from/to/rate/fromAmount/toAmount).
  final Map<String, dynamic>? conversionMeta;

  const ClientTransaction({
    required this.id,
    required this.clientId,
    required this.type,
    required this.amount,
    required this.currency,
    this.description,
    required this.createdBy,
    this.createdByName,
    this.transactionCode,
    this.balanceAfter,
    required this.createdAt,
    this.conversionId,
    this.conversionMeta,
  });

  bool get isDeposit => type == 'deposit';

  /// Является ли операция конвертацией.
  bool get isConversion => conversionId != null;

  @override
  List<Object?> get props => [
        id, clientId, type, amount, currency, description,
        createdBy, createdByName, transactionCode, balanceAfter, createdAt,
        conversionId, conversionMeta,
      ];
}

/// Результат успешной конвертации валют клиента.
class ClientConversionResult extends Equatable {
  final String conversionId;
  final String fromCurrency;
  final String toCurrency;
  final double fromAmount;
  final double toAmount;
  final double rate;

  const ClientConversionResult({
    required this.conversionId,
    required this.fromCurrency,
    required this.toCurrency,
    required this.fromAmount,
    required this.toAmount,
    required this.rate,
  });

  @override
  List<Object?> get props =>
      [conversionId, fromCurrency, toCurrency, fromAmount, toAmount, rate];
}

/// Denormalized client balance document (O(1) read).
class ClientBalance extends Equatable {
  final String clientId;
  /// Остаток в основной валюте клиента ([currency]).
  final double balance;
  final String currency;
  /// Остатки по валютам (документ Firestore `balances`).
  final Map<String, double> balancesByCurrency;
  final DateTime updatedAt;

  const ClientBalance({
    required this.clientId,
    required this.balance,
    required this.currency,
    this.balancesByCurrency = const {},
    required this.updatedAt,
  });

  @override
  List<Object?> get props =>
      [clientId, balance, currency, balancesByCurrency, updatedAt];
}
