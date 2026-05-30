import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';

/// Top section of the Transfers list (desktop): page title, "Новый перевод"
/// CTA, "Обновить" secondary, and a 4-tile KPI strip below.
///
/// Counts come pre-computed via [TransfersKpis] so the parent can decide
/// whether to count visible-only / all / today / this-week subsets.
class TransfersHeroHeader extends StatelessWidget {
  const TransfersHeroHeader({
    super.key,
    required this.kpis,
    required this.onCreate,
    required this.onRefresh,
    this.canCreate = true,
  });

  final TransfersKpis kpis;
  final VoidCallback onCreate;
  final VoidCallback onRefresh;
  final bool canCreate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 18),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.darkDivider, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'TREASURY',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: AppColors.darkTextTertiary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Переводы между филиалами',
                      style: GoogleFonts.inter(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        color: AppColors.darkTextPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              _SecondaryButton(
                label: 'Обновить',
                icon: AppIcons.refresh,
                onTap: onRefresh,
              ),
              if (canCreate) ...[
                const SizedBox(width: 8),
                _PrimaryButton(
                  label: 'Новый перевод',
                  icon: AppIcons.add,
                  onTap: onCreate,
                ),
              ],
            ],
          ),
          const SizedBox(height: 18),
          _KpiStrip(kpis: kpis),
        ],
      ),
    );
  }
}

class TransfersKpis {
  const TransfersKpis({
    required this.totalToday,
    required this.usdToday,
    required this.pendingCount,
    required this.toDeliveryCount,
    required this.deliveredCount,
  });
  final int totalToday;
  final double usdToday;
  final int pendingCount;
  final int toDeliveryCount;
  final int deliveredCount;
}

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({required this.kpis});
  final TransfersKpis kpis;
  @override
  Widget build(BuildContext context) {
    final tiles = [
      _KpiTile(
        icon: AppIcons.swap_horiz,
        label: 'ВСЕГО СЕГОДНЯ',
        value: '${kpis.totalToday}',
        sub: '≈ \$${kpis.usdToday.formatCurrencyNoDecimals()} USD',
        color: AppColors.darkTextPrimary,
      ),
      _KpiTile(
        icon: AppIcons.schedule,
        label: 'ОЖИДАЮТ ПОДТВ.',
        value: '${kpis.pendingCount}',
        sub: kpis.pendingCount == 0
            ? 'всё под контролем'
            : 'нужно действие',
        color: AppColors.warning,
      ),
      _KpiTile(
        icon: AppIcons.check,
        label: 'К ВЫДАЧЕ',
        value: '${kpis.toDeliveryCount}',
        sub: 'готовы к выдаче',
        color: AppColors.secondary,
      ),
      _KpiTile(
        icon: AppIcons.check_circle,
        label: 'ВЫДАНЫ',
        value: '${kpis.deliveredCount}',
        sub: 'закрыты',
        color: AppColors.primary,
      ),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth < 540
            ? 1
            : c.maxWidth < 900
                ? 2
                : 4;
        return GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: cols,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: cols == 4 ? 3.2 : 3.6,
          children: tiles,
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.darkCard,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 15, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                    color: color,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: AppColors.darkTextSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.darkTextSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: BoxDecoration(
          gradient: AppColors.primaryGradient,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: AppColors.primary.withValues(alpha: 0.4),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: AppColors.darkBg),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.darkBg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
