import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';

/// Vertically-stacked hero amount card from `transfer-create-mobile`.
///
/// Layout (centered):
///   ОТПРАВЛЯЕТСЯ
///   [BIG mono input]
///   [USD · 184 500 доступно ▾]   ← currency / balance pill (opens account sheet)
///   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
///   ПОЛУЧАТЕЛЬ ПОЛУЧИТ
///   [BIG primary mono]
///   [RUB ▾]
///
/// Quick chips (100/500/1k/5k/10k + Макс) sit below, and a rate strip
/// appears when from/to currencies differ.
class MobileHeroAmount extends StatelessWidget {
  const MobileHeroAmount({
    super.key,
    required this.amountController,
    required this.fromCurrency,
    required this.toCurrency,
    required this.balance,
    required this.received,
    required this.insufficient,
    required this.rate,
    required this.onAmountChanged,
    required this.onAccountTap,
    required this.onCurrencyTap,
    required this.onQuickPick,
    required this.onMaxPick,
    this.accountSelected = true,
  });

  final TextEditingController amountController;
  final String fromCurrency;
  final String toCurrency;
  final double balance;
  final double received;
  final bool insufficient;
  final double rate;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onAccountTap;
  final VoidCallback onCurrencyTap;
  final ValueChanged<double> onQuickPick;
  final VoidCallback onMaxPick;

  /// When false the currency pill renders as "Выбрать счёт" prompt.
  final bool accountSelected;

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(amountController.text) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeroCard(
          amountController: amountController,
          fromCurrency: fromCurrency,
          toCurrency: toCurrency,
          balance: balance,
          received: received,
          insufficient: insufficient,
          onAmountChanged: onAmountChanged,
          onAccountTap: onAccountTap,
          onCurrencyTap: onCurrencyTap,
          accountSelected: accountSelected,
        ),
        if (insufficient) ...[
          const SizedBox(height: 10),
          _InsufficientBanner(
            balance: balance,
            currency: fromCurrency,
          ),
        ],
        const SizedBox(height: 12),
        _QuickChips(
          balance: balance,
          onPick: onQuickPick,
          onMax: onMaxPick,
        ),
        if (fromCurrency != toCurrency && amount > 0) ...[
          const SizedBox(height: 12),
          _RateStrip(
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            rate: rate,
          ),
        ],
      ],
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.amountController,
    required this.fromCurrency,
    required this.toCurrency,
    required this.balance,
    required this.received,
    required this.insufficient,
    required this.onAmountChanged,
    required this.onAccountTap,
    required this.onCurrencyTap,
    required this.accountSelected,
  });
  final TextEditingController amountController;
  final String fromCurrency;
  final String toCurrency;
  final double balance;
  final double received;
  final bool insufficient;
  final ValueChanged<String> onAmountChanged;
  final VoidCallback onAccountTap;
  final VoidCallback onCurrencyTap;
  final bool accountSelected;

  @override
  Widget build(BuildContext context) {
    final amount = double.tryParse(amountController.text) ?? 0;
    final received0 = amount > 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.12),
            AppColors.secondary.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            'ОТПРАВЛЯЕТСЯ',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppColors.darkTextTertiary,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: amountController,
            onChanged: onAmountChanged,
            textAlign: TextAlign.center,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [DecimalInputFormatter()],
            style: GoogleFonts.jetBrainsMono(
              fontSize: 42,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.4,
              color: insufficient
                  ? AppColors.error
                  : AppColors.darkTextPrimary,
              height: 1.05,
            ),
            cursorColor: AppColors.primary,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: '0',
              hintStyle: GoogleFonts.jetBrainsMono(
                fontSize: 42,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.4,
                color: AppColors.darkTextDisabled,
                height: 1.05,
              ),
            ),
          ),
          const SizedBox(height: 8),
          _AccountPill(
            currency: fromCurrency,
            balance: balance,
            selected: accountSelected,
            onTap: onAccountTap,
          ),
          const SizedBox(height: 18),
          const _DashedDivider(),
          const SizedBox(height: 14),
          Text(
            'ПОЛУЧАТЕЛЬ ПОЛУЧИТ',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: AppColors.darkTextTertiary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            received0 ? received.formatCurrencyNoDecimals() : '—',
            style: GoogleFonts.jetBrainsMono(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.9,
              color: received0
                  ? AppColors.primary
                  : AppColors.darkTextDisabled,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          _CurrencyPill(currency: toCurrency, onTap: onCurrencyTap),
        ],
      ),
    );
  }
}

class _AccountPill extends StatelessWidget {
  const _AccountPill({
    required this.currency,
    required this.balance,
    required this.selected,
    required this.onTap,
  });
  final String currency;
  final double balance;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.darkSurface,
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Text(
                  currency,
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '· ${balance.formatCurrencyNoDecimals()} доступно',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
              ] else
                Text(
                  'Выбрать счёт',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkTextSecondary,
                  ),
                ),
              const SizedBox(width: 4),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 14,
                color: AppColors.darkTextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CurrencyPill extends StatelessWidget {
  const _CurrencyPill({required this.currency, required this.onTap});
  final String currency;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.primarySurface,
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                currency,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 3),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 13,
                color: AppColors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashedDivider extends StatelessWidget {
  const _DashedDivider();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 1,
      child: CustomPaint(
        painter: _DashPainter(),
        size: const Size(double.infinity, 1),
      ),
    );
  }
}

class _DashPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.darkBorder
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 4.0;
    double x = 0;
    while (x < size.width) {
      canvas.drawLine(
        Offset(x, 0),
        Offset((x + dash).clamp(0, size.width), 0),
        p,
      );
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _InsufficientBanner extends StatelessWidget {
  const _InsufficientBanner({
    required this.balance,
    required this.currency,
  });
  final double balance;
  final String currency;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.10),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.error_outline, size: 14, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Недостаточно: доступно ${balance.formatCurrencyNoDecimals()} $currency',
              style: GoogleFonts.inter(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppColors.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickChips extends StatelessWidget {
  const _QuickChips({
    required this.balance,
    required this.onPick,
    required this.onMax,
  });
  final double balance;
  final ValueChanged<double> onPick;
  final VoidCallback onMax;

  static const _quickValues = [100, 500, 1000, 5000, 10000];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final v in _quickValues) ...[
            _Chip(
              label: v.toDouble().formatCurrencyNoDecimals(),
              onTap: () => onPick(v.toDouble()),
              accent: false,
            ),
            const SizedBox(width: 6),
          ],
          _Chip(label: 'Макс.', onTap: onMax, accent: true),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.label,
    required this.onTap,
    required this.accent,
  });
  final String label;
  final VoidCallback onTap;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(100),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: accent ? AppColors.primarySurface : AppColors.darkCard,
            border: Border.all(
              color: accent
                  ? AppColors.primary.withValues(alpha: 0.3)
                  : AppColors.darkBorder,
            ),
            borderRadius: BorderRadius.circular(100),
          ),
          child: Text(
            label,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: accent
                  ? AppColors.primary
                  : AppColors.darkTextSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _RateStrip extends StatelessWidget {
  const _RateStrip({
    required this.fromCurrency,
    required this.toCurrency,
    required this.rate,
  });
  final String fromCurrency;
  final String toCurrency;
  final double rate;

  String _fmtRate() {
    if (rate <= 0) return '—';
    if (rate < 1) return rate.toStringAsFixed(6);
    if (rate >= 1000) return rate.toStringAsFixed(0);
    return rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 4);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(AppIcons.swap_horiz,
              size: 13, color: AppColors.secondary),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ТЕКУЩИЙ КУРС',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: AppColors.darkTextTertiary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '1 $fromCurrency = ${_fmtRate()} $toCurrency',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.darkTextPrimary,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.primarySurface,
              borderRadius: BorderRadius.circular(100),
            ),
            child: Text(
              'LIVE',
              style: GoogleFonts.inter(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
