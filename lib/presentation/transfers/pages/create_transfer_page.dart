import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/core/extensions/number_x.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:flutter/services.dart';
import 'package:ethnocount/core/utils/decimal_input_formatter.dart';
import 'package:ethnocount/core/utils/phone_input_formatter.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:uuid/uuid.dart';

class CreateTransferPage extends StatefulWidget {
  const CreateTransferPage({super.key});

  @override
  State<CreateTransferPage> createState() => _CreateTransferPageState();
}

class _CreateTransferPageState extends State<CreateTransferPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _commissionValueController = TextEditingController(text: '0');
  final _exchangeRateController = TextEditingController(text: '1.0');
  final _senderNameCtrl = TextEditingController();
  final _senderPhoneCtrl = TextEditingController();
  final _senderInfoCtrl = TextEditingController();
  final _receiverNameCtrl = TextEditingController();
  final _receiverPhoneCtrl = TextEditingController();
  final _receiverInfoCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();

  /// Clears "0" / "0.0" placeholder when field receives focus.
  void _smartClear(TextEditingController ctrl) {
    final t = ctrl.text.trim();
    if (t == '0' || t == '0.0' || t == '0.00' || t == '1.0') {
      ctrl.clear();
    }
  }

  void _restoreDefault(TextEditingController ctrl, String def) {
    if (ctrl.text.trim().isEmpty) ctrl.text = def;
  }
  CommissionType _commissionType = CommissionType.fixed;
  String _transferCurrency = 'USD';
  String _toCurrency = 'USD';
  String _commissionCurrency = 'USD';

  String? _fromBranchId;
  String? _toBranchId;
  String? _fromAccountId;

  /// Ошибка недостатка средств — подсвечиваем поле суммы красным.
  String? _balanceError;

  String? _exchangeRateError;
  String? _commissionError;

  /// Филиалы, к которым у пользователя есть доступ (для выбора отправителя).
  List<Branch> _branches = [];
  /// Все филиалы (для выбора получателя — бухгалтеры видят все).
  List<Branch> _allBranches = [];
  List<BranchAccount> _fromAccounts = [];

  StreamSubscription<List<Branch>>? _branchesSub;
  StreamSubscription<List<BranchAccount>>? _accountsSub;

  @override
  void initState() {
    super.initState();
    // After first frame: [context.read<AuthBloc>] is reliable; stream alone can
    // emit before UI and leave dropdowns disabled (empty items).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _branchesSub?.cancel();
      _branchesSub = sl<BranchRepository>().watchBranches().listen((branches) {
        if (!mounted) return;
        final user = context.read<AuthBloc>().state.user;
        setState(() {
          _allBranches = branches;
          _branches = filterBranchesByAccess(branches, user);
        });
      });
    });
  }

  void _loadAccountsFor(String branchId) {
    _accountsSub?.cancel();
    _accountsSub = sl<BranchRepository>().watchBranchAccounts(branchId).listen(
      (accounts) {
        if (!mounted) return;
        setState(() {
          _fromAccounts = accounts;
          if (_fromAccountId != null) {
            final match = accounts.where((a) => a.id == _fromAccountId);
            if (match.isNotEmpty) {
              _transferCurrency = match.first.currency;
              _toCurrency = match.first.currency;
              _commissionCurrency = match.first.currency;
            }
          }
        });
      },
    );
  }

  @override
  void dispose() {
    _branchesSub?.cancel();
    _accountsSub?.cancel();
    _amountController.dispose();
    _commissionValueController.dispose();
    _exchangeRateController.dispose();
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _senderInfoCtrl.dispose();
    _receiverNameCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverInfoCtrl.dispose();
    _descriptionCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<TransferBloc, TransferBlocState>(
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(state.successMessage ?? 'Перевод создан'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          Navigator.of(context).pop();
        }
        if (state.status == TransferBlocStatus.error) {
          final msg = state.errorMessage ?? 'Ошибка';
          final displayMsg = _formatInsufficientFundsError(msg);
          setState(() {
            if (msg.toLowerCase().contains('insufficient') || msg.contains('недостаточно')) {
              _balanceError = displayMsg;
            }
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                displayMsg,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              backgroundColor: Theme.of(context).colorScheme.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      },
      builder: (context, state) {
        return Scaffold(
          appBar: AppBar(title: const Text('Новый перевод')),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  children: [
                    if (context.isDesktop)
                      _buildDesktopForm(context, state)
                    else
                      _buildMobileForm(context, state),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildDesktopForm(BuildContext context, TransferBlocState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _buildSenderSection()),
            const SizedBox(width: AppSpacing.sectionGap),
            Expanded(child: _buildReceiverSection()),
          ],
        ),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildDetailsSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildPreview(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildSubmitButton(context, state),
      ],
    );
  }

  Widget _buildMobileForm(BuildContext context, TransferBlocState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSenderSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildReceiverSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildDetailsSection(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildPreview(),
        const SizedBox(height: AppSpacing.sectionGap),
        _buildSubmitButton(context, state),
      ],
    );
  }

  Widget _buildSenderSection() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (prev, curr) => prev.branches != curr.branches,
      builder: (context, dash) {
        final user = context.read<AuthBloc>().state.user;
        final senderBranches = _branches.isNotEmpty
            ? _branches
            : filterBranchesByAccess(dash.branches, user);

        return _FormSection(
          title: 'Отправитель',
          icon: Icons.arrow_upward_rounded,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(
                'from-branch-${senderBranches.length}-$_fromBranchId',
              ),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Филиал отправителя',
                border: OutlineInputBorder(),
              ),
              initialValue: _fromBranchId != null &&
                      senderBranches.any((b) => b.id == _fromBranchId)
                  ? _fromBranchId
                  : null,
              hint: senderBranches.isEmpty
                  ? const Text('Нет доступных филиалов')
                  : const Text('Выберите филиал'),
              items: senderBranches
                  .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                  .toList(),
              onChanged: senderBranches.isEmpty
                  ? null
                  : (v) {
                      setState(() {
                        _fromBranchId = v;
                        _fromAccountId = null;
                        _fromAccounts = [];
                      });
                      if (v != null) _loadAccountsFor(v);
                    },
              validator: (v) => v == null ? 'Выберите филиал' : null,
            ),
            if (senderBranches.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs, bottom: 4),
                child: Text(
                  'Обратитесь к администратору для назначения филиалов.',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.formFieldGap),
            DropdownButtonFormField<String>(
              key: ValueKey('from-acc-$_fromAccountId-${_fromAccounts.length}'),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Счёт отправителя',
                border: OutlineInputBorder(),
              ),
              initialValue: _fromAccountId != null &&
                      _fromAccounts.any((a) => a.id == _fromAccountId)
                  ? _fromAccountId
                  : null,
              items: _fromAccounts
                  .map(
                    (a) => DropdownMenuItem(
                      value: a.id,
                      child: Text(
                        '${_currFlag(a.currency)} ${a.name} (${a.currency})',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                setState(() {
                  _fromAccountId = v;
                  _balanceError = null;
                  if (v != null) {
                    final match = _fromAccounts.where((a) => a.id == v);
                    if (match.isNotEmpty) {
                      _transferCurrency = match.first.currency;
                    }
                  }
                });
              },
              validator: (v) => v == null ? 'Выберите счёт' : null,
            ),
        if (_fromAccountId != null)
          BlocBuilder<DashboardBloc, DashboardState>(
            builder: (context, dashState) {
              final balance = dashState.accountBalances[_fromAccountId] ?? 0;
              return Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Text(
                  'Доступно: ${balance.formatCurrencyNoDecimals()} $_transferCurrency',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              );
            },
          ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _senderNameCtrl,
          decoration: const InputDecoration(
            labelText: 'ФИО отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _senderPhoneCtrl,
          decoration: const InputDecoration(
            labelText: 'Телефон отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_outlined, size: 20),
            isDense: true,
            hintText: '+7 900 123 45 67',
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            PhoneInputFormatter(),
            LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
          ],
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _senderInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо отправителя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.info_outline, size: 20),
            isDense: true,
          ),
        ),
          ],
        );
      },
    );
  }

  Widget _buildReceiverSection() {
    return BlocBuilder<DashboardBloc, DashboardState>(
      buildWhen: (prev, curr) => prev.branches != curr.branches,
      builder: (context, dash) {
        final allBranches = _allBranches.isNotEmpty
            ? _allBranches
            : dash.branches;
        final receiverItems = allBranches
            .where((b) => b.id != _fromBranchId)
            .toList();

        return _FormSection(
          title: 'Получатель',
          icon: Icons.arrow_downward_rounded,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(
                'to-branch-${receiverItems.length}-$_toBranchId-$_fromBranchId',
              ),
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Филиал получателя',
                border: OutlineInputBorder(),
              ),
              initialValue: _toBranchId != null &&
                      receiverItems.any((b) => b.id == _toBranchId)
                  ? _toBranchId
                  : null,
              hint: receiverItems.isEmpty
                  ? const Text('Нет других филиалов')
                  : const Text('Выберите филиал'),
              items: receiverItems
                  .map((b) => DropdownMenuItem(value: b.id, child: Text(b.name)))
                  .toList(),
              onChanged: receiverItems.isEmpty
                  ? null
                  : (v) => setState(() => _toBranchId = v),
              validator: (v) => v == null ? 'Выберите филиал' : null,
            ),
        const SizedBox(height: AppSpacing.sm),
        TextFormField(
          controller: _descriptionCtrl,
          decoration: const InputDecoration(
            labelText: 'Назначение платежа',
            hintText: 'Оплата по договору, аванс, возврат...',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.description_outlined, size: 20),
            isDense: true,
          ),
          maxLines: 2,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'Счёт получателя укажет бухгалтер филиала при подтверждении',
          style: TextStyle(
            fontSize: 12,
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        TextFormField(
          controller: _receiverNameCtrl,
          decoration: const InputDecoration(
            labelText: 'ФИО получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.person_outline, size: 20),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _receiverPhoneCtrl,
          decoration: const InputDecoration(
            labelText: 'Телефон получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_outlined, size: 20),
            isDense: true,
            hintText: '+998 90 123 45 67',
          ),
          keyboardType: TextInputType.phone,
          inputFormatters: [
            PhoneInputFormatter(),
            LengthLimitingTextInputFormatter(kPhoneMaxFormattedLength),
          ],
        ),
        const SizedBox(height: AppSpacing.formFieldGap),
        TextFormField(
          controller: _receiverInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Доп. инфо получателя',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.info_outline, size: 20),
            isDense: true,
          ),
        ),
          ],
        );
      },
    );
  }

  static const _currencies = ['USD', 'USDT', 'UZS', 'RUB', 'EUR', 'TRY', 'AED', 'CNY', 'KZT', 'KGS', 'TJS'];

  Widget _buildDetailsSection() {
    return _FormSection(
      title: 'Параметры перевода',
      icon: Icons.tune_rounded,
      children: [
        Builder(builder: (_) {
          final opts = List<String>.from(_currencies);
          if (!opts.contains(_transferCurrency) && _transferCurrency.isNotEmpty) {
            opts.insert(0, _transferCurrency);
          }
          final val = _transferCurrency.isEmpty ? 'USD' : _transferCurrency;
          return DropdownButtonFormField<String>(
            value: opts.contains(val) ? val : opts.first,
            decoration: const InputDecoration(
              labelText: 'Валюта перевода',
              border: OutlineInputBorder(),
            ),
            items: opts.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) {
                setState(() {
                  _transferCurrency = v ?? _transferCurrency;
                  if (_toCurrency == _transferCurrency || !_currencies.contains(_toCurrency)) {
                    _toCurrency = _transferCurrency;
                  }
                  if (_commissionCurrency == _transferCurrency || !_currencies.contains(_commissionCurrency)) {
                    _commissionCurrency = _transferCurrency;
                  }
                });
              },
          );
        }),
        const SizedBox(height: AppSpacing.sm),
        Builder(builder: (_) {
          final opts = List<String>.from(_currencies);
          if (!opts.contains(_toCurrency) && _toCurrency.isNotEmpty) {
            opts.insert(0, _toCurrency);
          }
          final val = _toCurrency.isEmpty ? 'USD' : _toCurrency;
          return DropdownButtonFormField<String>(
            value: opts.contains(val) ? val : opts.first,
            decoration: const InputDecoration(
              labelText: 'Валюта получателя',
              border: OutlineInputBorder(),
            ),
            items: opts.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
            onChanged: (v) {
              setState(() {
                _toCurrency = v ?? _transferCurrency;
              });
            },
          );
        }),
        const SizedBox(height: 6),
        if (_toCurrency != _transferCurrency)
          Text(
            'Разные валюты — укажите курс $_transferCurrency → $_toCurrency',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          )
        else
          Text(
            'Одинаковые валюты — курс не нужен',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        TextFormField(
          controller: _amountController,
          decoration: InputDecoration(
            labelText: 'Сумма',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.payments_outlined),
            suffixText: _transferCurrency,
            errorText: _balanceError,
            errorBorder: _balanceError != null
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.error, width: 2),
                  )
                : null,
            focusedErrorBorder: _balanceError != null
                ? OutlineInputBorder(
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.error, width: 2),
                  )
                : null,
          ),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [DecimalInputFormatter()],
          onChanged: (_) => setState(() => _balanceError = null),
          validator: (v) {
            if (v == null || v.isEmpty) return 'Введите сумму';
            final amount = double.tryParse(v);
            if (amount == null || amount <= 0) return 'Сумма должна быть > 0';
            return null;
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          CommissionMode.fromTransfer.description,
          style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Commission type toggle
        Row(
          children: [
            const Text('Тип комиссии:',
                style: TextStyle(fontSize: 13)),
            const SizedBox(width: AppSpacing.sm),
            SegmentedButton<CommissionType>(
              segments: CommissionType.values
                  .map((t) => ButtonSegment<CommissionType>(
                        value: t,
                        label: Text(t.displayName),
                      ))
                  .toList(),
              selected: {_commissionType},
              onSelectionChanged: (v) =>
                  setState(() => _commissionType = v.first),
              style: const ButtonStyle(
                  visualDensity: VisualDensity.compact),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Focus(
                onFocusChange: (f) {
                  if (!f) _restoreDefault(_commissionValueController, '0');
                },
                child: TextFormField(
                  controller: _commissionValueController,
                  decoration: InputDecoration(
                    labelText: 'Комиссия',
                    border: const OutlineInputBorder(),
                    suffixText: _commissionType == CommissionType.percentage
                        ? '%'
                        : _commissionCurrency,
                    hintText: _commissionType == CommissionType.percentage
                        ? '1.5'
                        : '100',
                    errorText: _commissionError,
                  ),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [DecimalInputFormatter()],
                  onTap: () => _smartClear(_commissionValueController),
                  onChanged: (_) => setState(() => _commissionError = null),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _currencies.contains(_commissionCurrency) ? _commissionCurrency : _transferCurrency,
                decoration: const InputDecoration(
                  labelText: 'Валюта комиссии',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: _currencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _commissionCurrency = v ?? _transferCurrency),
              ),
            ),
            if (_toCurrency != _transferCurrency) ...[
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Focus(
                  onFocusChange: (f) {
                    if (!f) _restoreDefault(_exchangeRateController, '1.0');
                  },
                  child: TextFormField(
                    controller: _exchangeRateController,
                    decoration: InputDecoration(
                      labelText: 'Курс $_transferCurrency → $_toCurrency',
                      hintText: '1.0',
                      border: const OutlineInputBorder(),
                      errorText: _exchangeRateError,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [DecimalInputFormatter()],
                    onTap: () => _smartClear(_exchangeRateController),
                    onChanged: (_) => setState(() => _exchangeRateError = null),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final amount = double.tryParse(_amountController.text) ?? 0;
    final commissionValue =
        double.tryParse(_commissionValueController.text) ?? 0;
    final commission = _commissionType == CommissionType.percentage
        ? amount * commissionValue / 100
        : commissionValue;
    final rate = _toCurrency == _transferCurrency
        ? 1.0
        : (double.tryParse(_exchangeRateController.text) ?? 1.0);
    // For fixed commission in different currency: fetch exchange rate. Percentage is already in transfer currency.
    final needsCommissionRate = _commissionType == CommissionType.fixed &&
        commission > 0 &&
        _commissionCurrency.isNotEmpty &&
        _commissionCurrency != _transferCurrency;
    final isDark = context.isDark;

    if (amount <= 0) return const SizedBox.shrink();

    Widget previewContent;
    if (needsCommissionRate) {
      previewContent = FutureBuilder(
        future: sl<ExchangeRateRepository>()
            .getLatestRate(_commissionCurrency, _transferCurrency)
            .then((r) => r.fold((_) => null, (v) => v)),
        builder: (ctx, snap) {
          final commissionRate = snap.data?.rate ?? 0.0;
          final commissionInTransferCur = commissionRate > 0
              ? commission * commissionRate
              : commission;
          final receiverGets = (amount - commissionInTransferCur) * rate;
          final totalDebit = amount;
          if (commissionRate <= 0) {
            return Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Text(
                'Курс $_commissionCurrency → $_transferCurrency не найден. '
                'Установите в настройках курсов валют.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            );
          }
          return _buildPreviewContent(
            amount: amount,
            commission: commission,
            commissionInTransferCur: commissionInTransferCur,
            totalDebit: totalDebit,
            receiverGets: receiverGets,
            isDark: isDark,
            showCommissionRateNote: true,
          );
        },
      );
    } else {
      final commissionInTransferCur = commission;
      final receiverGets = (amount - commissionInTransferCur) * rate;
      final totalDebit = amount;
      previewContent = _buildPreviewContent(
        amount: amount,
        commission: commission,
        commissionInTransferCur: commissionInTransferCur,
        totalDebit: totalDebit,
        receiverGets: receiverGets,
        isDark: isDark,
        showCommissionRateNote: false,
      );
    }

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: isDark
            ? AppColors.primary.withValues(alpha: 0.05)
            : AppColors.primary.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: AppColors.primary.withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Предварительный расчёт',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          previewContent,
        ],
      ),
    );
  }

  Widget _buildPreviewContent({
    required double amount,
    required double commission,
    required double commissionInTransferCur,
    required double totalDebit,
    required double receiverGets,
    required bool isDark,
    bool showCommissionRateNote = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.sm,
          children: [
            _PreviewItem(label: 'Сумма', value: amount.formatCurrencyNoDecimals(), currency: _transferCurrency),
            _PreviewItem(label: 'Комиссия', value: commission.formatCurrencyNoDecimals(), currency: _commissionCurrency),
            if (_commissionCurrency != _transferCurrency)
              _PreviewItem(
                label: 'Комиссия в $_transferCurrency',
                value: commissionInTransferCur.formatCurrencyNoDecimals(),
                currency: _transferCurrency,
              ),
            _PreviewItem(label: 'Списание с отправителя', value: totalDebit.formatCurrencyNoDecimals(), currency: _transferCurrency, bold: true),
            _PreviewItem(label: 'Из них комиссия (у нас)', value: commission.formatCurrencyNoDecimals(), currency: _commissionCurrency),
            _PreviewItem(label: 'Получатель получит', value: receiverGets.formatCurrencyNoDecimals(), currency: _toCurrency, bold: true),
          ],
        ),
        if (showCommissionRateNote) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Курс комиссии взят из настроек курсов валют',
            style: TextStyle(
              fontSize: 10,
              fontStyle: FontStyle.italic,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildSubmitButton(BuildContext context, TransferBlocState state) {
    final isCreating = state.status == TransferBlocStatus.creating;

    return SizedBox(
      height: 48,
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: isCreating ? null : () => _submit(context),
        icon: isCreating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.send_rounded),
        label: Text(isCreating ? 'Обработка...' : 'Создать перевод'),
      ),
    );
  }

  void _submit(BuildContext context) {
    if (!_formKey.currentState!.validate()) return;

    final amount = double.parse(_amountController.text);
    if (_fromAccountId == null) return;

    final balance = context.read<DashboardBloc>().state.accountBalances[_fromAccountId] ?? 0;
    final totalDebit = amount; // CommissionMode.fromTransfer — списание = сумма
    if (totalDebit > balance) {
      setState(() {
        _balanceError = 'Недостаточно средств. Доступно: ${balance.formatCurrencyNoDecimals()}, требуется: ${totalDebit.formatCurrencyNoDecimals()} $_transferCurrency';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Недостаточно средств. Доступно: ${balance.formatCurrencyNoDecimals()} $_transferCurrency. '
            'Пополните счёт через «Пополнение филиала» (вкладка «Без источника»).',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
      return;
    }

    final commissionValue =
        double.tryParse(_commissionValueController.text) ?? 0;
    final exchangeRate = _toCurrency == _transferCurrency
        ? 1.0
        : (double.tryParse(_exchangeRateController.text) ?? 1.0);
    if (_toCurrency != _transferCurrency && exchangeRate <= 0) {
      setState(() {
        _exchangeRateError = 'Укажите положительный курс для разных валют';
      });
      return;
    }
    final commission = _commissionType == CommissionType.percentage
        ? amount * commissionValue / 100
        : commissionValue;
    if (commission >= amount) {
      setState(() {
        _commissionError =
            'Комиссия должна быть меньше суммы перевода (режим: списание с отправителя)';
      });
      return;
    }
    final currency =
        _transferCurrency.isNotEmpty ? _transferCurrency : 'USD';
    final toCur = _toCurrency.isNotEmpty ? _toCurrency : currency;

    context.read<TransferBloc>().add(TransferCreateRequested(
          fromBranchId: _fromBranchId!,
          toBranchId: _toBranchId!,
          fromAccountId: _fromAccountId!,
          toAccountId: null,
          toCurrency: toCur != currency ? toCur : null,
          amount: amount,
          currency: currency,
          exchangeRate: exchangeRate,
          commissionType: _commissionType.name,
          commissionValue: commissionValue,
          commissionCurrency: _commissionCurrency,
          commissionMode: CommissionMode.fromTransfer.name,
          idempotencyKey: const Uuid().v4(),
          description: _descriptionCtrl.text.trim().isNotEmpty ? _descriptionCtrl.text.trim() : null,
          senderName: _senderNameCtrl.text.trim().isNotEmpty ? _senderNameCtrl.text.trim() : null,
          senderPhone: _senderPhoneCtrl.text.trim().isNotEmpty ? _senderPhoneCtrl.text.trim() : null,
          senderInfo: _senderInfoCtrl.text.trim().isNotEmpty ? _senderInfoCtrl.text.trim() : null,
          receiverName: _receiverNameCtrl.text.trim().isNotEmpty ? _receiverNameCtrl.text.trim() : null,
          receiverPhone: _receiverPhoneCtrl.text.trim().isNotEmpty ? _receiverPhoneCtrl.text.trim() : null,
          receiverInfo: _receiverInfoCtrl.text.trim().isNotEmpty ? _receiverInfoCtrl.text.trim() : null,
        ));
  }
}

class _FormSection extends StatelessWidget {
  const _FormSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              title,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        ...children,
      ],
    );
  }
}

class _PreviewItem extends StatelessWidget {
  const _PreviewItem({
    required this.label,
    required this.value,
    this.currency = '',
    this.bold = false,
  });

  final String label;
  final String value;
  final String currency;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: context.isDark
                ? AppColors.darkTextSecondary
                : AppColors.lightTextSecondary,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$value $currency',
          style: TextStyle(
            fontSize: 14,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
            fontFamily: 'JetBrains Mono',
          ),
        ),
      ],
    );
  }
}
String _formatInsufficientFundsError(String msg) {
  final match = RegExp(r'Available:\s*([\d.]+),\s*required:\s*([\d.]+)', caseSensitive: false).firstMatch(msg);
  if (match != null) {
    final avail = double.tryParse(match.group(1) ?? '0') ?? 0;
    final req = double.tryParse(match.group(2) ?? '0') ?? 0;
    return 'Недостаточно средств. Доступно: ${avail.toStringAsFixed(0)}, требуется: ${req.toStringAsFixed(0)}';
  }
  if (msg.toLowerCase().contains('insufficient')) {
    return 'Недостаточно средств на счёте';
  }
  return msg;
}

String _currFlag(String currency) {
  const flags = {
    'USD': '🇺🇸',
    'RUB': '🇷🇺',
    'UZS': '🇺🇿',
    'TRY': '🇹🇷',
    'AED': '🇦🇪',
    'CNY': '🇨🇳',
    'KZT': '🇰🇿',
    'KGS': '🇰🇬',
    'TJS': '🇹🇯',
  };
  return flags[currency] ?? '🏳️';
}

