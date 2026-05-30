import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';

/// "Hero amount" block from the `transfer-create-desktop` reference.
///
/// Left: huge JetBrains-Mono input bound to [amountController] + currency
/// pill + branch hint + live "insufficient" banner.
/// Right: dashed-divider, "Получает" label, big mono received amount, branch
/// hint, currency picker (read-only display — picker callback wired through
/// [onChangeToCurrency]).
/// Bottom strip: 4 tiles — Курс / Комиссия / Списание / Идемпотент.
class HeroAmountSection extends StatelessWidget {
  const HeroAmountSection({
    super.key,
    required this.amountController,
    required this.fromCurrency,
    required this.toCurrency,
    required this.fromBranchCode,
    required this.toBranchCode,
    required this.received,
    required this.balance,
    required this.insufficient,
    required this.rate,
    required this.commissionLabel,
    required this.commission,
    required this.commissionCurrency,
    required this.totalDebit,
    required this.onAmountChanged,
    required this.onChangeToCurrency,
    required this.toCurrencyOptions,
  });

  final TextEditingController amountController;
  final String fromCurrency;
  final String toCurrency;
  final String fromBranchCode;
  final String toBranchCode;
  final double received;
  final double balance;
  final bool insufficient;
  final double rate;
  final String commissionLabel;
  final double commission;
  final String commissionCurrency;
  final double totalDebit;
  final ValueChanged<String> onAmountChanged;
  final ValueChanged<String> onChangeToCurrency;
  final List<String> toCurrencyOptions;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 26, 28, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppColors.primary.withValues(alpha: 0.10),
            AppColors.secondary.withValues(alpha: 0.04),
          ],
        ),
        border: Border.all(color: AppColors.darkBorder),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // LayoutBuilder removed: HeroAmountSection is always rendered in
          // the desktop+dark hero column (≥ 560 px wide), so the wide-row
          // layout is the only valid mode. The previous LayoutBuilder was
          // re-creating InkWell-bearing children on every layout pass and
          // racing with mouse_tracker on Flutter web.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SendingColumn(
                  amountController: amountController,
                  fromCurrency: fromCurrency,
                  fromBranchCode: fromBranchCode,
                  insufficient: insufficient,
                  balance: balance,
                  onChanged: onAmountChanged,
                ),
              ),
              const _ArrowDivider(),
              Expanded(
                child: _ReceivingColumn(
                  received: received,
                  toCurrency: toCurrency,
                  toBranchCode: toBranchCode,
                  onChangeToCurrency: onChangeToCurrency,
                  toOptions: toCurrencyOptions,
                  alignRight: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          const Divider(
            color: AppColors.darkDivider,
            height: 1,
            thickness: 0.6,
          ),
          const SizedBox(height: 16),
          _RateStrip(
            fromCurrency: fromCurrency,
            toCurrency: toCurrency,
            rate: rate,
            commissionLabel: commissionLabel,
            commission: commission,
            commissionCurrency: commissionCurrency,
            totalDebit: totalDebit,
            balance: balance,
            insufficient: insufficient,
          ),
        ],
      ),
    );
  }
}

class _SendingColumn extends StatelessWidget {
  const _SendingColumn({
    required this.amountController,
    required this.fromCurrency,
    required this.fromBranchCode,
    required this.insufficient,
    required this.balance,
    required this.onChanged,
  });
  final TextEditingController amountController;
  final String fromCurrency;
  final String fromBranchCode;
  final bool insufficient;
  final double balance;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label('ОТПРАВЛЯЕТСЯ', color: AppColors.darkTextTertiary),
        const SizedBox(height: 6),
        TextField(
          controller: amountController,
          onChanged: onChanged,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalInputFormatter()],
          style: GoogleFonts.jetBrainsMono(
            fontSize: 56,
            fontWeight: FontWeight.w800,
            letterSpacing: -1.5,
            color: AppColors.darkTextPrimary,
            height: 1.05,
          ),
          cursorColor: AppColors.primary,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            hintText: '0',
            hintStyle: GoogleFonts.jetBrainsMono(
              fontSize: 56,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.5,
              color: AppColors.darkTextDisabled,
              height: 1.05,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _Pill(
              text: fromCurrency,
              mono: true,
              bg: AppColors.darkSurface,
              border: AppColors.darkBorder,
              color: AppColors.darkTextPrimary,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                fromBranchCode.isEmpty
                    ? 'выберите счёт'
                    : 'с $fromBranchCode · Касса $fromCurrency',
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  color: AppColors.darkTextTertiary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (insufficient) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.10),
              border: Border.all(
                color: AppColors.error.withValues(alpha: 0.30),
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(AppIcons.error_outline,
                    size: 13, color: AppColors.error),
                const SizedBox(width: 6),
                Text(
                  'Недостаточно: доступно ${balance.formatCurrencyNoDecimals()} $fromCurrency',
                  style: GoogleFonts.inter(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.error,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ReceivingColumn extends StatelessWidget {
  const _ReceivingColumn({
    required this.received,
    required this.toCurrency,
    required this.toBranchCode,
    required this.onChangeToCurrency,
    required this.toOptions,
    required this.alignRight,
  });
  final double received;
  final String toCurrency;
  final String toBranchCode;
  final ValueChanged<String> onChangeToCurrency;
  final List<String> toOptions;
  final bool alignRight;

  @override
  Widget build(BuildContext context) {
    final cross =
        alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final hasReceived = received > 0;
    final padding = alignRight
        ? const EdgeInsets.only(left: 24)
        : EdgeInsets.zero;
    return Padding(
      padding: padding,
      child: Container(
        decoration: alignRight
            ? const BoxDecoration(
                border: Border(
                  left: BorderSide(color: AppColors.darkBorder, width: 0.6),
                ),
              )
            : null,
        padding: alignRight ? const EdgeInsets.only(left: 24) : null,
        child: Column(
          crossAxisAlignment: cross,
          children: [
            _Label('ПОЛУЧАЕТ', color: AppColors.primary),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: alignRight
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Text(
                hasReceived ? received.formatCurrencyNoDecimals() : '—',
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 48,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  color: hasReceived
                      ? AppColors.primary
                      : AppColors.darkTextDisabled,
                  height: 1.05,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: alignRight
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                Flexible(
                  child: Text(
                    toBranchCode.isEmpty
                        ? 'выберите получателя'
                        : 'в $toBranchCode',
                    style: GoogleFonts.inter(
                      fontSize: 11.5,
                      color: AppColors.darkTextTertiary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                _CurrencyPicker(
                  value: toCurrency,
                  options: toOptions,
                  onChanged: onChangeToCurrency,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrowDivider extends StatelessWidget {
  const _ArrowDivider();
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: AppColors.darkCardHover,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.darkBorder),
        ),
        alignment: Alignment.center,
        child: const Icon(
          AppIcons.arrow_forward,
          size: 14,
          color: AppColors.primary,
        ),
      ),
    );
  }
}

class _CurrencyPicker extends StatelessWidget {
  const _CurrencyPicker({
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  /// We avoid [PopupMenuButton] here: on Flutter web it can trip the
  /// `_debugDuringDeviceUpdate` assertion (mouse_tracker.dart:199) when the
  /// menu opens/closes while the cursor is over the trigger. A modal bottom
  /// sheet behaves the same UX-wise and doesn't churn MouseRegions.
  Future<void> _open(BuildContext context) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkCard,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      isScrollControlled: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.darkBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Валюта получения',
                style: GoogleFonts.inter(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppColors.darkTextPrimary,
                ),
              ),
              const SizedBox(height: 14),
              for (final c in options)
                Material(
                  color: c == value
                      ? AppColors.primarySurface
                      : AppColors.darkSurface,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.of(ctx).pop(c),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: c == value
                              ? AppColors.primary
                              : AppColors.darkBorder,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Text(
                            c,
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: c == value
                                  ? AppColors.primary
                                  : AppColors.darkTextPrimary,
                            ),
                          ),
                          const Spacer(),
                          if (c == value)
                            const Icon(AppIcons.check,
                                size: 14, color: AppColors.primary),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.darkSurface,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.darkBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
              const SizedBox(width: 3),
              const Icon(Icons.keyboard_arrow_down_rounded,
                  size: 14, color: AppColors.primary),
            ],
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
    required this.commissionLabel,
    required this.commission,
    required this.commissionCurrency,
    required this.totalDebit,
    required this.balance,
    required this.insufficient,
  });
  final String fromCurrency;
  final String toCurrency;
  final double rate;
  final String commissionLabel;
  final double commission;
  final String commissionCurrency;
  final double totalDebit;
  final double balance;
  final bool insufficient;

  String _fmtRate() {
    if (fromCurrency == toCurrency) return '1.000000';
    if (rate <= 0) return '—';
    if (rate < 1) return '1 $fromCurrency = ${rate.toStringAsFixed(6)} $toCurrency';
    if (rate >= 1000) {
      return '1 $fromCurrency = ${rate.toStringAsFixed(0)} $toCurrency';
    }
    return '1 $fromCurrency = ${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 4)} $toCurrency';
  }

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _Tile(
        label: 'Курс',
        value: _fmtRate(),
        mono: true,
        accent: true,
      ),
      _Tile(
        label: commissionLabel,
        value: '${commission.formatCurrency()} $commissionCurrency',
        mono: true,
      ),
      _Tile(
        label: 'Списание со счёта',
        value: '${totalDebit.formatCurrencyNoDecimals()} $fromCurrency',
        sub: 'из ${balance.formatCurrencyNoDecimals()}',
        mono: true,
        danger: insufficient,
      ),
      _Tile(
        label: 'Идемпотент. ключ',
        value: 'auto-generate',
        sub: 'UUID v4',
        small: true,
      ),
    ];
    // Always 4 columns on the desktop+dark hero (column width ≥ 520).
    // GridView is still fine without a LayoutBuilder — it just uses the
    // parent constraint directly. No MouseRegion race on layout.
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 4,
      mainAxisSpacing: 14,
      crossAxisSpacing: 16,
      childAspectRatio: 3.4,
      children: tiles,
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.label,
    required this.value,
    this.sub,
    this.mono = false,
    this.accent = false,
    this.danger = false,
    this.small = false,
  });
  final String label;
  final String value;
  final String? sub;
  final bool mono;
  final bool accent;
  final bool danger;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? AppColors.error
        : (accent ? AppColors.primary : AppColors.darkTextPrimary);
    final valueStyle = mono
        ? GoogleFonts.jetBrainsMono(
            fontSize: small ? 12 : 13.5,
            fontWeight: FontWeight.w700,
            color: color,
          )
        : GoogleFonts.inter(
            fontSize: small ? 12 : 13.5,
            fontWeight: FontWeight.w700,
            color: color,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Label(label.toUpperCase(), color: AppColors.darkTextTertiary),
        const SizedBox(height: 5),
        Text(value, maxLines: 2, overflow: TextOverflow.ellipsis, style: valueStyle),
        if (sub != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              sub!,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                color: AppColors.darkTextTertiary,
              ),
            ),
          ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        color: color,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.text,
    required this.bg,
    required this.border,
    required this.color,
    this.mono = false,
  });
  final String text;
  final Color bg;
  final Color border;
  final Color color;
  final bool mono;
  @override
  Widget build(BuildContext context) {
    final style = mono
        ? GoogleFonts.jetBrainsMono(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
          )
        : GoogleFonts.inter(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: color,
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: style),
    );
  }
}
