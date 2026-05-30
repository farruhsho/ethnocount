import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/core/utils/currency_tier.dart';
import 'package:ethnocount/core/utils/currency_utils.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/counterparties/widgets/account_option.dart';
import 'package:ethnocount/presentation/transfers/widgets/contact_autocomplete_field.dart';
import 'package:ethnocount/presentation/transfers/widgets/dealer_rates_block.dart';

/// Открыть диалог «Перевод через партнёра». Возвращает `true`, если
/// перевод успешно создан (страница перезагружает данные).
///
/// [feePercentage] — комиссия партнёра по умолчанию. Автоматически
/// подставится как `commission_value` с type=percentage. Пользователь
/// может изменить.
Future<bool?> showPartnerTransferDialog(
  BuildContext context, {
  required String counterpartyId,
  required String counterpartyName,
  double? feePercentage,
}) {
  return showDialog<bool>(
    context: context,
    builder: (_) => PartnerTransferDialog(
      counterpartyId: counterpartyId,
      counterpartyName: counterpartyName,
      feePercentage: feePercentage,
    ),
  );
}

/// Создание партнёрского перевода (RPC `create_partner_transfer`):
/// debit нашего счёта-источника + transfer сразу в статусе `delivered`
/// + saldo партнёра уходит в минус ровно на сумму выплаты.
///
/// Полный набор полей как в обычной форме перевода:
///  • Отправитель (sender_name + phone с автокомплитом)
///  • Получатель (receiver_name + phone с автокомплитом)
///  • Cross-currency (валюта получения + курс)
///  • 2 чипа комиссии («Внутри перевода» / «На отдельный счёт»)
///  • Чип-роу способов выплаты
///  • Preview итога: «спишем X, комиссия Y, partner saldo: Z»
///  • Idempotency_key в initState — защита от двойного клика.
class PartnerTransferDialog extends StatefulWidget {
  const PartnerTransferDialog({
    super.key,
    required this.counterpartyId,
    required this.counterpartyName,
    this.feePercentage,
  });

  final String counterpartyId;
  final String counterpartyName;
  final double? feePercentage;

  @override
  State<PartnerTransferDialog> createState() => _PartnerTransferDialogState();
}

class _PartnerTransferDialogState extends State<PartnerTransferDialog> {
  // ── Идемпотентность: ключ генерируется ОДИН раз на форму, чтобы
  // двойной клик / случайный double-tap не создавал два перевода.
  // RPC проверяет idempotency_key на unique violation.
  late final String _idempotencyKey;

  String? _accountId;
  String _payoutMethod = 'cash';
  final _amount = TextEditingController();

  // ── Cross-currency (для получателя) ───────────────────────────
  /// Валюта получения. По умолчанию = валюта счёта-источника.
  String? _toCurrency;
  final _exchangeRate = TextEditingController(text: '1');
  String? _rateError;

  // ── Дилерская модель (buy/sell) ───────────────────────────────
  /// Если включено — появляются поля buy_rate/sell_rate. Spread profit
  /// считается автоматически и сохраняется в transfers.spread_profit.
  /// Saldo партнёра ведётся в `_baseCurrency` (а не в валюте счёта).
  bool _dealerMode = false;
  String _baseCurrency = 'USD';
  final _buyRate = TextEditingController();
  final _sellRate = TextEditingController();
  String? _buyRateError;
  String? _sellRateError;

  // ── Sender (отправитель) ──────────────────────────────────────
  final _senderName = TextEditingController();
  final _senderPhone = TextEditingController();
  final _senderInfo = TextEditingController();

  // ── Receiver (получатель в городе партнёра) ──────────────────
  final _receiverName = TextEditingController();
  final _receiverPhone = TextEditingController();
  final _receiverInfo = TextEditingController();

  // ── Комиссия ──────────────────────────────────────────────────
  CommissionType _commissionType = CommissionType.percentage;
  CommissionMode _commissionMode = CommissionMode.fromTransfer;
  final _commissionValue = TextEditingController(text: '0');
  String? _commissionAccountId;

  final _desc = TextEditingController();

  List<AccountOption> _accounts = const [];
  Map<String, double> _balances = const {};
  bool _loadingAccounts = true;
  String? _accountsError;

  /// Список последних получателей через ЭТОГО партнёра. Подгружается
  /// async на старте; если миграция 035 не применена — список пустой
  /// (тихий fallback, никаких ошибок).
  List<_RecentReceiver> _recentReceivers = const [];

  /// Кэш live-курсов для подсказки под полем «Курс». Ключ — пара
  /// `'STRONG/WEAK'` (как её формирует [CurrencyTier.quotePair]).
  /// Значение — курс из `exchange_rates` (последний установленный
  /// оператором в разделе «Курсы валют»). Если в кэше нет — fallback
  /// на захардкоженные ориентировочные значения (см. _fallbackHints).
  final Map<String, double> _liveRateHints = <String, double>{};

  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _idempotencyKey = const Uuid().v4();
    // Авто-подстановка fee_percentage партнёра как % комиссии.
    final fee = widget.feePercentage;
    if (fee != null && fee > 0) {
      _commissionType = CommissionType.percentage;
      _commissionValue.text = _formatRate(fee);
    }
    _loadAccounts();
    _loadRecentReceivers();
  }

  /// Тянем последних получателей через ЭТОГО партнёра. Если миграция
  /// 035 не применена — RPC отсутствует, ловим ошибку и оставляем
  /// пустой список (chip-row просто не отрисуется).
  Future<void> _loadRecentReceivers() async {
    try {
      final rows = await Supabase.instance.client.rpc(
        'recent_partner_receivers',
        params: {'p_counterparty_id': widget.counterpartyId, 'p_limit': 6},
      ).timeout(const Duration(seconds: 8));
      final list = (rows as List)
          .map((m) => _RecentReceiver.fromMap(
              Map<String, dynamic>.from(m as Map)))
          .toList();
      _deferSetState(() => _recentReceivers = list);
    } catch (_) {
      // RPC ещё не применён — fallback: пустой список.
    }
  }

  /// Подставляет получателя в форму. Если телефон есть — кладём как
  /// есть; имя/инфо тоже. Курсор после.
  void _applyRecent(_RecentReceiver r) {
    setState(() {
      _receiverName.text = r.name ?? '';
      _receiverPhone.text = r.phone ?? '';
      _receiverInfo.text = r.info ?? '';
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _exchangeRate.dispose();
    _buyRate.dispose();
    _sellRate.dispose();
    _senderName.dispose();
    _senderPhone.dispose();
    _senderInfo.dispose();
    _receiverName.dispose();
    _receiverPhone.dispose();
    _receiverInfo.dispose();
    _commissionValue.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final user = context.read<AuthBloc>().state.user;
    final allowed = accessibleBranchIds(user);
    try {
      final accFuture = Supabase.instance.client
          .from('branch_accounts')
          .select('id, branch_id, name, currency, type, is_active, '
              'branches(name)')
          .eq('is_active', true)
          .order('name');
      final balFuture =
          Supabase.instance.client.from('account_balances').select();
      final results = await Future.wait(<Future<dynamic>>[accFuture, balFuture]);
      final accRows = results[0] as List;
      final balRows = results[1] as List;

      final list = accRows
          .map((m) =>
              AccountOption.fromMap(Map<String, dynamic>.from(m as Map)))
          // Транзитные счета для контрагентов как ИСТОЧНИК не подходят —
          // эти деньги уже «привязаны». Скрываем.
          .where((a) => a.type != 'transit')
          .where((a) => allowed == null || allowed.contains(a.branchId))
          .toList()
        // Сортировка branch → currency → name: в дропдауне счета одной
        // валюты идут подряд внутри филиала, операторы перестают путать
        // USD/RUB/UZS-кассы в смешанном списке.
        ..sort((a, b) {
          final byBranch = a.branchName.compareTo(b.branchName);
          if (byBranch != 0) return byBranch;
          final byCurrency = a.currency.compareTo(b.currency);
          if (byCurrency != 0) return byCurrency;
          return a.name.compareTo(b.name);
        });
      final balances = <String, double>{
        for (final r in balRows)
          (r as Map)['account_id'] as String:
              ((r['balance'] ?? 0) as num).toDouble(),
      };
      _deferSetState(() {
        _accounts = list;
        _balances = balances;
        _loadingAccounts = false;
      });
    } catch (e) {
      _deferSetState(() {
        _loadingAccounts = false;
        _accountsError = e.toString();
      });
    }
  }

  void _deferSetState(VoidCallback fn) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(fn);
    });
  }

  AccountOption? get _selectedAccount {
    if (_accountId == null) return null;
    for (final a in _accounts) {
      if (a.id == _accountId) return a;
    }
    return null;
  }

  AccountOption? get _selectedCommissionAccount {
    if (_commissionAccountId == null) return null;
    for (final a in _accounts) {
      if (a.id == _commissionAccountId) return a;
    }
    return null;
  }

  String get _sourceCurrency =>
      _selectedAccount?.currency.toUpperCase() ?? 'USD';

  String get _payoutCurrency => (_toCurrency ?? _sourceCurrency).toUpperCase();

  double get _amountValue =>
      double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0;

  double get _rateInput =>
      double.tryParse(_exchangeRate.text.replaceAll(',', '.')) ?? 1;

  double get _buyRateValue =>
      double.tryParse(_buyRate.text.replaceAll(',', '.')) ?? 0;

  double get _sellRateValue =>
      double.tryParse(_sellRate.text.replaceAll(',', '.')) ?? 0;

  /// USD-эквивалент принятой суммы (amount / buy_rate). Сколько мы реально
  /// взяли «в базовой валюте» — это то, что партнёр нам должен.
  double get _baseAmount {
    if (!_dealerMode || _buyRateValue <= 0) return _amountValue;
    return _amountValue / _buyRateValue;
  }

  /// Сколько мы должны партнёру в валюте принятия (по sell_rate).
  /// Если same-currency или sell не указан — = amount (нет конвертации).
  double get _partnerOwesInLocal {
    if (!_dealerMode || _sellRateValue <= 0) return _amountValue;
    return _baseAmount * _sellRateValue;
  }

  /// Прибыль с курса (spread) в валюте принятия.
  double get _spreadProfit {
    if (!_dealerMode) return 0;
    if (_buyRateValue <= 0 || _sellRateValue <= 0) return 0;
    return _amountValue - _partnerOwesInLocal;
  }

  double get _multiplier => CurrencyTier.multiplierFromInput(
        _rateInput,
        _sourceCurrency,
        _payoutCurrency,
      );

  /// Сумма получателю в валюте выплаты.
  double get _convertedAmount =>
      _amountValue * (_sourceCurrency == _payoutCurrency ? 1 : _multiplier);

  /// Комиссия (в валюте источника, для preview).
  double get _commissionAmount {
    final v = double.tryParse(_commissionValue.text.replaceAll(',', '.')) ?? 0;
    if (v <= 0) return 0;
    if (_commissionType == CommissionType.percentage) {
      return (_amountValue * v) / 100.0;
    }
    return v;
  }

  /// Сколько всего спишется со счёта-источника.
  double get _totalDebit {
    if (_commissionMode == CommissionMode.fromSender) {
      return _amountValue + _commissionAmount;
    }
    return _amountValue;
  }

  /// Подсказка под полем курса. Объясняет направление котировки и даёт
  /// ориентир, если оператор не помнит порядок («1 USD = сколько UZS,
  /// а не наоборот»). Hints подобраны под пары, которые мы реально
  /// используем — оператор почти никогда не вводит EUR→AED.
  /// Захардкоженный fallback. Эти числа — НЕ источник истины, а резерв
  /// для случая когда `exchange_rates` пустой (новый филиал, ещё не
  /// вводили курсы). Цифры стартовые ~2024 — со временем устаревают,
  /// но это нормально: оператор вводит реальный курс в форме, помощник
  /// лишь подсказывает порядок величины.
  static const _fallbackHints = <String, String>{
    'USD/UZS': '≈ 12 700',
    'USD/RUB': '≈ 92',
    'USD/KZT': '≈ 470',
    'USD/KGS': '≈ 89',
    'USD/TJS': '≈ 11',
    'USD/CNY': '≈ 7.2',
    'USD/TRY': '≈ 33',
    'USD/AED': '≈ 3.67',
    'EUR/USD': '≈ 1.08',
    'EUR/UZS': '≈ 13 700',
    'EUR/RUB': '≈ 99',
    'RUB/UZS': '≈ 140',
    'RUB/KZT': '≈ 5.1',
    'RUB/KGS': '≈ 0.97',
    'KZT/UZS': '≈ 27',
    'CNY/UZS': '≈ 1750',
    'CNY/RUB': '≈ 12.7',
    'TRY/UZS': '≈ 380',
    'AED/UZS': '≈ 3450',
    'GBP/USD': '≈ 1.27',
  };

  String _rateHelper() {
    final pair = CurrencyTier.quotePair(_sourceCurrency, _payoutCurrency);
    if (pair == null) return 'Введите курс конвертации';
    final (strong, weak) = pair;
    final key = '$strong/$weak';

    // 1. Сначала — живой курс из exchange_rates (последний введённый).
    final live = _liveRateHints[key];
    if (live != null && live > 0) {
      final formatted = live == live.roundToDouble()
          ? live.toStringAsFixed(0)
          : live.toStringAsFixed(live < 10 ? 3 : 2);
      return '1 $strong ≈ $formatted $weak (из «Курсы валют»)';
    }

    // 2. Fallback — захардкоженный ориентир.
    final fallback = _fallbackHints[key];
    if (fallback != null) return '1 $strong $fallback $weak';
    return '1 $strong = X $weak (введи число)';
  }

  /// Подгружает свежий курс strong→weak из `exchange_rates` и кеширует
  /// его для helperText. Вызывается при смене валют. Если RPC ничего
  /// не вернул — helper откатится на fallback из `_fallbackHints`.
  Future<void> _refreshLiveRateHint() async {
    final pair = CurrencyTier.quotePair(_sourceCurrency, _payoutCurrency);
    if (pair == null) return;
    final (strong, weak) = pair;
    final key = '$strong/$weak';
    if (_liveRateHints.containsKey(key)) return; // уже подгружено
    try {
      final direct = await sl<ExchangeRateRepository>()
          .getLatestRate(strong, weak)
          .then((r) => r.fold((_) => null, (v) => v));
      double? rate = (direct?.rate ?? 0) > 0 ? direct!.rate : null;
      if (rate == null) {
        final inverse = await sl<ExchangeRateRepository>()
            .getLatestRate(weak, strong)
            .then((r) => r.fold((_) => null, (v) => v));
        if ((inverse?.rate ?? 0) > 0) rate = 1 / inverse!.rate;
      }
      if (!mounted || rate == null || rate <= 0) return;
      setState(() => _liveRateHints[key] = rate!);
    } catch (_) {
      // Тихий fallback — helper останется на статичном hint.
    }
  }

  String _formatRate(double r) {
    if (r == r.roundToDouble()) return r.toStringAsFixed(0);
    return r.toString();
  }

  Future<void> _submit() async {
    final account = _selectedAccount;
    if (account == null) {
      setState(() => _error = 'Выберите счёт-источник');
      return;
    }
    if (_amountValue <= 0) {
      setState(() => _error = 'Введите сумму больше 0');
      return;
    }
    if (_amountValue > (_balances[account.id] ?? 0)) {
      setState(() => _error =
          'Недостаточно средств. Доступно: ${(_balances[account.id] ?? 0).formatCurrencyNoDecimals()} ${account.currency}');
      return;
    }
    final receiverName = _receiverName.text.trim();
    if (receiverName.isEmpty) {
      setState(() => _error = 'Укажите ФИО получателя');
      return;
    }
    final senderName = _senderName.text.trim();
    if (senderName.isEmpty) {
      setState(() =>
          _error = 'Укажите ФИО отправителя — нужно для отчётности');
      return;
    }
    if (_sourceCurrency != _payoutCurrency && _multiplier <= 0) {
      setState(() => _rateError = 'Введите курс');
      return;
    }
    if (_dealerMode) {
      if (_buyRateValue <= 0) {
        setState(() => _buyRateError = 'Введите наш курс приёма');
        return;
      }
      if (_sellRateValue <= 0) {
        setState(() => _sellRateError = 'Введите курс расчёта с партнёром');
        return;
      }
      if (_baseCurrency == _sourceCurrency) {
        setState(() => _error =
            'Базовая валюта совпадает с валютой счёта — дилерский режим '
            'имеет смысл только при разных валютах. Выберите другую '
            'базовую валюту или отключите дилерский режим.');
        return;
      }
    }
    final commissionValueRaw =
        double.tryParse(_commissionValue.text.replaceAll(',', '.')) ?? 0;
    if (commissionValueRaw < 0) {
      setState(() => _error = 'Комиссия не может быть отрицательной');
      return;
    }
    if (_commissionType == CommissionType.percentage &&
        commissionValueRaw > 50) {
      setState(() =>
          _error = 'Комиссия > 50% — это явно ошибка. Проверь значение.');
      return;
    }
    if (_commissionMode == CommissionMode.fromAccount &&
        commissionValueRaw > 0 &&
        _commissionAccountId == null) {
      setState(() => _error =
          'Для режима «На отдельный счёт» укажите счёт зачисления комиссии');
      return;
    }
    if (_commissionMode == CommissionMode.fromAccount &&
        _commissionAccountId != null) {
      final commAcc = _selectedCommissionAccount;
      if (commAcc == null || commAcc.branchId != account.branchId) {
        setState(() => _error =
            'Счёт комиссии должен принадлежать тому же филиалу, что и счёт-источник');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final params = <String, dynamic>{
        'p_from_branch_id': account.branchId,
        'p_from_account_id': account.id,
        'p_counterparty_id': widget.counterpartyId,
        'p_amount': _amountValue,
        'p_currency': account.currency,
        'p_payout_method': _payoutMethod,
        'p_commission_type': _commissionType.name,
        'p_commission_value': commissionValueRaw,
        'p_commission_mode': _commissionMode.name,
        'p_idempotency_key': _idempotencyKey,
        if (_commissionMode != CommissionMode.fromAccount)
          'p_commission_currency': account.currency,
        if (_commissionMode == CommissionMode.fromAccount &&
            _commissionAccountId != null)
          'p_commission_account_id': _commissionAccountId,
        if (_desc.text.trim().isNotEmpty)
          'p_description': _desc.text.trim(),
        'p_sender_name': senderName,
        if (_senderPhone.text.trim().isNotEmpty)
          'p_sender_phone': _normalizedPhone(_senderPhone.text),
        if (_senderInfo.text.trim().isNotEmpty)
          'p_sender_info': _senderInfo.text.trim(),
        'p_receiver_name': receiverName,
        if (_receiverPhone.text.trim().isNotEmpty)
          'p_receiver_phone': _normalizedPhone(_receiverPhone.text),
        if (_receiverInfo.text.trim().isNotEmpty)
          'p_receiver_info': _receiverInfo.text.trim(),
        if (_sourceCurrency != _payoutCurrency) ...{
          'p_to_currency': _payoutCurrency,
          'p_exchange_rate': _multiplier,
        },
        if (_dealerMode) ...{
          'p_buy_rate': _buyRateValue,
          'p_sell_rate': _sellRateValue,
          'p_base_currency': _baseCurrency,
        },
      };
      await Supabase.instance.client
          .rpc('create_partner_transfer', params: params);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = _humanizeError(e);
      });
    }
  }

  /// Сворачивает «+7 920 988 38 76» в E.164 «+79209883876».
  /// БД-триггер 034 нормализует ещё раз, но клиент шлёт сразу чистый
  /// формат — это надёжнее для дедупликации в `searchContacts`.
  String _normalizedPhone(String raw) =>
      '+${raw.replaceAll(RegExp(r'[^\d]'), '')}';

  String _humanizeError(Object e) {
    final s = e.toString();
    if (s.contains('Insufficient funds')) {
      final m = RegExp(r'Available:\s*([\d.]+),\s*required:\s*([\d.]+)')
          .firstMatch(s);
      if (m != null) {
        return 'Недостаточно средств. Доступно: ${m.group(1)}, требуется: ${m.group(2)}';
      }
      return 'Недостаточно средств на выбранном счёте';
    }
    if (s.contains('архивирован')) {
      return 'Партнёр архивирован — операции запрещены. Разархивируйте его.';
    }
    if (s.contains('PGRST') || s.contains('42883')) {
      return 'RPC create_partner_transfer не найдена или старой сигнатуры. '
          'Примените миграцию 034.';
    }
    if (s.contains('Duplicate')) {
      return 'Перевод уже был создан (двойной клик?). Обновите страницу.';
    }
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selectedAccount;

    // Defensive: dropdowns не должны получить initialValue, которого нет
    // в items, иначе Flutter падает с assertion.
    final safeAccountId =
        _accounts.any((a) => a.id == _accountId) ? _accountId : null;
    final commItems = _accounts
        .where((a) => selected == null || a.branchId == selected.branchId)
        .toList();
    final safeCommAccId = commItems.any((a) => a.id == _commissionAccountId)
        ? _commissionAccountId
        : null;

    // Список валют для «Валюта получения». Берём из настроек филиала,
    // если есть; иначе общий список.
    final payoutCurrencies = CurrencyUtils.supported;
    final isCrossCurrency = _sourceCurrency != _payoutCurrency;

    return AlertDialog(
      title: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(AppIcons.send, size: 18, color: scheme.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Перевод через партнёра'),
                Text(
                  widget.counterpartyName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 1. Откуда списать ─────────────────────────
              const _SectionTitle('Откуда списываем'),
              if (_loadingAccounts)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                )
              else if (_accountsError != null)
                _ErrorBox(text: 'Не удалось загрузить счета: $_accountsError')
              else if (_accounts.isEmpty)
                const _ErrorBox(
                  text: 'Нет доступных счетов. Сначала создайте счёт филиала.',
                )
              else
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: safeAccountId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Наш счёт-источник *',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(AppIcons.account_balance, size: 20),
                      ),
                      items: _accounts
                          .map((a) => DropdownMenuItem(
                                value: a.id,
                                child: Text(
                                  a.displayLabel,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _accountId = v;
                          // При смене счёта — сброс toCurrency и rate.
                          if (v != null) {
                            final acc =
                                _accounts.firstWhere((a) => a.id == v);
                            _toCurrency = acc.currency;
                            _exchangeRate.text = '1';
                            _rateError = null;
                          }
                        });
                        _refreshLiveRateHint();
                      },
                    ),
                    if (selected != null) ...[
                      const SizedBox(height: 6),
                      _BalanceLine(
                        balance: _balances[selected.id] ?? 0,
                        currency: selected.currency,
                      ),
                    ],
                  ],
                ),
              const SizedBox(height: AppSpacing.md),

              // ── 2. Сумма + валюта + курс ───────────────────
              const _SectionTitle('Сумма и курс'),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        DecimalInputFormatter(),
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Сумма к списанию',
                        border: const OutlineInputBorder(),
                        suffixText: _sourceCurrency,
                        prefixIcon: const Icon(AppIcons.payments, size: 20),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      initialValue:
                          payoutCurrencies.contains(_payoutCurrency)
                              ? _payoutCurrency
                              : _sourceCurrency,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Валюта выплаты',
                        border: OutlineInputBorder(),
                      ),
                      items: payoutCurrencies
                          .map((c) => DropdownMenuItem(
                                value: c,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(CurrencyUtils.flag(c)),
                                    const SizedBox(width: 6),
                                    Text(c,
                                        style:
                                            const TextStyle(fontSize: 13)),
                                  ],
                                ),
                              ))
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _toCurrency = v;
                          // При смене валюты — сброс курса.
                          _exchangeRate.text =
                              v == _sourceCurrency ? '1' : '';
                          _rateError = null;
                        });
                        _refreshLiveRateHint();
                      },
                    ),
                  ),
                ],
              ),
              if (isCrossCurrency) ...[
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _exchangeRate,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  inputFormatters: [
                    DecimalInputFormatter(),
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  onChanged: (_) => setState(() => _rateError = null),
                  decoration: InputDecoration(
                    labelText:
                        CurrencyTier.rateLabel(_sourceCurrency, _payoutCurrency),
                    helperText: _rateHelper(),
                    border: const OutlineInputBorder(),
                    errorText: _rateError,
                    prefixIcon:
                        const Icon(AppIcons.swap_horiz, size: 20),
                  ),
                ),
                // Live превью: «100 000 UZS → 690 RUB». Видно сразу при
                // вводе курса, чтобы оператор поймал ошибку «забыл
                // нолик» до отправки.
                if (_amountValue > 0 && _multiplier > 0) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Row(
                      children: [
                        Icon(AppIcons.arrow_forward,
                            size: 14,
                            color: Theme.of(context)
                                .colorScheme
                                .primary),
                        const SizedBox(width: 6),
                        Text(
                          '${_amountValue.formatCurrencyNoDecimals()} '
                          '$_sourceCurrency  =  '
                          '${_convertedAmount.formatCurrencyNoDecimals()} '
                          '$_payoutCurrency',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
              const SizedBox(height: AppSpacing.md),

              // ── 2.5. Дилерская модель (buy/sell rate) ─────
              _DealerModeToggle(
                enabled: _dealerMode,
                onChanged: (v) => setState(() {
                  _dealerMode = v;
                  if (!v) {
                    _buyRate.clear();
                    _sellRate.clear();
                    _buyRateError = null;
                    _sellRateError = null;
                  }
                }),
              ),
              if (_dealerMode) ...[
                const SizedBox(height: AppSpacing.sm),
                DealerRatesBlock(
                  baseCurrency: _baseCurrency,
                  sourceCurrency: _sourceCurrency,
                  onBaseChanged: (v) =>
                      setState(() => _baseCurrency = v),
                  buyController: _buyRate,
                  buyError: _buyRateError,
                  onBuyChanged: () =>
                      setState(() => _buyRateError = null),
                  sellController: _sellRate,
                  sellError: _sellRateError,
                  onSellChanged: () =>
                      setState(() => _sellRateError = null),
                  spreadProfit: _spreadProfit,
                  spreadCurrency: _sourceCurrency,
                  baseAmount: _baseAmount,
                ),
                const SizedBox(height: AppSpacing.md),
              ],

              // ── 3. Способ выплаты — chip-row ──────────────
              const _SectionTitle('Способ выплаты получателю'),
              _PayoutMethodChips(
                value: _payoutMethod,
                onChanged: (v) => setState(() => _payoutMethod = v),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 4. Отправитель ─────────────────────────────
              const _SectionTitle('Отправитель (у нас)'),
              TextField(
                controller: _senderName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'ФИО отправителя *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.person_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ContactAutocompleteField(
                side: 'sender',
                phoneController: _senderPhone,
                nameController: _senderName,
                infoController: _senderInfo,
                label: 'Телефон отправителя',
                hintText: '+7 920 988 38 76',
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _senderInfo,
                decoration: const InputDecoration(
                  labelText: 'Доп. инфо отправителя',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.info_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 5. Получатель в городе партнёра ───────────
              const _SectionTitle('Получатель (у партнёра)'),
              if (_recentReceivers.isNotEmpty) ...[
                _RecentReceiversBar(
                  receivers: _recentReceivers,
                  onSelect: _applyRecent,
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
              TextField(
                controller: _receiverName,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'ФИО получателя *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.person_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              ContactAutocompleteField(
                side: 'receiver',
                phoneController: _receiverPhone,
                nameController: _receiverName,
                infoController: _receiverInfo,
                label: 'Телефон получателя',
                hintText: '+998 90 123 45 67',
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _receiverInfo,
                decoration: const InputDecoration(
                  labelText: 'Доп. инфо (карта, паспорт)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.info_outline, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 6. Комиссия — 2 чипа + значение ───────────
              const _SectionTitle('Комиссия'),
              _CommissionModeChips(
                mode: _commissionMode,
                onChanged: (m) => setState(() {
                  _commissionMode = m;
                  if (m != CommissionMode.fromAccount) {
                    _commissionAccountId = null;
                  }
                }),
              ),
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: SegmentedButton<CommissionType>(
                      segments: const [
                        ButtonSegment(
                            value: CommissionType.percentage,
                            label: Text('%')),
                        ButtonSegment(
                            value: CommissionType.fixed, label: Text('Фикс')),
                      ],
                      selected: {_commissionType},
                      onSelectionChanged: (s) => setState(() {
                        _commissionType = s.first;
                      }),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _commissionValue,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        DecimalInputFormatter(),
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: 'Значение',
                        border: const OutlineInputBorder(),
                        suffixText:
                            _commissionType == CommissionType.percentage
                                ? '%'
                                : _sourceCurrency,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              if (_commissionMode == CommissionMode.fromAccount) ...[
                const SizedBox(height: AppSpacing.sm),
                if (commItems.isEmpty)
                  const _ErrorBox(
                    text:
                        'Сначала выберите счёт-источник — счёт комиссии должен быть в том же филиале.',
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: safeCommAccId,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Счёт зачисления комиссии',
                      border: OutlineInputBorder(),
                      helperText: 'Валюта берётся из этого счёта',
                    ),
                    items: commItems
                        .map((a) => DropdownMenuItem(
                              value: a.id,
                              child: Text(a.displayLabel,
                                  style: const TextStyle(fontSize: 13),
                                  overflow: TextOverflow.ellipsis),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _commissionAccountId = v),
                  ),
              ],
              const SizedBox(height: AppSpacing.md),

              // ── 7. Описание ───────────────────────────────
              TextField(
                controller: _desc,
                maxLines: 2,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Описание / комментарий',
                  hintText: 'Зарплата, возврат долга, семейный…',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.description, size: 20),
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── 8. Preview итога ──────────────────────────
              if (selected != null && _amountValue > 0)
                _Preview(
                  totalDebit: _totalDebit,
                  sourceCurrency: _sourceCurrency,
                  payoutAmount: _convertedAmount,
                  payoutCurrency: _payoutCurrency,
                  commission: _commissionAmount,
                  commissionMode: _commissionMode,
                  partnerName: widget.counterpartyName,
                  // Дилерская часть (если включено).
                  dealerMode: _dealerMode,
                  spreadProfit: _spreadProfit,
                  baseAmount: _baseAmount,
                  baseCurrency: _baseCurrency,
                ),

              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                  ),
                  child: Row(
                    children: [
                      Icon(AppIcons.warning_amber,
                          size: 16, color: AppColors.error),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                              color: AppColors.error, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppIcons.send, size: 18),
          label: const Text('Создать перевод'),
        ),
      ],
    );
  }
}

/// Лёгкая модель «последнего получателя» через партнёра (миграция 035).
class _RecentReceiver {
  _RecentReceiver({
    this.phone,
    this.name,
    this.info,
    this.lastAmount,
    this.lastCurrency,
    this.transferCount = 0,
  });

  factory _RecentReceiver.fromMap(Map<String, dynamic> m) => _RecentReceiver(
        phone: (m['phone'] as String?)?.trim(),
        name: (m['name'] as String?)?.trim(),
        info: (m['info'] as String?)?.trim(),
        lastAmount: (m['last_amount'] as num?)?.toDouble(),
        lastCurrency: (m['last_currency'] as String?)?.trim(),
        transferCount: (m['transfer_count'] as num?)?.toInt() ?? 0,
      );

  final String? phone;
  final String? name;
  final String? info;
  final double? lastAmount;
  final String? lastCurrency;
  final int transferCount;

  String get label {
    if ((name ?? '').isNotEmpty) return name!;
    if ((phone ?? '').isNotEmpty) return phone!;
    return '—';
  }
}

/// Горизонтальный chip-row «Последние получатели» — быстрая подстановка
/// постоянных получателей через этого партнёра. Закрывает 80% случаев,
/// когда бухгалтер каждый месяц отправляет одним и тем же людям
/// (зарплата, рента, регулярные платежи).
class _RecentReceiversBar extends StatelessWidget {
  const _RecentReceiversBar({
    required this.receivers,
    required this.onSelect,
  });

  final List<_RecentReceiver> receivers;
  final ValueChanged<_RecentReceiver> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: scheme.outline.withValues(alpha: 0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.history, size: 14, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Постоянные получатели',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: receivers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final r = receivers[i];
                return ActionChip(
                  onPressed: () => onSelect(r),
                  avatar: CircleAvatar(
                    backgroundColor: scheme.primary.withValues(alpha: 0.18),
                    child: Text(
                      r.label.characters.first.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: scheme.primary,
                      ),
                    ),
                  ),
                  label: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        r.label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (r.transferCount > 1) ...[
                        const SizedBox(width: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color:
                                scheme.primary.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '×${r.transferCount}',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      child: Text(
        text,
        style: TextStyle(color: AppColors.error, fontSize: 12),
      ),
    );
  }
}

/// Подпись «Доступно: X CUR» под выбранным счётом. Если баланс
/// отрицательный — предупреждение о расхождении кэша.
class _BalanceLine extends StatelessWidget {
  const _BalanceLine({required this.balance, required this.currency});
  final double balance;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final negative = balance < 0;
    final color = negative ? scheme.error : scheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Row(
        children: [
          Icon(
            negative ? AppIcons.warning_amber : AppIcons.check_circle,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 6),
          Text(
            negative
                ? 'Баланс: ${balance.formatCurrencyNoDecimals()} $currency — кэш разъехался с журналом, запустите аудит'
                : 'Доступно: ${balance.formatCurrencyNoDecimals()} $currency',
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 4 чипа способа выплаты: Наличные / Карта / Банк. перевод / Другое.
/// Заменяет dropdown — короткие лейблы лучше как chip-row.
class _PayoutMethodChips extends StatelessWidget {
  const _PayoutMethodChips({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  static const _items = [
    ('cash', 'Наличные', AppIcons.payments),
    ('card', 'Карта', AppIcons.credit_card),
    ('transfer', 'Банк', AppIcons.account_balance),
    ('other', 'Другое', AppIcons.more_horiz),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _items.map((item) {
        final selected = value == item.$1;
        return ChoiceChip(
          selected: selected,
          onSelected: (_) => onChanged(item.$1),
          avatar: Icon(
            item.$3,
            size: 16,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          label: Text(item.$2),
          labelStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
          selectedColor: scheme.primary,
          backgroundColor:
              scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          showCheckmark: false,
        );
      }).toList(),
    );
  }
}

/// 2 чипа режима комиссии — идентичный UX с обычной формой перевода
/// (создание перевода уже использует тот же подход).
class _CommissionModeChips extends StatelessWidget {
  const _CommissionModeChips({
    required this.mode,
    required this.onChanged,
  });

  final CommissionMode mode;
  final ValueChanged<CommissionMode> onChanged;

  static const _visibleModes = [
    CommissionMode.fromTransfer,
    CommissionMode.fromAccount,
  ];

  @override
  Widget build(BuildContext context) {
    final selected =
        _visibleModes.contains(mode) ? mode : CommissionMode.fromTransfer;
    return SegmentedButton<CommissionMode>(
      segments: _visibleModes
          .map((m) => ButtonSegment<CommissionMode>(
                value: m,
                label: Text(
                  m == CommissionMode.fromTransfer
                      ? 'Внутри перевода'
                      : 'На отдельный счёт',
                  style: const TextStyle(fontSize: 12),
                ),
                icon: Icon(
                  m == CommissionMode.fromTransfer
                      ? Icons.call_merge
                      : Icons.account_balance_wallet_outlined,
                  size: 16,
                ),
              ))
          .toList(),
      selected: {selected},
      onSelectionChanged: (v) => onChanged(v.first),
      showSelectedIcon: false,
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        ),
      ),
    );
  }
}

/// Preview итога: какие реально будут эффекты от перевода. Закрывает
/// классический UX-gap — пользователь не должен в уме считать, что
/// «10 USD комиссия + 1000 USD сумма = 1010 USD спишется».
class _Preview extends StatelessWidget {
  const _Preview({
    required this.totalDebit,
    required this.sourceCurrency,
    required this.payoutAmount,
    required this.payoutCurrency,
    required this.commission,
    required this.commissionMode,
    required this.partnerName,
    this.dealerMode = false,
    this.spreadProfit = 0,
    this.baseAmount = 0,
    this.baseCurrency = '',
  });

  final double totalDebit;
  final String sourceCurrency;
  final double payoutAmount;
  final String payoutCurrency;
  final double commission;
  final CommissionMode commissionMode;
  final String partnerName;
  final bool dealerMode;
  final double spreadProfit;
  final double baseAmount;
  final String baseCurrency;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isCross = sourceCurrency != payoutCurrency;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            scheme.primary.withValues(alpha: 0.10),
            scheme.primary.withValues(alpha: 0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: scheme.primary.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.fact_check, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'Что произойдёт',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _PreviewRow(
            icon: AppIcons.arrow_upward,
            label: 'Спишется со счёта',
            value: '${totalDebit.formatCurrencyNoDecimals()} $sourceCurrency',
            accent: scheme.error,
          ),
          if (commission > 0) ...[
            const SizedBox(height: 4),
            _PreviewRow(
              icon: AppIcons.percent,
              label: commissionMode == CommissionMode.fromAccount
                  ? 'Комиссия → отдельный счёт'
                  : 'Комиссия (внутри суммы)',
              value:
                  '${commission.formatCurrencyNoDecimals()} $sourceCurrency',
              accent: scheme.primary,
            ),
          ],
          const SizedBox(height: 4),
          _PreviewRow(
            icon: AppIcons.arrow_downward,
            label: 'Получит клиент через $partnerName',
            value:
                '${payoutAmount.formatCurrencyNoDecimals()} $payoutCurrency',
            accent: isCross ? scheme.tertiary : scheme.primary,
            bold: true,
          ),
          const SizedBox(height: 4),
          _PreviewRow(
            icon: AppIcons.account_tree,
            label: '$partnerName станет должен нам',
            value: dealerMode
                ? '${baseAmount.formatCurrencyNoDecimals()} $baseCurrency'
                : '${totalDebit.formatCurrencyNoDecimals()} $sourceCurrency',
            accent: scheme.onSurfaceVariant,
          ),
          // ── Дилерская прибыль ───────────────────────────
          if (dealerMode && spreadProfit > 0) ...[
            const Divider(height: 16),
            _PreviewRow(
              icon: AppIcons.currency_exchange,
              label: 'Прибыль с курса (spread)',
              value:
                  '${spreadProfit.formatCurrencyNoDecimals()} $sourceCurrency',
              accent: Colors.green.shade600,
              bold: true,
            ),
          ],
        ],
      ),
    );
  }
}

/// Переключатель «Дилерский режим» — раскрывает поля buy_rate/sell_rate
/// и базовой валюты. Текст подсказки объясняет смысл без жаргона.
class _DealerModeToggle extends StatelessWidget {
  const _DealerModeToggle({required this.enabled, required this.onChanged});
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(AppSpacing.radiusMd);
    // Material+InkWell оборачивает всю строку — теперь тап по тексту/
    // фону переключает Switch, а не только нажатие точно по тумблеру.
    return Material(
      color: enabled
          ? scheme.primary.withValues(alpha: 0.08)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.4),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => onChanged(!enabled),
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(
              color: enabled
                  ? scheme.primary.withValues(alpha: 0.3)
                  : scheme.outline.withValues(alpha: 0.15),
            ),
          ),
          child: Row(
            children: [
              Switch(
                value: enabled,
                onChanged: onChanged,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Дилерский режим (учёт прибыли с курса)',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: enabled ? scheme.primary : null,
                      ),
                    ),
                    Text(
                      enabled
                          ? 'Указываем buy/sell rate — система посчитает spread'
                          : 'Включи если принимаешь в UZS, а долг партнёра ведёшь в USD',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    this.bold = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 14, color: accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
            color: accent,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
