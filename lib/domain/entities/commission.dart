import 'package:equatable/equatable.dart';

/// Commission record linked to a transfer.
class Commission extends Equatable {
  final String id;
  final String transferId;
  final double amount;
  final String currency;
  final String type;
  final DateTime createdAt;

  const Commission({
    required this.id,
    required this.transferId,
    required this.amount,
    required this.currency,
    required this.type,
    required this.createdAt,
  });

  @override
  List<Object?> get props => [id, transferId, amount, currency, type];
}
