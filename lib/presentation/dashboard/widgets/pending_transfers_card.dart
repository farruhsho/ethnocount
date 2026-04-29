import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/date_x.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/transfer.dart';

/// Список ожидающих переводов с компактными строками: код, статус-чип,
/// маршрут "from → to", имя клиента, время, сумма справа моно-шрифтом.
class PendingTransfersCard extends StatelessWidget {
  const PendingTransfersCard({
    super.key,
    required this.transfers,
    required this.branches,
    this.title = 'Ожидают подтверждения',
    this.onTapTransfer,
  });

  final List<Transfer> transfers;
  final List<Branch> branches;
  final String title;
  final ValueChanged<Transfer>? onTapTransfer;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final branchById = {for (final b in branches) b.id: b};

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
                ),
                child: Text(
                  '${transfers.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (transfers.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline_rounded,
                        size: 28, color: secondary),
                    const SizedBox(height: 6),
                    Text(
                      'Нет ожидающих переводов',
                      style: TextStyle(fontSize: 12, color: secondary),
                    ),
                  ],
                ),
              ),
            )
          else
            for (var i = 0; i < transfers.length.clamp(0, 6); i++) ...[
              _PendingRow(
                t: transfers[i],
                fromBranch: branchById[transfers[i].fromBranchId]?.name ?? '—',
                toBranch: branchById[transfers[i].toBranchId]?.name ?? '—',
                onTap: onTapTransfer == null
                    ? null
                    : () => onTapTransfer!(transfers[i]),
              ),
              if (i != transfers.length.clamp(0, 6) - 1)
                Divider(
                  height: AppSpacing.sm,
                  thickness: 0.4,
                  color: secondary.withValues(alpha: 0.15),
                ),
            ],
        ],
      ),
    );
  }
}

class _PendingRow extends StatelessWidget {
  const _PendingRow({
    required this.t,
    required this.fromBranch,
    required this.toBranch,
    this.onTap,
  });
  final Transfer t;
  final String fromBranch;
  final String toBranch;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _statusLabel(t),
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w700,
                  color: AppColors.warning,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '#${t.transactionCode ?? t.id.substring(0, 6)}',
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: secondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '$fromBranch → $toBranch',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '${t.senderName ?? '—'} · ${t.createdAt.historyFormatted}',
                    style: TextStyle(fontSize: 10.5, color: secondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_compact(t.amount)} ${t.currency}',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(Transfer t) {
    if (t.toAccountId.isEmpty) return 'ДОКУМЕНТЫ';
    return 'В ПУТИ';
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}
