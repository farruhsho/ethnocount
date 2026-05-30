import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';

/// 3-segment step progress bar matching `transfer-create-mobile`.
/// Each segment is a 3-px high pill, primary fill for completed/active.
/// Shows "Шаг N из total" label above when [showLabel] is true.
class MobileStepIndicator extends StatelessWidget {
  const MobileStepIndicator({
    super.key,
    required this.current,
    required this.total,
    this.showLabel = true,
    this.stepName,
  });

  /// Zero-based current step index.
  final int current;
  final int total;
  final bool showLabel;

  /// Optional short label of the current step ("Сумма и маршрут" etc.).
  /// Rendered next to the "Шаг N из M" badge.
  final String? stepName;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showLabel)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Text(
                  'ШАГ ${current + 1} ИЗ $total',
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
                if (stepName != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 3,
                    height: 3,
                    decoration: const BoxDecoration(
                      color: AppColors.darkTextDisabled,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      stepName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.darkTextSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        Row(
          children: [
            for (var i = 0; i < total; i++) ...[
              Expanded(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  height: 3,
                  decoration: BoxDecoration(
                    color: i <= current
                        ? AppColors.primary
                        : AppColors.darkBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (i < total - 1) const SizedBox(width: 6),
            ],
          ],
        ),
      ],
    );
  }
}
