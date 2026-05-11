import 'package:equatable/equatable.dart';

/// A physical branch office of Ethno Logistics.
class Branch extends Equatable {
  final String id;
  final String name;
  final String code;
  final String baseCurrency;

  /// Валюты, которые филиал реально принимает/выдаёт. Если null/пусто,
  /// клиент использует общий список. Хранится в `branches.supported_currencies`
  /// (jsonb) — отдельно от `base_currency`, чтобы не ломать существующие записи.
  final List<String>? supportedCurrencies;

  final bool isActive;
  final String? address;
  final String? phone;
  final String? notes;
  final int sortOrder;
  final DateTime? archivedAt;
  final DateTime createdAt;

  const Branch({
    required this.id,
    required this.name,
    required this.code,
    required this.baseCurrency,
    this.supportedCurrencies,
    this.isActive = true,
    this.address,
    this.phone,
    this.notes,
    this.sortOrder = 0,
    this.archivedAt,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [
        id,
        name,
        code,
        baseCurrency,
        supportedCurrencies,
        isActive,
        address,
        phone,
        notes,
        sortOrder,
        archivedAt,
      ];
}
