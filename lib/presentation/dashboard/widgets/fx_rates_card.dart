import 'dart:math' as math;
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/presentation/dashboard/widgets/delta_chip.dart';

/// Локальная in-memory модель FX для UI до появления стрима курсов.
class FxRateRow {
  const FxRateRow({
    required this.from,
    required this.to,
    required this.rate,
    required this.deltaPercent,
    required this.spark,
  });
  final String from;
  final String to;
  final double rate;
  final double deltaPercent;
  final List<double> spark;
}

/// Карточка курсов валют: 4 пары + спарклайны + delta-чипы.
/// Сейчас — заглушки (см. [defaultRates]); когда появится репозиторий
/// курсов, заменить на реальные данные без правки UI.
class FxRatesCard extends StatelessWidget {
  const FxRatesCard({
    super.key,
    this.title = 'Курсы валют',
    this.rates,
  });

  final String title;
  final List<FxRateRow>? rates;

  static List<FxRateRow> defaultRates() {
    final rng = math.Random(7);
    List<double> spark(double base) {
      var v = base;
      return List.generate(20, (_) {
        v = v + (rng.nextDouble() - 0.45) * base * 0.005;
        return v;
      });
    }
    return [
      FxRateRow(from: 'USD', to: 'UZS', rate: 12780.5, deltaPercent: 0.3, spark: spark(12780.5)),
      FxRateRow(from: 'USD', to: 'RUB', rate: 92.4, deltaPercent: -0.6, spark: spark(92.4)),
      FxRateRow(from: 'USD', to: 'KZT', rate: 522.1, deltaPercent: 0.1, spark: spark(522.1)),
      FxRateRow(from: 'EUR', to: 'USD', rate: 1.085, deltaPercent: 0.2, spark: spark(1.085)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final list = rates ?? defaultRates();
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

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
              Text(
                'обновлено сейчас',
                style: TextStyle(fontSize: 10, color: secondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < list.length; i++) ...[
            _FxRateRowTile(row: list[i]),
            if (i != list.length - 1)
              Divider(
                height: AppSpacing.md,
                thickness: 0.4,
                color: secondary.withValues(alpha: 0.15),
              ),
          ],
        ],
      ),
    );
  }
}

class _FxRateRowTile extends StatelessWidget {
  const _FxRateRowTile({required this.row});
  final FxRateRow row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              '${row.from}/${row.to}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Expanded(
            child: SizedBox(
              height: 26,
              child: _Spark(values: row.spark, deltaPercent: row.deltaPercent),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(
            row.rate.toStringAsFixed(row.rate >= 100 ? 1 : 4),
            style: GoogleFonts.jetBrainsMono(
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          DeltaChip(
            compact: true,
            label: '${row.deltaPercent >= 0 ? '+' : ''}${row.deltaPercent.toStringAsFixed(2)}%',
            delta: row.deltaPercent,
          ),
        ],
      ),
    );
  }
}

class _Spark extends StatelessWidget {
  const _Spark({required this.values, required this.deltaPercent});
  final List<double> values;
  final double deltaPercent;

  @override
  Widget build(BuildContext context) {
    final color =
        deltaPercent >= 0 ? AppColors.primary : AppColors.error;
    final spots = [
      for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
    ];
    return LineChart(
      LineChartData(
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.3,
            color: color,
            barWidth: 1.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  color.withValues(alpha: 0.25),
                  color.withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
