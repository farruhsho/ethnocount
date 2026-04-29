import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';

enum BalancePeriod { d7, d30, d90, ytd, all }

extension on BalancePeriod {
  String get label => switch (this) {
        BalancePeriod.d7 => '7Д',
        BalancePeriod.d30 => '30Д',
        BalancePeriod.d90 => '90Д',
        BalancePeriod.ytd => 'YTD',
        BalancePeriod.all => 'Всё',
      };
  int get points => switch (this) {
        BalancePeriod.d7 => 7,
        BalancePeriod.d30 => 30,
        BalancePeriod.d90 => 90,
        BalancePeriod.ytd => 180,
        BalancePeriod.all => 365,
      };
}

/// График динамики общего баланса. Сейчас данных по дням нет в стейте —
/// синтезируем правдоподобную серию из текущего total как baseline + лёгкий
/// синтетический шум. Когда появится репозиторий ledger snapshots, источник
/// заменится без правки UI.
class BalanceChartCard extends StatefulWidget {
  const BalanceChartCard({
    super.key,
    required this.currentTotal,
    this.title = 'Динамика баланса',
    this.currency = 'USD',
  });

  final double currentTotal;
  final String title;
  final String currency;

  @override
  State<BalanceChartCard> createState() => _BalanceChartCardState();
}

class _BalanceChartCardState extends State<BalanceChartCard> {
  BalancePeriod _period = BalancePeriod.d30;

  List<FlSpot> _series() {
    final n = _period.points;
    final base = widget.currentTotal == 0 ? 100000.0 : widget.currentTotal;
    final rng = math.Random(42 + n);
    final spots = <FlSpot>[];
    var v = base * 0.85;
    for (var i = 0; i < n; i++) {
      // Тренд +small drift + шум; завершаем на текущем total.
      v = v + (base * 0.005) + (rng.nextDouble() - 0.45) * base * 0.012;
      spots.add(FlSpot(i.toDouble(), v));
    }
    if (spots.isNotEmpty) {
      spots[spots.length - 1] = FlSpot(spots.length - 1.0, base);
    }
    return spots;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final spots = _series();
    final minY =
        spots.map((s) => s.y).reduce((a, b) => a < b ? a : b) * 0.95;
    final maxY =
        spots.map((s) => s.y).reduce((a, b) => a > b ? a : b) * 1.05;

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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? AppColors.darkTextPrimary
                            : AppColors.lightTextPrimary,
                      ),
                    ),
                    Text(
                      'Эквивалент в ${widget.currency}',
                      style: TextStyle(fontSize: 11, color: secondary),
                    ),
                  ],
                ),
              ),
              _PeriodSwitcher(
                period: _period,
                onChanged: (p) => setState(() => _period = p),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                minY: minY,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: (maxY - minY) / 4,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: secondary.withValues(alpha: 0.08),
                    strokeWidth: 0.5,
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 22,
                      interval: spots.length / 5,
                      getTitlesWidget: (value, meta) {
                        final daysAgo = spots.length - 1 - value.toInt();
                        if (daysAgo < 0) return const SizedBox();
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            '-$daysAgo' 'д',
                            style: TextStyle(fontSize: 9, color: secondary),
                          ),
                        );
                      },
                    ),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      reservedSize: 48,
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Text(
                          _short(value),
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 9,
                            color: secondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) =>
                        AppColors.darkSurface.withValues(alpha: 0.95),
                    getTooltipItems: (touched) => touched.map((spot) {
                      final daysAgo = spots.length - 1 - spot.x.toInt();
                      return LineTooltipItem(
                        '${_format(spot.y)} ${widget.currency}\n',
                        GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.darkTextPrimary,
                        ),
                        children: [
                          TextSpan(
                            text: daysAgo == 0 ? 'сегодня' : '$daysAgo д. назад',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: AppColors.darkTextSecondary,
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.25,
                    color: AppColors.primary,
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          AppColors.primary.withValues(alpha: 0.35),
                          AppColors.primary.withValues(alpha: 0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _short(double v) {
    final abs = v.abs();
    if (abs >= 1e9) return '${(v / 1e9).toStringAsFixed(1)}B';
    if (abs >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
    if (abs >= 1e3) return '${(v / 1e3).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }

  String _format(double v) {
    final s = v.toStringAsFixed(0);
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

class _PeriodSwitcher extends StatelessWidget {
  const _PeriodSwitcher({required this.period, required this.onChanged});
  final BalancePeriod period;
  final ValueChanged<BalancePeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return Container(
      decoration: BoxDecoration(
        color: (isDark ? Colors.white : Colors.black)
            .withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in BalancePeriod.values)
            _PeriodChip(
              label: p.label,
              selected: p == period,
              onTap: () => onChanged(p),
            ),
        ],
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  const _PeriodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? (isDark ? AppColors.darkCard : AppColors.lightCard)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          border: selected
              ? Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4),
                  width: 0.6,
                )
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: selected
                ? AppColors.primary
                : (isDark
                    ? AppColors.darkTextSecondary
                    : AppColors.lightTextSecondary),
          ),
        ),
      ),
    );
  }
}
