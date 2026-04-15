import 'package:equatable/equatable.dart';

/// A physical branch office of Ethno Logistics.
class Branch extends Equatable {
  final String id;
  final String name;
  final String code;
  final String baseCurrency;
  final bool isActive;
  final DateTime createdAt;

  const Branch({
    required this.id,
    required this.name,
    required this.code,
    required this.baseCurrency,
    this.isActive = true,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [id, name, code, baseCurrency, isActive];
}
