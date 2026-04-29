import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';

/// Donut по валютам: левый круг — суммы по валютам в долях, справа легенда
/// с процентом и компактной суммой каждой пары.
class CurrencyDonutCard extends StatelessWidget {
  const CurrencyDonutCard({
    super.key,
    required this.balancesByCurrency,
    this.title = 'Распределение по валютам',
  });

  final Map<String, double> balancesByCurrency;
  final String title;

  static const _palette = <String, Color>{
    'UZS': AppColors.primary,
    'USD': AppColors.secondary,
    'USDT': AppColors.secondary,
    'RUB': AppColors.warning,
    'KZT': Color(0xFF9B59B6),
    'EUR': Color(0xFF1ABC9C),
    'TRY': Color(0xFFE74C3C),
    'CNY': Color(0xFFF39C12),
    'AED': Color(0xFF2A5BD8),
    'KGS': Color(0xFF8E44AD),
    'TJS': Color(0xFF27AE60),
  };

  Color _color(String cur, int i) =>
      _palette[cur] ?? AppColors.chartPalette[i % AppColors.chartPalette.length];

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    final entries = balancesByCurrency.entries
        .where((e) => e.value.abs() > 0.01)
        .toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    final total =
        entries.fold<double>(0, (s, e) => s + e.value.abs());

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
          const SizedBox(height: AppSpacing.lg),
          if (entries.isEmpty)
            SizedBox(
              height: 160,
              child: Center(
                child: Text(
                  'Нет данных по балансам',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 140,
                  height: 160,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 42,
                      startDegreeOffset: -90,
                      sections: [
                        for (var i = 0; i < entries.length; i++)
                          PieChartSectionData(
                            value: entries[i].value.abs(),
                            color: _color(entries[i].key, i),
                            radius: 22,
                            showTitle: false,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < entries.length; i++) ...[
                        _LegendRow(
                          color: _color(entries[i].key, i),
                          currency: entries[i].key,
                          amount: entries[i].value,
                          percent:
                              total > 0 ? entries[i].value.abs() / total : 0,
                        ),
                        if (i != entries.length - 1)
                          const SizedBox(height: 6),
                      ],
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.currency,
    required this.amount,
    required this.percent,
  });
  final Color color;
  final String currency;
  final double amount;
  final double percent;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            currency,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '${(percent * 100).toStringAsFixed(1)}%',
          style: TextStyle(fontSize: 11, color: secondary),
        ),
        const SizedBox(width: 8),
        Text(
          _compact(amount),
          style: GoogleFonts.jetBrainsMono(
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
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
