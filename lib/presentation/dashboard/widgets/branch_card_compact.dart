import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/branch.dart';

/// Карточка филиала для desktop-сетки 4-up.
///
/// Показывает: код-плашка, название, валюта · число счетов, баланс крупно
/// (моно), мини-бар «доля от казначейства», подпись «X.X% от казн.».
/// При [lowBalance] — точка warning слева.
class BranchCardCompact extends StatelessWidget {
  const BranchCardCompact({
    super.key,
    required this.branch,
    required this.balanceUsd,
    required this.shareOfTotal,
    required this.accountCount,
    this.lowBalance = false,
    this.onTap,
  });

  final Branch branch;

  /// Эквивалент общего баланса филиала в USD (или базовой валюте).
  final double balanceUsd;

  /// Доля от общего баланса казначейства в [0, 1].
  final double shareOfTotal;
  final int accountCount;
  final bool lowBalance;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final pct = (shareOfTotal * 100).clamp(0, 100);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        child: Container(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.md,
            AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkCard : AppColors.lightCard,
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            border: Border.all(
              color: lowBalance
                  ? AppColors.error.withValues(alpha: 0.4)
                  : (isDark
                      ? AppColors.darkBorder
                      : AppColors.lightBorder),
              width: 0.5,
            ),
            boxShadow: lowBalance
                ? [
                    BoxShadow(
                      color: AppColors.error.withValues(alpha: 0.18),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: lowBalance
                          ? AppColors.error.withValues(alpha: 0.12)
                          : AppColors.primary.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      branch.code.isNotEmpty
                          ? branch.code.substring(
                              0, branch.code.length.clamp(0, 3))
                          : '?',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        color: lowBalance
                            ? AppColors.error
                            : AppColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          branch.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${branch.baseCurrency} · $accountCount счёт${accountCount == 1 ? '' : (accountCount < 5 ? 'а' : 'ов')}',
                          style: TextStyle(fontSize: 10, color: secondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (lowBalance)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  _compact(balanceUsd),
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
                child: LinearProgressIndicator(
                  value: shareOfTotal.clamp(0.0, 1.0),
                  minHeight: 4,
                  backgroundColor:
                      (isDark ? Colors.white : Colors.black)
                          .withValues(alpha: 0.06),
                  valueColor: AlwaysStoppedAnimation(
                    lowBalance ? AppColors.error : AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${pct.toStringAsFixed(1)}% от казн.',
                style: TextStyle(fontSize: 10, color: secondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _compact(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(2)}B';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(2)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}K';
    return v.toStringAsFixed(0);
  }
}
