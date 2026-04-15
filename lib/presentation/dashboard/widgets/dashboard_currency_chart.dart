import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';

/// Donut chart: share of balances by currency (absolute amounts).
class DashboardCurrencyChart extends StatelessWidget {
  const DashboardCurrencyChart({
    super.key,
    required this.balancesByCurrency,
  });

  final Map<String, double> balancesByCurrency;

  static const _palette = [
    AppColors.primary,
    AppColors.secondary,
    AppColors.info,
    AppColors.warning,
    Color(0xFF8E7CC3),
    Color(0xFF4FC3F7),
  ];

  @override
  Widget build(BuildContext context) {
    final entries = balancesByCurrency.entries
        .where((e) => e.value.abs() > 1e-6)
        .toList()
      ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));

    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            'Нет данных для диаграммы',
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.isDark
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
        ),
      );
    }

    final sumAbs = entries.fold<double>(0, (s, e) => s + e.value.abs());
    if (sumAbs <= 0) {
      return const SizedBox.shrink();
    }

    const maxSlices = 6;
    final shown = entries.length > maxSlices ? entries.take(maxSlices - 1).toList() : entries;
    double otherAbs = 0;
    if (entries.length > maxSlices) {
      for (var i = maxSlices - 1; i < entries.length; i++) {
        otherAbs += entries[i].value.abs();
      }
    }

    final sections = <PieChartSectionData>[];
    for (var i = 0; i < shown.length; i++) {
      final e = shown[i];
      final pct = (e.value.abs() / sumAbs * 100).clamp(0.0, 100.0);
      sections.add(
        PieChartSectionData(
          color: _palette[i % _palette.length],
          value: e.value.abs(),
          title: '${pct.toStringAsFixed(0)}%',
          radius: 52,
          titleStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [Shadow(color: Colors.black45, blurRadius: 2)],
          ),
        ),
      );
    }
    if (otherAbs > 0) {
      final pct = (otherAbs / sumAbs * 100).clamp(0.0, 100.0);
      sections.add(
        PieChartSectionData(
          color: AppColors.darkTextSecondary.withValues(alpha: 0.6),
          value: otherAbs,
          title: '${pct.toStringAsFixed(0)}%',
          radius: 52,
          titleStyle: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            shadows: [Shadow(color: Colors.black45, blurRadius: 2)],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Структура по валютам',
          style: context.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 200,
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 2,
                    centerSpaceRadius: 44,
                    sections: sections,
                    pieTouchData: PieTouchData(enabled: true),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: ListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    for (var i = 0; i < shown.length; i++)
                      _LegendRow(
                        color: _palette[i % _palette.length],
                        code: shown[i].key,
                        value: shown[i].value,
                      ),
                    if (otherAbs > 0)
                      _LegendRow(
                        color: AppColors.darkTextSecondary.withValues(alpha: 0.6),
                        code: 'Другое',
                        value: otherAbs,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.color,
    required this.code,
    required this.value,
  });

  final Color color;
  final String code;
  final double value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              CurrencyUtils.display(code),
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${value.abs().formatCurrency()}',
            style: const TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrains Mono',
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
