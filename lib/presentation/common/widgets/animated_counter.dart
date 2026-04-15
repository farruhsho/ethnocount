import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_durations.dart';
import 'package:ethnocount/core/constants/app_typography.dart';

/// Animated counter that smoothly interpolates between values.
/// Used for balance displays and dashboard hero numbers.
class AnimatedCounter extends StatelessWidget {
  const AnimatedCounter({
    super.key,
    required this.value,
    this.prefix = '',
    this.suffix = '',
    this.style,
    this.duration,
    this.curve = Curves.easeOutCubic,
    this.decimalPlaces = 2,
  });

  final double value;
  final String prefix;
  final String suffix;
  final TextStyle? style;
  final Duration? duration;
  final Curve curve;
  final int decimalPlaces;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: duration ?? AppDurations.dramatic,
      curve: curve,
      builder: (context, animatedValue, _) {
        final formatted = _formatNumber(animatedValue);
        return Text(
          '$prefix$formatted$suffix',
          style: style ?? AppTypography.monoLarge.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        );
      },
    );
  }

  String _formatNumber(double number) {
    final parts = number.toStringAsFixed(decimalPlaces).split('.');
    final intPart = parts[0];
    final decPart = parts.length > 1 ? parts[1] : '';

    // Add thousand separators
    final buffer = StringBuffer();
    final digits = intPart.replaceAll('-', '');
    final isNegative = number < 0;
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[i]);
    }

    final result = '${isNegative ? '-' : ''}$buffer${decimalPlaces > 0 ? '.$decPart' : ''}';
    return result;
  }
}

/// Colored animated counter for income/expense amounts.
class ColoredAmountCounter extends StatelessWidget {
  const ColoredAmountCounter({
    super.key,
    required this.amount,
    required this.currency,
    this.style,
    this.showSign = true,
  });

  final double amount;
  final String currency;
  final TextStyle? style;
  final bool showSign;

  @override
  Widget build(BuildContext context) {
    final color = amount >= 0 ? AppColors.income : AppColors.expense;
    final sign = showSign ? (amount >= 0 ? '+' : '') : '';

    return AnimatedCounter(
      value: amount,
      prefix: sign,
      suffix: ' $currency',
      style: (style ?? AppTypography.monoMedium).copyWith(color: color),
    );
  }
}
