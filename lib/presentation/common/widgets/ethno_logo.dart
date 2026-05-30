import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_branding.dart';
import 'package:ethnocount/core/constants/app_colors.dart';

/// Текстовый бренд приложения: квадратная монограмма + wordmark.
/// Источник истины для имени — [kAppDisplayName] / [kAppMonogram].
///
/// [height] задаёт высоту монограммы; wordmark масштабируется пропорционально.
/// Можно вывести только монограмму через [monogramOnly]: true (для узких мест).
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({
    super.key,
    this.height = 40,
    this.monogramOnly = false,
    this.color,
  });

  final double height;
  final bool monogramOnly;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = color ??
        (scheme.brightness == Brightness.light
            ? AppColors.primary
            : AppColors.primaryLight);

    final mono = Container(
      width: height,
      height: height,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(height * 0.18),
        border: Border.all(color: accent, width: 1.2),
      ),
      alignment: Alignment.center,
      child: Text(
        kAppMonogram,
        style: GoogleFonts.inter(
          fontSize: height * 0.48,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.5,
          color: accent,
          height: 1,
        ),
      ),
    );

    if (monogramOnly) return mono;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        mono,
        SizedBox(width: height * 0.32),
        Text(
          kAppDisplayName,
          style: GoogleFonts.inter(
            fontSize: height * 0.46,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: scheme.onSurface,
            height: 1,
          ),
        ),
      ],
    );
  }
}

