import 'package:equatable/equatable.dart';

/// A physical branch office of Ethno Logistics.
class Branch extends Equatable {
  final String id;
  final String name;
  final String code;
  final String baseCurrency;
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
        isActive,
        address,
        phone,
        notes,
        sortOrder,
        archivedAt,
      ];
}
