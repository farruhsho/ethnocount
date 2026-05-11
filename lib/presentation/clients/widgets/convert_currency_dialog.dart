import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/presentation/clients/bloc/client_bloc.dart';

/// Открывает bottom-sheet (mobile) или диалог (desktop) для конвертации
/// валют клиента. Принимает текущий [client], [balance] и валюту, с которой
/// пользователь начал операцию ([initialFrom]). Курс — «1 from = X to».
Future<void> showConvertCurrencyDialog({
  required BuildContext context,
  required Client client,
  required ClientBalance? balance,
  required String initialFrom,
}) async {
  if (balance == null) return;
  final size = MediaQuery.of(context).size;
  final isCompact = size.width < 600;

  // Захватываем ClientBloc в контексте вызова: showDialog/showModalBottomSheet
  // создают route поверх корневого Navigator, чей контекст НЕ под нашим
  // BlocProvider<ClientBloc> (он живёт только в ClientsPage). Без этого —
  // ProviderNotFoundException при первом же context.read<ClientBloc>().
  final bloc = context.read<ClientBloc>();

  Widget wrap(Widget child) =>
      BlocProvider<ClientBloc>.value(value: bloc, child: child);

  final body = _ConvertCurrencyBody(
    client: client,
    balance: balance,
    initialFrom: initialFrom,
  );

  if (isCompact) {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => wrap(
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: body,
        ),
      ),
    );
  } else {
    await showDialog<void>(
      context: context,
      builder: (ctx) => wrap(
        Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: body,
          ),
        ),
      ),
    );
  }
}

class _ConvertCurrencyBody extends StatefulWidget {
  const _ConvertCurrencyBody({
    required this.client,
    required this.balance,
    required this.initialFrom,
  });

  final Client client;
  final ClientBalance balance;
  final String initialFrom;

  @override
  State<_ConvertCurrencyBody> createState() => _ConvertCurrencyBodyState();
}

class _ConvertCurrencyBodyState extends State<_ConvertCurrencyBody> {
  late String _from;
  late String _to;
  final _amountCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  String? _amountError;
  String? _rateError;

  @override
  void initState() {
    super.initState();
    _from = widget.initialFrom;
    _to = _pickInitialTo(_from);
  }

  String _pickInitialTo(String from) {
    final wallet = widget.client.walletCurrencies;
    for (final c in wallet) {
      if (c != from) return c;
    }
    // fallback: первая разная из списка валют
    for (final c in CurrencyUtils.supported) {
      if (c != from) return c;
    }
    return from;
  }

  /// Валюты-источники = только те, в которых ненулевой баланс.
  List<String> get _availableFrom {
    final result = <String>{};
    widget.balance.balancesByCurrency.forEach((c, v) {
      if (v > 0.0049) result.add(c);
    });
    if (result.isEmpty) {
      result.addAll(widget.client.walletCurrencies);
    }
    return result.toList()..sort();
  }

  /// Валюты-цели = wallet_currencies клиента + основной список (без `from`).
  List<String> get _availableTo {
    final set = <String>{};
    set.addAll(widget.client.walletCurrencies);
    set.addAll(CurrencyUtils.supported);
    set.remove(_from);
    return set.toList()..sort();
  }

  double get _fromBalance =>
      widget.balance.balancesByCurrency[_from] ?? 0;

  double? get _amount => double.tryParse(_amountCtrl.text);
  double? get _rate => double.tryParse(_rateCtrl.text);

  double get _toAmount => (_amount ?? 0) * (_rate ?? 0);

  @override
  void dispose() {
    _amountCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  void _swap() {
    setState(() {
      final old = _from;
      _from = _to;
      _to = old;
      _amountCtrl.clear();
      _rateCtrl.clear();
      _amountError = null;
      _rateError = null;
    });
  }

  bool get _canSubmit {
    final amount = _amount;
    final rate = _rate;
    if (amount == null || amount <= 0) return false;
    if (rate == null || rate <= 0) return false;
    if (amount > _fromBalance + 0.0001) return false;
    return _from != _to;
  }

  void _submit(BuildContext context) {
    final amount = _amount;
    final rate = _rate;
    if (amount == null || amount <= 0) {
      setState(() => _amountError = 'Введите сумму > 0');
      return;
    }
    if (amount > _fromBalance + 0.0001) {
      setState(() => _amountError =
          'Недостаточно средств. Доступно: ${_fromBalance.formatCurrency()} $_from');
      return;
    }
    if (rate == null || rate <= 0) {
      setState(() => _rateError = 'Курс должен быть > 0');
      return;
    }

    context.read<ClientBloc>().add(ClientConvertRequested(
          clientId: widget.client.id,
          fromCurrency: _from,
          toCurrency: _to,
          amount: amount,
          rate: rate,
        ));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.isDark;
    final scheme = Theme.of(context).colorScheme;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;

    return BlocListener<ClientBloc, ClientBlocState>(
      listenWhen: (a, b) => a.status != b.status,
      listener: (ctx, state) {},
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.sm,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [AppColors.primary, AppColors.secondary],
                      ),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.swap_horiz_rounded,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Конвертация валюты',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          widget.client.name,
                          style: TextStyle(fontSize: 11.5, color: secondary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),

              // ── Selectors row: from -> to ──
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _CurrencyPicker(
                        label: 'Из',
                        value: _from,
                        balance: _fromBalance,
                        options: _availableFrom,
                        onChanged: (v) {
                          setState(() {
                            _from = v;
                            if (_to == _from) _to = _pickInitialTo(_from);
                            _amountError = null;
                          });
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs),
                      child: Center(
                        child: IconButton.filledTonal(
                          onPressed: _swap,
                          icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                          tooltip: 'Поменять местами',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 36, minHeight: 36),
                        ),
                      ),
                    ),
                    Expanded(
                      child: _CurrencyPicker(
                        label: 'В',
                        value: _to,
                        balance: widget.balance.balancesByCurrency[_to] ?? 0,
                        options: _availableTo,
                        onChanged: (v) => setState(() => _to = v),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── Amount field ──
              TextFormField(
                controller: _amountCtrl,
                decoration: InputDecoration(
                  labelText: 'Сумма к списанию',
                  border: const OutlineInputBorder(),
                  suffixText: _from,
                  hintText: '0',
                  errorText: _amountError,
                  helperText:
                      'Доступно: ${_fromBalance.formatCurrency()} $_from',
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [DecimalInputFormatter()],
                onChanged: (_) => setState(() => _amountError = null),
              ),
              const SizedBox(height: AppSpacing.sm),

              // ── Rate field ──
              TextFormField(
                controller: _rateCtrl,
                decoration: InputDecoration(
                  labelText: 'Курс · 1 $_from = ? $_to',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.percent_rounded, size: 18),
                  suffixText: _to,
                  hintText: _hintRate(_from, _to),
                  errorText: _rateError,
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [DecimalInputFormatter()],
                onChanged: (_) => setState(() => _rateError = null),
              ),
              const SizedBox(height: AppSpacing.lg),

              // ── Preview ──
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.10),
                      AppColors.secondary.withValues(alpha: 0.04),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
                  border: Border.all(
                    color: AppColors.primary.withValues(alpha: 0.25),
                    width: 0.6,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Получит на кошелёк $_to',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: secondary,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            _toAmount > 0
                                ? _toAmount.formatCurrency()
                                : '0.00',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                              height: 1,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _to,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_amount != null && _rate != null && _toAmount > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${_amount!.formatCurrency()} $_from × ${_rate!.toStringAsFixed(_rate! < 10 ? 4 : 2)} = ${_toAmount.formatCurrency()} $_to',
                        style: TextStyle(
                          fontSize: 11,
                          color: secondary,
                          fontFamily: 'JetBrains Mono',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── Actions ──
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: BlocBuilder<ClientBloc, ClientBlocState>(
                      buildWhen: (a, b) => a.status != b.status,
                      builder: (ctx, state) {
                        final busy = state.status == ClientBlocStatus.operating;
                        return FilledButton.icon(
                          onPressed: (_canSubmit && !busy)
                              ? () => _submit(context)
                              : null,
                          icon: busy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.swap_horiz_rounded),
                          label: const Text('Конвертировать'),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _hintRate(String from, String to) {
    // Подсказки для типичных пар.
    const hints = {
      'USD-UZS': '12700',
      'USD-RUB': '92',
      'USD-KZT': '460',
      'USD-KGS': '88',
      'USD-EUR': '0.92',
      'EUR-USD': '1.08',
      'RUB-UZS': '138',
      'KGS-UZS': '143',
    };
    return hints['$from-$to'] ?? '1.0';
  }
}

class _CurrencyPicker extends StatelessWidget {
  const _CurrencyPicker({
    required this.label,
    required this.value,
    required this.balance,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final double balance;
  final List<String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = context.isDark;
    final secondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.lightTextSecondary;
    final opts = options.contains(value) ? options : [value, ...options];

    return Container(
      padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: scheme.outline.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              color: secondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: opts.contains(value) ? value : opts.first,
              isExpanded: true,
              isDense: true,
              items: opts
                  .map(
                    (c) => DropdownMenuItem(
                      value: c,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(CurrencyUtils.flag(c),
                              style: const TextStyle(fontSize: 14)),
                          const SizedBox(width: 6),
                          Text(c,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              )),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
          Text(
            balance.formatCurrency(),
            style: TextStyle(
              fontSize: 11,
              color: balance > 0.0049 ? AppColors.primary : secondary,
              fontFamily: 'JetBrains Mono',
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
