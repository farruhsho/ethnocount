import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';

/// Маленький круглый чип `+2.4%` / `-3 со вчера` — растёт/падает.
/// Цвет — primary для positive, error для negative; нейтральный, если 0/null.
class DeltaChip extends StatelessWidget {
  const DeltaChip({
    super.key,
    required this.label,
    this.delta,
    this.compact = false,
  });

  /// Подпись внутри: "+2.4%" / "+2 со вчера" / "-3".
  final String label;

  /// Числовое значение для определения цвета. null = нейтральный.
  final double? delta;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final positive = (delta ?? 0) > 0;
    final negative = (delta ?? 0) < 0;
    final color = positive
        ? AppColors.primary
        : (negative ? AppColors.error : AppColors.darkTextSecondary);
    final bg = positive
        ? AppColors.primarySurface
        : (negative
            ? AppColors.error.withValues(alpha: 0.10)
            : Colors.white.withValues(alpha: 0.06));
    final icon = positive
        ? Icons.arrow_upward_rounded
        : (negative ? Icons.arrow_downward_rounded : Icons.remove_rounded);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : AppSpacing.sm,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppSpacing.radiusFull),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: compact ? 10 : 12, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w700,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
