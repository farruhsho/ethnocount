import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';

/// Glassmorphism design tokens and helper widgets.
class Glassmorphism {
  Glassmorphism._();

  /// Standard glass decoration for cards.
  static BoxDecoration cardDecoration(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: isDark ? AppColors.glassWhite : AppColors.glassDark,
      borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
      border: Border.all(
        color: isDark ? AppColors.glassBorder : AppColors.glassDarkBorder,
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }

  /// Strong glass effect for hero elements.
  static BoxDecoration heroDecoration(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      gradient: isDark
          ? const LinearGradient(
              colors: [Color(0x33FFFFFF), Color(0x0DFFFFFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            )
          : const LinearGradient(
              colors: [Color(0x80FFFFFF), Color(0x33FFFFFF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
      borderRadius: BorderRadius.circular(AppSpacing.radiusXl),
      border: Border.all(
        color: isDark ? AppColors.glassBorder : AppColors.glassDarkBorder,
        width: 1.5,
      ),
      boxShadow: [
        BoxShadow(
          color: AppColors.primary.withValues(alpha: 0.15),
          blurRadius: 32,
          offset: const Offset(0, 12),
        ),
      ],
    );
  }

  /// Blur sigma for backdrop filter.
  static const double blurSigma = 20.0;
  static const double lightBlurSigma = 10.0;
}

/// A glassmorphic container widget with blur backdrop.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius,
    this.blur,
    this.hero = false,
  });

  final Widget child;
  final EdgeInsets? padding;
  final EdgeInsets? margin;
  final BorderRadius? borderRadius;
  final double? blur;
  final bool hero;

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(AppSpacing.radiusLg);

    return Container(
      margin: margin,
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: blur ?? Glassmorphism.blurSigma,
            sigmaY: blur ?? Glassmorphism.blurSigma,
          ),
          child: Container(
            decoration: hero
                ? Glassmorphism.heroDecoration(context)
                : Glassmorphism.cardDecoration(context),
            padding: padding ?? const EdgeInsets.all(AppSpacing.cardPadding),
            child: child,
          ),
        ),
      ),
    );
  }
}
