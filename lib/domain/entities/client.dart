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
      [id, clientCode, name, phone, country, currency, branchId, walletCurrencies, isActive];
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
  final DateTime createdAt;

  const ClientTransaction({
    required this.id,
    required this.clientId,
    required this.type,
    required this.amount,
    required this.currency,
    this.description,
    required this.createdBy,
    required this.createdAt,
  });

  bool get isDeposit => type == 'deposit';

  @override
  List<Object?> get props => [id, clientId, type, amount, currency, createdAt];
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
