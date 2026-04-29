import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/presentation/dashboard/widgets/delta_chip.dart';

/// Универсальная карточка KPI для дашборда казначейства.
///
/// Hero-вариант (`hero: true`) — крупный, с радиальным свечением primary
/// и горизонтальным градиентом фона. Используется для «Общий баланс
/// казначейства». Остальные KPI — компактный вариант: иконка-плашка,
/// label, крупное значение, опциональный delta-чип.
class KpiCard extends StatelessWidget {
  const KpiCard({
    super.key,
    required this.label,
    required this.primary,
    this.secondary,
    required this.icon,
    required this.iconColor,
    this.hero = false,
    this.delta,
    this.deltaValue,
  });

  /// Подпись сверху: "Общий баланс", "Активных филиалов".
  final String label;

  /// Главное значение крупным шрифтом (моно).
  final String primary;

  /// Под-строка: эквиваленты в других валютах или подпись.
  final String? secondary;

  final IconData icon;
  final Color iconColor;
  final bool hero;

  /// Подпись delta-чипа: "+2.4%", "+2 со вчера".
  final String? delta;

  /// Числовое значение для окраски delta.
  final double? deltaValue;

  @override
  Widget build(BuildContext context) {
    return hero ? _buildHero(context) : _buildStandard(context);
  }

  Widget _buildStandard(BuildContext context) {
    final isDark = context.isDark;
    final secondaryColor = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkCard : AppColors.lightCard,
        borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 0.5,
        ),
      ),
      // Compact layout: row "icon + delta", row "label", flexible primary,
      // optional secondary. Все элементы ужимаются — нет фиксированных
      // высот, нет overflow на 92×242.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _IconBadge(icon: icon, color: iconColor, size: 28),
              const Spacer(),
              if (delta != null) DeltaChip(label: delta!, delta: deltaValue),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: secondaryColor,
              letterSpacing: 0.3,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                primary,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  height: 1.0,
                  color: isDark
                      ? AppColors.darkTextPrimary
                      : AppColors.lightTextPrimary,
                ),
              ),
            ),
          ),
          if (secondary != null) ...[
            const SizedBox(height: 2),
            Flexible(
              child: Text(
                secondary!,
                style: TextStyle(
                  fontSize: 10.5,
                  color: secondaryColor,
                  height: 1.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final isDark = context.isDark;
    final secondaryColor = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return Stack(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xl),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primarySurface,
                AppColors.secondary.withValues(alpha: 0.04),
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.25),
              width: 0.6,
            ),
          ),
        ),
        // Радиальное свечение в правом-верхнем углу.
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
                gradient: RadialGradient(
                  center: const Alignment(0.9, -0.9),
                  radius: 0.9,
                  colors: [
                    AppColors.primary.withValues(alpha: 0.18),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _IconBadge(icon: icon, color: iconColor, size: 40),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: secondaryColor,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                  if (delta != null) DeltaChip(label: delta!, delta: deltaValue),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  primary,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: isDark
                        ? AppColors.darkTextPrimary
                        : AppColors.lightTextPrimary,
                    height: 1.0,
                  ),
                ),
              ),
              if (secondary != null) ...[
                const SizedBox(height: 6),
                Text(
                  secondary!,
                  style: TextStyle(
                    fontSize: 12,
                    color: secondaryColor,
                    height: 1.4,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({required this.icon, required this.color, this.size = 36});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Icon(icon, color: color, size: size * 0.5),
    );
  }
}
