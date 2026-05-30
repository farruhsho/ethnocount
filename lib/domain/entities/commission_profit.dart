import 'package:equatable/equatable.dart';

/// Aggregated commission income for one (branch × currency) bucket within a
/// time period. Source: `public.commission_profit_by_branch` RPC
/// (migration 050).
class CommissionProfitRow extends Equatable {
  const CommissionProfitRow({
    required this.branchId,
    required this.branchCode,
    required this.branchName,
    required this.currency,
    required this.transferCount,
    required this.totalCommission,
  });

  final String branchId;
  final String branchCode;
  final String branchName;
  final String currency;
  final int transferCount;
  final double totalCommission;

  factory CommissionProfitRow.fromMap(Map<String, dynamic> m) {
    return CommissionProfitRow(
      branchId: (m['branch_id'] ?? '').toString(),
      branchCode: (m['branch_code'] ?? '—').toString(),
      branchName: (m['branch_name'] ?? '—').toString(),
      currency: (m['currency'] ?? 'USD').toString().toUpperCase(),
      transferCount: (m['transfer_count'] as num?)?.toInt() ?? 0,
      totalCommission:
          ((m['total_commission'] as num?) ?? 0).toDouble(),
    );
  }

  @override
  List<Object?> get props => [
        branchId,
        branchCode,
        branchName,
        currency,
        transferCount,
        totalCommission,
      ];
}

/// One row of the per-currency grand totals (sum across all branches in
/// the period). Source: `public.commission_profit_totals` RPC.
class CommissionProfitTotal extends Equatable {
  const CommissionProfitTotal({
    required this.currency,
    required this.transferCount,
    required this.totalCommission,
  });

  final String currency;
  final int transferCount;
  final double totalCommission;

  factory CommissionProfitTotal.fromMap(Map<String, dynamic> m) {
    return CommissionProfitTotal(
      currency: (m['currency'] ?? 'USD').toString().toUpperCase(),
      transferCount: (m['transfer_count'] as num?)?.toInt() ?? 0,
      totalCommission:
          ((m['total_commission'] as num?) ?? 0).toDouble(),
    );
  }

  @override
  List<Object?> get props => [currency, transferCount, totalCommission];
}

/// Bundle of both detail rows and per-currency totals for a single
/// snapshot of the analytics widget.
class CommissionProfitReport extends Equatable {
  const CommissionProfitReport({
    required this.rows,
    required this.totals,
    required this.start,
    required this.end,
  });

  final List<CommissionProfitRow> rows;
  final List<CommissionProfitTotal> totals;
  final DateTime? start;
  final DateTime? end;

  bool get isEmpty => rows.isEmpty;

  @override
  List<Object?> get props => [rows, totals, start, end];
}
