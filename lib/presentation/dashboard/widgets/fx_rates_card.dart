import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';
import 'package:ethnocount/presentation/dashboard/widgets/delta_chip.dart';
import 'package:ethnocount/presentation/exchange_rates/bloc/exchange_rate_bloc.dart';

/// Строка курса для отображения: пара, последний курс, delta% к предыдущему,
/// спарклайн из исторических курсов этой же пары.
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

/// Карточка курсов валют. Источник — `ExchangeRateBloc.state.rates` (полная
/// история курсов из public.exchange_rates). По каждой паре берём последние
/// до 20 значений → спарклайн, текущий курс — самый свежий, delta% — между
/// двумя последними.
class FxRatesCard extends StatelessWidget {
  const FxRatesCard({
    super.key,
    this.title = 'Курсы валют',
  });

  final String title;

  /// Свернуть полную историю в список FxRateRow по уникальным парам.
  static List<FxRateRow> _buildRows(List<ExchangeRate> all) {
    if (all.isEmpty) return const [];
    // Группируем по паре, сохраняя порядок «новые сверху».
    final grouped = <String, List<ExchangeRate>>{};
    for (final r in all) {
      final key = '${r.fromCurrency}/${r.toCurrency}';
      grouped.putIfAbsent(key, () => []).add(r);
    }
    final rows = <FxRateRow>[];
    grouped.forEach((key, list) {
      // list в порядке как пришёл из стрима (обычно DESC по effectiveAt).
      final sorted = [...list]
        ..sort((a, b) => a.effectiveAt.compareTo(b.effectiveAt));
      final last = sorted.last;
      final prev = sorted.length > 1 ? sorted[sorted.length - 2] : null;
      final delta = prev == null
          ? 0.0
          : ((last.rate - prev.rate) / (prev.rate == 0 ? 1 : prev.rate)) * 100;
      final spark = sorted
          .skip(sorted.length > 20 ? sorted.length - 20 : 0)
          .map((e) => e.rate)
          .toList();
      rows.add(FxRateRow(
        from: last.fromCurrency,
        to: last.toCurrency,
        rate: last.rate,
        deltaPercent: delta,
        spark: spark.isEmpty ? [last.rate, last.rate] : spark,
      ));
    });
    // Сортируем по абсолютному изменению — самые "движущиеся" наверху.
    rows.sort(
        (a, b) => b.deltaPercent.abs().compareTo(a.deltaPercent.abs()));
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ExchangeRateBloc, ExchangeRateBlocState>(
      builder: (context, state) {
        final rows = _buildRows(state.rates).take(6).toList();
        return _FxRatesView(title: title, rows: rows, loading: state.isLoading);
      },
    );
  }
}

class _FxRatesView extends StatelessWidget {
  const _FxRatesView({
    required this.title,
    required this.rows,
    required this.loading,
  });
  final String title;
  final List<FxRateRow> rows;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
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
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: Text(
                  loading ? 'Загрузка курсов…' : 'Курсы ещё не установлены',
                  style: TextStyle(fontSize: 12, color: secondary),
                ),
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              _FxRateRowTile(row: rows[i]),
              if (i != rows.length - 1)
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
