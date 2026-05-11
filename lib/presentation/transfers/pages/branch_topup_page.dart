import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/errors/failures.dart';
import 'package:ethnocount/core/utils/branch_access.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/usecases/transfer/create_transfer.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:uuid/uuid.dart';

/// Пополнение филиала с нескольких счетов других филиалов.
/// Создаёт несколько переводов в один целевой филиал.
class BranchTopUpPage extends StatefulWidget {
  const BranchTopUpPage({super.key});

  @override
  State<BranchTopUpPage> createState() => _BranchTopUpPageState();
}

class _SourceRow {
  String? fromBranchId;
  String? fromAccountId;
  double amount = 0;
  String currency = 'USD';
  double exchangeRate = 1.0;
}

class _BranchTopUpPageState extends State<BranchTopUpPage> {
  final _fromSourceFormKey = GlobalKey<FormState>();
  final _directFormKey = GlobalKey<FormState>();

  String? _toBranchId;
  String? _toAccountId;
  String? _toAccountCurrency;
  final List<_SourceRow> _sources = [_SourceRow()];
  bool _isSubmitting = false;
  // Direct fill (no source)
  String? _directToBranchId;
  String? _directToAccountId;
  String? _directToAccountCurrency;
  final _directAmountCtrl = TextEditingController();
  final _directDescCtrl = TextEditingController();
  bool _isDirectSubmitting = false;

  String? _validateSourceAmount(_SourceRow s, String? v) {
    if (s.fromBranchId == null || s.fromAccountId == null) return null;
    if (v == null || v.trim().isEmpty) return 'Введите сумму';
    final p = double.tryParse(v.replaceAll(',', '.'));
    if (p == null || p <= 0) return 'Сумма должна быть > 0';
    return null;
  }

  String? _validateSourceRate(_SourceRow s, String? v) {
    final to = _toAccountCurrency;
    if (to == null || s.currency == to) return null;
    if (v == null || v.trim().isEmpty) return 'Укажите курс';
    final p = double.tryParse(v.replaceAll(',', '.'));
    if (p == null || p <= 0) return 'Курс должен быть > 0';
    return null;
  }

  @override
  void dispose() {
    _directAmountCtrl.dispose();
    _directDescCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Пополнение филиала'),
            Text(
              'Перевод с другого счёта или прямое зачисление',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75),
                  ),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/transfers'),
        ),
      ),
      body: SafeArea(
        child: StreamBuilder<List<Branch>>(
          stream: sl<BranchRepository>().watchBranches(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'Не удалось загрузить филиалы: ${snap.error}',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }
            final dashBranches =
                context.watch<DashboardBloc>().state.branches;
            final raw = snap.data;
            final merged = (raw != null && raw.isNotEmpty)
                ? raw
                : dashBranches;
            final branches = filterBranchesByAccess(
              merged,
              context.watch<AuthBloc>().state.user,
            );
            final screenWidth = MediaQuery.sizeOf(context).width;
            final isMobile = screenWidth < AppSpacing.breakpointMobile;
            final padding = isMobile ? AppSpacing.md : AppSpacing.lg;

            return DefaultTabController(
              length: 2,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 600),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
                        child: TabBar(
                          isScrollable: isMobile,
                          labelColor: Theme.of(context).colorScheme.primary,
                          tabAlignment: isMobile ? TabAlignment.start : TabAlignment.fill,
                          tabs: [
                            Tab(
                              icon: Icon(Icons.swap_horiz_rounded, size: isMobile ? 18 : 20),
                              text: isMobile ? 'С источника' : 'За счёт источника',
                            ),
                            Tab(
                              icon: Icon(Icons.account_balance_wallet_rounded, size: isMobile ? 18 : 20),
                              text: isMobile ? 'Без источника' : 'Без источника',
                            ),
                          ],
                        ),
                      ),
                      // ── Контент вкладок берёт всё оставшееся место.
                      // Ранее тут был внешний SingleChildScrollView + фиксированная
                      // высота TabBarView (clamp 280..600), что на мобилке давало
                      // вложенные скроллы и отрезало кнопку «Пополнить» под фолд.
                      // Теперь Expanded → каждый таб скроллится сам, кнопка всегда
                      // достижима через свой внутренний SingleChildScrollView.
                      Expanded(
                        child: TabBarView(
                          children: [
                            _buildFromSourceTab(context, branches, isMobile),
                            _buildDirectTab(context, branches, isMobile),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFromSourceTab(BuildContext context, List<Branch> branches, [bool isMobile = false]) {
    final cardPadding = isMobile ? AppSpacing.md : AppSpacing.lg;
    final outerPadding = isMobile ? AppSpacing.md : AppSpacing.lg;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        outerPadding,
        AppSpacing.md,
        outerPadding,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: IgnorePointer(
        ignoring: _isSubmitting,
        child: Form(
          key: _fromSourceFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                    child: Padding(
                      padding: EdgeInsets.all(cardPadding),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Целевой филиал',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                          DropdownButtonFormField<String>(
                            value: _toBranchId ?? '',
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Филиал',
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              const DropdownMenuItem(value: '', child: Text('— Выберите филиал —')),
                              ...branches.map((b) => DropdownMenuItem(value: b.id, child: Text(b.name))),
                            ],
                            validator: (v) =>
                                (v == null || v.isEmpty) ? 'Выберите целевой филиал' : null,
                            onChanged: (v) => setState(() {
                              _toBranchId = v != null && v.isNotEmpty ? v : null;
                              _toAccountId = null;
                              _toAccountCurrency = null;
                            }),
                          ),
                          SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                          _TargetAccountDropdown(
                            branchId: _toBranchId,
                            value: _toAccountId,
                            validator: (v) => _toBranchId != null && (v == null || v.isEmpty)
                                ? 'Выберите счёт пополнения'
                                : null,
                            onChanged: (acc) => setState(() {
                              _toAccountId = acc?.id;
                              _toAccountCurrency = acc?.currency;
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.lg),
                  Card(
                    child: Padding(
                      padding: EdgeInsets.all(cardPadding),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Источники',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              TextButton.icon(
                                onPressed: () => setState(() => _sources.add(_SourceRow())),
                                icon: const Icon(Icons.add, size: 18),
                                label: const Text('Добавить'),
                              ),
                            ],
                          ),
                          SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                          ..._sources.asMap().entries.map((e) {
                            final i = e.key;
                            final s = e.value;
                            final sourceBranches = branches.where((b) => b.id != _toBranchId).toList();
                            final sourceBranchValue = s.fromBranchId != null &&
                                    sourceBranches.any((b) => b.id == s.fromBranchId)
                                ? s.fromBranchId!
                                : '';
                            return Padding(
                              key: ValueKey('source-row-$i'),
                              padding: EdgeInsets.only(bottom: isMobile ? 10 : 12),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final narrow = constraints.maxWidth < 420 || isMobile;
                                  if (narrow) {
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: DropdownButtonFormField<String>(
                                                value: sourceBranchValue,
                                                isExpanded: true,
                                                decoration: const InputDecoration(
                                                  labelText: 'Филиал-источник',
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                  hintText: 'Выберите филиал',
                                                ),
                                                items: [
                                                  const DropdownMenuItem(value: '', child: Text('— Выберите филиал —')),
                                                  ...sourceBranches.map((b) => DropdownMenuItem(value: b.id, child: Text(b.name))),
                                                ],
                                                onChanged: sourceBranches.isEmpty
                                                    ? null
                                                    : (v) => setState(() {
                                                          s.fromBranchId = v != null && v.isNotEmpty ? v : null;
                                                          s.fromAccountId = null;
                                                        }),
                                              ),
                                            ),
                                            if (_sources.length > 1)
                                              IconButton(
                                                icon: const Icon(Icons.remove_circle_outline),
                                                onPressed: () => setState(() => _sources.removeAt(i)),
                                              ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        _SourceAccountDropdown(
                                          branchId: s.fromBranchId,
                                          value: s.fromAccountId,
                                          currency: s.currency,
                                          validator: (v) => s.fromBranchId != null &&
                                                  (v == null || v.isEmpty)
                                              ? 'Выберите счёт источника'
                                              : null,
                                          onChanged: (acc) => setState(() {
                                            s.fromAccountId = acc?.id;
                                            s.currency = acc?.currency ?? 'USD';
                                          }),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: TextFormField(
                                                key: ValueKey('amount-$i'),
                                                initialValue: s.amount > 0 ? s.amount.toString() : '',
                                                decoration: const InputDecoration(
                                                  labelText: 'Сумма',
                                                  isDense: true,
                                                  border: OutlineInputBorder(),
                                                ),
                                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                validator: (v) => _validateSourceAmount(s, v),
                                                onChanged: (v) => setState(() => s.amount = double.tryParse(v.replaceAll(',', '.')) ?? 0),
                                              ),
                                            ),
                                            if (_toAccountCurrency != null && s.currency != _toAccountCurrency) ...[
                                              const SizedBox(width: 8),
                                              SizedBox(
                                                width: 80,
                                                child: TextFormField(
                                                  key: ValueKey('rate-$i'),
                                                  initialValue: s.exchangeRate != 1.0 ? s.exchangeRate.toString() : '',
                                                  decoration: const InputDecoration(
                                                    labelText: 'Курс',
                                                    isDense: true,
                                                    border: OutlineInputBorder(),
                                                  ),
                                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                                  validator: (v) => _validateSourceRate(s, v),
                                                  onChanged: (v) => setState(() => s.exchangeRate = double.tryParse(v.replaceAll(',', '.')) ?? 1.0),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    );
                                  }
                                  return Row(
                                    children: [
                                      Expanded(
                                        flex: 2,
                                        child: DropdownButtonFormField<String>(
                                          value: sourceBranchValue,
                                          isExpanded: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Филиал-источник',
                                            isDense: true,
                                            border: OutlineInputBorder(),
                                            hintText: 'Выберите филиал',
                                          ),
                                          items: [
                                            const DropdownMenuItem(value: '', child: Text('— Выберите филиал —')),
                                            ...sourceBranches.map((b) => DropdownMenuItem(value: b.id, child: Text(b.name))),
                                          ],
                                          onChanged: sourceBranches.isEmpty
                                              ? null
                                              : (v) => setState(() {
                                                    s.fromBranchId = v != null && v.isNotEmpty ? v : null;
                                                    s.fromAccountId = null;
                                                  }),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        flex: 2,
                                        child: _SourceAccountDropdown(
                                          branchId: s.fromBranchId,
                                          value: s.fromAccountId,
                                          currency: s.currency,
                                          validator: (v) => s.fromBranchId != null &&
                                                  (v == null || v.isEmpty)
                                              ? 'Выберите счёт источника'
                                              : null,
                                          onChanged: (acc) => setState(() {
                                            s.fromAccountId = acc?.id;
                                            s.currency = acc?.currency ?? 'USD';
                                          }),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: TextFormField(
                                          key: ValueKey('amount-$i'),
                                          initialValue: s.amount > 0 ? s.amount.toString() : '',
                                          decoration: const InputDecoration(
                                            labelText: 'Сумма',
                                            isDense: true,
                                            border: OutlineInputBorder(),
                                          ),
                                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                          validator: (v) => _validateSourceAmount(s, v),
                                          onChanged: (v) => setState(() => s.amount = double.tryParse(v.replaceAll(',', '.')) ?? 0),
                                        ),
                                      ),
                                      if (_toAccountCurrency != null && s.currency != _toAccountCurrency) ...[
                                        const SizedBox(width: 8),
                                        SizedBox(
                                          width: 70,
                                          child: TextFormField(
                                            key: ValueKey('rate-$i'),
                                            initialValue: s.exchangeRate != 1.0 ? s.exchangeRate.toString() : '',
                                            decoration: const InputDecoration(
                                              labelText: 'Курс',
                                              isDense: true,
                                              border: OutlineInputBorder(),
                                            ),
                                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                            validator: (v) => _validateSourceRate(s, v),
                                            onChanged: (v) => setState(() => s.exchangeRate = double.tryParse(v.replaceAll(',', '.')) ?? 1.0),
                                          ),
                                        ),
                                      ],
                                      if (_sources.length > 1)
                                        IconButton(
                                          icon: const Icon(Icons.remove_circle_outline),
                                          onPressed: () => setState(() => _sources.removeAt(i)),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                  if (branches.length <= 1)
                    Padding(
                      padding: EdgeInsets.only(top: isMobile ? 6 : 8),
                      child: Text(
                        'Нет филиалов-источников. Переключитесь на вкладку «Без источника».',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.lg),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 48),
                    ),
                    onPressed: _isSubmitting ? null : () => _submit(context, branches),
                    child: _isSubmitting
                        ? const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            ),
                          )
                        : const Text('Создать переводы'),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDirectTab(BuildContext context, List<Branch> branches, [bool isMobile = false]) {
    final cardPadding = isMobile ? AppSpacing.md : AppSpacing.lg;
    final outerPadding = isMobile ? AppSpacing.md : AppSpacing.lg;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        outerPadding,
        AppSpacing.md,
        outerPadding,
        AppSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: IgnorePointer(
        ignoring: _isDirectSubmitting,
        child: Form(
          key: _directFormKey,
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(cardPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Добавить деньги на счёт напрямую, без списания с другого филиала.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                  ),
                  SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                  DropdownButtonFormField<String>(
                    initialValue: _directToBranchId ?? '',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Филиал',
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('— Выберите филиал —')),
                      ...branches.map((b) => DropdownMenuItem(value: b.id, child: Text(b.name))),
                    ],
                    validator: (v) => (v == null || v.isEmpty) ? 'Выберите филиал' : null,
                    onChanged: (v) => setState(() {
                      _directToBranchId = v != null && v.isNotEmpty ? v : null;
                      _directToAccountId = null;
                      _directToAccountCurrency = null;
                    }),
                  ),
                  SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                  _TargetAccountDropdown(
                    branchId: _directToBranchId,
                    value: _directToAccountId,
                    validator: (v) => _directToBranchId != null && (v == null || v.isEmpty)
                        ? 'Выберите счёт'
                        : null,
                    onChanged: (acc) => setState(() {
                      _directToAccountId = acc?.id;
                      _directToAccountCurrency = acc?.currency;
                    }),
                  ),
                  SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                  TextFormField(
                    controller: _directAmountCtrl,
                    decoration: InputDecoration(
                      labelText: _directToAccountCurrency != null
                          ? 'Сумма ($_directToAccountCurrency)'
                          : 'Сумма',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.add_rounded),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Введите сумму';
                      final a = double.tryParse(v.trim().replaceAll(',', '.'));
                      if (a == null || a <= 0) return 'Сумма должна быть > 0';
                      return null;
                    },
                  ),
                  SizedBox(height: isMobile ? AppSpacing.sm : AppSpacing.md),
                  TextFormField(
                    controller: _directDescCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Описание (необязательно)',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.notes_rounded),
                    ),
                    maxLines: 1,
                  ),
                  SizedBox(height: isMobile ? AppSpacing.md : AppSpacing.formFieldGap),
                  FilledButton.icon(
                    onPressed: _isDirectSubmitting ? null : _submitDirect,
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                      minimumSize: const Size(0, 48),
                    ),
                    icon: _isDirectSubmitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.add_rounded),
                    label: const Text('Пополнить'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submit(BuildContext context, List<Branch> branches) async {
    if (_fromSourceFormKey.currentState?.validate() != true) return;

    final validSources = _sources.where((s) =>
        s.fromBranchId != null &&
        s.fromAccountId != null &&
        s.amount > 0).toList();
    if (validSources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Заполните строку источника: филиал, счёт и сумму'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    final toCurrency = _toAccountCurrency ?? 'USD';
    final createTransfer = sl<CreateTransferUseCase>();
    var successCount = 0;
    for (final s in validSources) {
      final needsRate = s.currency != toCurrency;
      final rate = needsRate ? (s.exchangeRate > 0 ? s.exchangeRate : 1.0) : 1.0;
      if (needsRate && rate <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Укажите курс ${s.currency} → $toCurrency для источника')),
        );
        setState(() => _isSubmitting = false);
        return;
      }
      final result = await createTransfer(
        fromBranchId: s.fromBranchId!,
        toBranchId: _toBranchId!,
        fromAccountId: s.fromAccountId!,
        toAccountId: _toAccountId,
        toCurrency: needsRate ? toCurrency : null,
        amount: s.amount,
        currency: s.currency,
        exchangeRate: rate,
        commissionType: 'fixed',
        commissionValue: 0,
        commissionCurrency: s.currency,
        idempotencyKey: const Uuid().v4(),
      );
      result.fold(
        (f) {
          if (context.mounted) {
            final isInsufficientFunds = f is InsufficientFundsFailure ||
                f.message.toLowerCase().contains('insufficient funds');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Ошибка перевода: ${f.message}'),
                    if (isInsufficientFunds)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Перейдите на вкладку «Без источника» для пополнения счёта напрямую.',
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onError.withValues(alpha: 0.9),
                          ),
                        ),
                      ),
                  ],
                ),
                backgroundColor: Theme.of(context).colorScheme.error,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        },
        (_) => successCount++,
      );
      if (!context.mounted) return;
    }

    if (!mounted) return;
    setState(() => _isSubmitting = false);
    if (!context.mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Создано $successCount из ${validSources.length} переводов')),
    );
    context.go('/transfers');
  }

  Future<void> _submitDirect() async {
    if (_directFormKey.currentState?.validate() != true) return;
    final amount = double.tryParse(_directAmountCtrl.text.trim().replaceAll(',', '.'));
    if (amount == null || amount <= 0) return;
    if (_directToBranchId == null || _directToAccountId == null || _directToAccountCurrency == null) return;

    setState(() => _isDirectSubmitting = true);
    try {
      final creatorUid = context.read<AuthBloc>().state.user?.id ?? '';
      await sl<LedgerRemoteDataSource>().adjustAccountBalance(
        branchId: _directToBranchId!,
        accountId: _directToAccountId!,
        amount: amount,
        currency: _directToAccountCurrency!,
        type: 'credit',
        referenceType: 'adjustment',
        description: _directDescCtrl.text.trim().isEmpty
            ? 'Пополнение без источника'
            : _directDescCtrl.text.trim(),
        createdBy: creatorUid,
      );
      if (!mounted) return;
      _directAmountCtrl.clear();
      _directDescCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Счёт пополнен на ${amount.toStringAsFixed(2)} $_directToAccountCurrency'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isDirectSubmitting = false);
    }
  }
}

class _SourceAccountDropdown extends StatelessWidget {
  final String? branchId;
  final String? value;
  final String currency;
  final void Function(BranchAccount?)? onChanged;
  final FormFieldValidator<String>? validator;

  const _SourceAccountDropdown({
    this.branchId,
    this.value,
    this.currency = 'USD',
    this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    if (branchId == null) {
      return DropdownButtonFormField<String>(
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Счёт', border: OutlineInputBorder()),
        items: const [],
        onChanged: (_) {},
      );
    }
    return StreamBuilder<List<BranchAccount>>(
      stream: sl<BranchRepository>().watchBranchAccounts(branchId!),
      builder: (context, snap) {
        if (snap.hasError) {
          return InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Счёт',
              border: OutlineInputBorder(),
              errorText: 'Ошибка загрузки счетов',
            ),
            child: Text(
              '${snap.error}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          );
        }
        final streamAccts = snap.data ?? [];
        final fallback = context.watch<DashboardBloc>().state.branchAccounts[branchId!] ?? [];
        final accounts =
            streamAccts.isNotEmpty ? streamAccts : fallback;
        final hasValue = value != null && accounts.any((a) => a.id == value);
        return DropdownButtonFormField<String>(
          initialValue: hasValue ? value! : '',
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Счёт',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('— Выберите счёт —')),
            ...accounts.map((a) => DropdownMenuItem(
                  value: a.id,
                  child: Text('${a.name} (${a.currency})'),
                )),
          ],
          validator: validator,
          onChanged: (id) {
            if (id == null || id.isEmpty) {
              onChanged?.call(null);
              return;
            }
            final acc = accounts.where((a) => a.id == id).firstOrNull;
            onChanged?.call(acc);
          },
        );
      },
    );
  }
}

class _TargetAccountDropdown extends StatelessWidget {
  final String? branchId;
  final String? value;
  final void Function(BranchAccount?)? onChanged;
  final FormFieldValidator<String>? validator;

  const _TargetAccountDropdown({
    this.branchId,
    this.value,
    this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    if (branchId == null) {
      return DropdownButtonFormField<String>(
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Счёт пополнения', border: OutlineInputBorder()),
        items: const [],
        onChanged: (_) {},
      );
    }
    return StreamBuilder<List<BranchAccount>>(
      stream: sl<BranchRepository>().watchBranchAccounts(branchId!),
      builder: (context, snap) {
        if (snap.hasError) {
          return InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Счёт пополнения',
              border: OutlineInputBorder(),
              errorText: 'Ошибка загрузки счетов',
            ),
            child: Text(
              '${snap.error}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          );
        }
        final streamAccts = snap.data ?? [];
        final fallback = context.watch<DashboardBloc>().state.branchAccounts[branchId!] ?? [];
        final accounts =
            streamAccts.isNotEmpty ? streamAccts : fallback;
        final hasValue = value != null && accounts.any((a) => a.id == value);
        return DropdownButtonFormField<String>(
          initialValue: hasValue ? value! : '',
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Счёт пополнения',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem(value: '', child: Text('— Выберите счёт —')),
            ...accounts.map((a) => DropdownMenuItem(
                  value: a.id,
                  child: Text('${a.name} (${a.currency})'),
                )),
          ],
          validator: validator,
          onChanged: (id) {
            if (id == null || id.isEmpty) {
              onChanged?.call(null);
              return;
            }
            final acc = accounts.where((a) => a.id == id).firstOrNull;
            onChanged?.call(acc);
          },
        );
      },
    );
  }
}
