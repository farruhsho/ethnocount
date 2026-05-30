import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/presentation/approvals/approval_guards.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';

/// Универсальный диалог редактирования перевода.
///
/// • Статус `created` → полная форма как при создании: валюта, комиссия,
///   курс, счёт-источник, контрагенты, реквизиты, описание. RPC
///   `replace_pending_transfer` атомарно перенакатывает финансы.
/// • Любой другой статус (`toDelivery` / `withCourier` / `delivered`) →
///   редактируются только метаданные: имена/телефоны/реквизиты/описание.
class EditTransferDialog extends StatefulWidget {
  const EditTransferDialog({
    super.key,
    required this.transfer,
    required this.onSaved,
    @Deprecated('Решение принимается по статусу перевода — параметр игнорируется.')
    this.allowAmountEdit = true,
  });

  final Transfer transfer;
  final VoidCallback onSaved;
  final bool allowAmountEdit;

  @override
  State<EditTransferDialog> createState() => _EditTransferDialogState();
}

class _EditTransferDialogState extends State<EditTransferDialog> {
  // Финансовые поля
  late final TextEditingController _amountCtrl;
  late final TextEditingController _rateCtrl;
  late final TextEditingController _commissionValueCtrl;
  late String _currency;
  late String _toCurrency;
  late String _commissionCurrency;
  late CommissionType _commissionType;
  late CommissionMode _commissionMode;
  String? _fromAccountId;
  String? _toAccountId;
  String? _commissionAccountId;

  // Контактные/метаданные
  late final TextEditingController _descriptionCtrl;
  late final TextEditingController _senderNameCtrl;
  late final TextEditingController _senderPhoneCtrl;
  late final TextEditingController _senderInfoCtrl;
  late final TextEditingController _receiverNameCtrl;
  late final TextEditingController _receiverPhoneCtrl;
  late final TextEditingController _receiverInfoCtrl;
  late final TextEditingController _noteCtrl;

  // Dealer mode (опц.) — пересчёт spread profit при edit.
  late bool _dealerMode;
  late String _baseCurrency;
  late final TextEditingController _buyRateCtrl;
  late final TextEditingController _sellRateCtrl;

  bool _saving = false;

  bool get _isFullEdit => widget.transfer.isCreated;

  @override
  void initState() {
    super.initState();
    final t = widget.transfer;
    _amountCtrl = TextEditingController(text: _trim(t.amount));
    _rateCtrl = TextEditingController(text: _trim(t.exchangeRate));
    _commissionValueCtrl = TextEditingController(text: _trim(t.commissionValue));
    _currency = t.currency;
    _toCurrency = t.toCurrency ?? t.currency;
    _commissionCurrency = t.commissionCurrency.isEmpty ? t.currency : t.commissionCurrency;
    _commissionType = t.commissionType;
    _commissionMode = t.commissionMode;
    _fromAccountId = t.fromAccountId.isEmpty ? null : t.fromAccountId;
    _toAccountId = t.toAccountId.isEmpty ? null : t.toAccountId;
    _commissionAccountId = t.commissionAccountId;

    _descriptionCtrl = TextEditingController(text: t.description ?? '');
    _senderNameCtrl = TextEditingController(text: t.senderName ?? '');
    _senderPhoneCtrl = TextEditingController(text: t.senderPhone ?? '');
    _senderInfoCtrl = TextEditingController(text: t.senderInfo ?? '');
    _receiverNameCtrl = TextEditingController(text: t.receiverName ?? '');
    _receiverPhoneCtrl = TextEditingController(text: t.receiverPhone ?? '');
    _receiverInfoCtrl = TextEditingController(text: t.receiverInfo ?? '');
    _noteCtrl = TextEditingController();
    // Dealer state — заполняем из текущего перевода если есть курсы.
    _dealerMode = t.hasDealerRates;
    _baseCurrency = t.baseCurrency ?? 'USD';
    _buyRateCtrl = TextEditingController(
        text: t.buyRate != null ? _trim(t.buyRate!) : '');
    _sellRateCtrl = TextEditingController(
        text: t.sellRate != null ? _trim(t.sellRate!) : '');
  }

  String _trim(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _rateCtrl.dispose();
    _commissionValueCtrl.dispose();
    _descriptionCtrl.dispose();
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _senderInfoCtrl.dispose();
    _receiverNameCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverInfoCtrl.dispose();
    _noteCtrl.dispose();
    _buyRateCtrl.dispose();
    _sellRateCtrl.dispose();
    super.dispose();
  }

  double get _dealerBuy =>
      double.tryParse(_buyRateCtrl.text.replaceAll(',', '.')) ?? 0;
  double get _dealerSell =>
      double.tryParse(_sellRateCtrl.text.replaceAll(',', '.')) ?? 0;
  double get _spreadPreview {
    if (!_dealerMode || _dealerBuy <= 0 || _dealerSell <= 0) return 0;
    final amt = double.tryParse(_amountCtrl.text.replaceAll(',', '.')) ?? 0;
    if (amt <= 0 || _baseCurrency == _currency) return 0;
    return amt - (amt / _dealerBuy) * _dealerSell;
  }

  Future<void> _submit() async {
    final t = widget.transfer;
    if (_saving) return;

    if (_isFullEdit) {
      final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
      if (amount == null || amount <= 0) {
        _snack('Введите корректную сумму');
        return;
      }
      final rate = double.tryParse(_rateCtrl.text.replaceAll(',', '.'));
      if (rate == null || rate <= 0) {
        _snack('Введите корректный курс');
        return;
      }
      final commissionValue =
          double.tryParse(_commissionValueCtrl.text.replaceAll(',', '.')) ?? 0;
      if (commissionValue < 0) {
        _snack('Комиссия не может быть отрицательной');
        return;
      }

      setState(() => _saving = true);
      context.read<TransferBloc>().add(TransferReplacePendingRequested(
            transferId: t.id,
            fromAccountId: _fromAccountId,
            amount: amount,
            currency: _currency,
            toCurrency: _toCurrency,
            exchangeRate: rate,
            commissionType: _commissionType.name,
            commissionValue: commissionValue,
            commissionCurrency: _commissionCurrency,
            commissionMode: _commissionMode.name,
            commissionAccountId: _commissionMode == CommissionMode.fromAccount
                ? _commissionAccountId
                : null,
            toAccountId: _toAccountId ?? '',
            description: _descriptionCtrl.text.trim(),
            senderName: _senderNameCtrl.text.trim(),
            senderPhone: _senderPhoneCtrl.text.trim(),
            senderInfo: _senderInfoCtrl.text.trim(),
            receiverName: _receiverNameCtrl.text.trim(),
            receiverPhone: _receiverPhoneCtrl.text.trim(),
            receiverInfo: _receiverInfoCtrl.text.trim(),
            amendmentNote: _noteCtrl.text.trim().isEmpty
                ? null
                : _noteCtrl.text.trim(),
            buyRate:
                _dealerMode && _dealerBuy > 0 && _dealerSell > 0 ? _dealerBuy : null,
            sellRate:
                _dealerMode && _dealerBuy > 0 && _dealerSell > 0 ? _dealerSell : null,
            baseCurrency: _dealerMode && _dealerBuy > 0 && _dealerSell > 0
                ? _baseCurrency
                : null,
          ));
      widget.onSaved();
      return;
    }

    // Не-created: только metadata. Если accountant пытается править сумму
    // принятого перевода — это требует approval'а директора.
    final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
    if (amount != null && (amount - t.amount).abs() > 1e-9) {
      final go = await context.guardAmendTransferAmount(t, newAmount: amount);
      if (!go) {
        widget.onSaved();
        return;
      }
    }

    if (!mounted) return;
    setState(() => _saving = true);
    context.read<TransferBloc>().add(TransferUpdateRequested(
          transferId: t.id,
          amount: amount != null && (amount - t.amount).abs() > 1e-9
              ? amount
              : null,
          description: _descriptionCtrl.text.trim().isEmpty
              ? null
              : _descriptionCtrl.text.trim(),
          senderName: _senderNameCtrl.text.trim(),
          senderPhone: _senderPhoneCtrl.text.trim(),
          senderInfo: _senderInfoCtrl.text.trim(),
          receiverName: _receiverNameCtrl.text.trim(),
          receiverPhone: _receiverPhoneCtrl.text.trim(),
          receiverInfo: _receiverInfoCtrl.text.trim(),
        ));
    widget.onSaved();
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    final theme = Theme.of(context);

    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (ctx, state) {
        if (state.status == TransferBlocStatus.success) {
          if (Navigator.of(ctx).canPop()) Navigator.of(ctx).pop();
        } else if (state.status == TransferBlocStatus.error) {
          setState(() => _saving = false);
        }
      },
      child: Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusLg),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(transfer: t, fullEdit: _isFullEdit),
              const Divider(height: 1),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    AppSpacing.md,
                    AppSpacing.lg,
                    AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_isFullEdit) _financeSection(theme),
                      if (_isFullEdit) const SizedBox(height: AppSpacing.lg),
                      if (_isFullEdit) _dealerSection(theme),
                      if (_isFullEdit) const SizedBox(height: AppSpacing.lg),
                      _contactsSection(theme),
                      const SizedBox(height: AppSpacing.lg),
                      _metaSection(theme),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(AppIcons.check, size: 18),
                      label: const Text('Сохранить'),
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

  // ─── Финансы (full-edit для created) ───────────────────────────────────

  Widget _dealerSection(ThemeData theme) {
    final scheme = theme.colorScheme;
    final spread = _spreadPreview;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: _dealerMode
            ? scheme.primary.withValues(alpha: 0.06)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(
          color: _dealerMode
              ? scheme.primary.withValues(alpha: 0.25)
              : scheme.outline.withValues(alpha: 0.15),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Switch(
                value: _dealerMode,
                onChanged: (v) => setState(() => _dealerMode = v),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              const SizedBox(width: AppSpacing.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Дилерская модель (buy/sell + spread profit)',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: _dealerMode ? scheme.primary : null,
                      ),
                    ),
                    Text(
                      _dealerMode
                          ? 'Spread пересчитается при сохранении'
                          : 'Включи если меняешь курсы или хочешь зафиксировать spread',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_dealerMode) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: const ['USD', 'EUR', 'RUB', 'UZS', 'KZT']
                            .contains(_baseCurrency)
                        ? _baseCurrency
                        : 'USD',
                    isExpanded: true,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Base',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: const ['USD', 'EUR', 'RUB', 'UZS', 'KZT']
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(c,
                                  style: const TextStyle(fontSize: 13)),
                            ))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _baseCurrency = v);
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _buyRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Buy',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _sellRateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Sell',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            if (spread.abs() > 0.005) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm, vertical: 6),
                decoration: BoxDecoration(
                  color: spread > 0
                      ? Colors.green.withValues(alpha: 0.1)
                      : Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(
                      spread > 0 ? Icons.trending_up : Icons.trending_down,
                      size: 16,
                      color: spread > 0
                          ? Colors.green.shade700
                          : Colors.red.shade700,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        spread > 0
                            ? 'Spread: +${spread.toStringAsFixed(0)} $_currency'
                            : 'Убыток: ${spread.toStringAsFixed(0)} $_currency',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: spread > 0
                              ? Colors.green.shade800
                              : Colors.red.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _financeSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Финансы'),
        const SizedBox(height: AppSpacing.sm),
        StreamBuilder<List<BranchAccount>>(
          stream: sl<BranchRepository>().watchBranchAccounts(widget.transfer.fromBranchId),
          builder: (ctx, snap) {
            final fromAccs = snap.data ?? const <BranchAccount>[];
            return DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: fromAccs.any((a) => a.id == _fromAccountId) ? _fromAccountId : null,
              decoration: const InputDecoration(
                labelText: 'Счёт отправителя',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: fromAccs
                  .map((a) => DropdownMenuItem(
                        value: a.id,
                        child: Text('${a.name} (${a.currency})'),
                      ))
                  .toList(),
              onChanged: (v) => setState(() {
                _fromAccountId = v;
                final m = fromAccs.where((a) => a.id == v).firstOrNull;
                if (m != null) {
                  final old = _currency;
                  _currency = m.currency;
                  if (_toCurrency == old) _toCurrency = m.currency;
                  if (_commissionCurrency.isEmpty ||
                      _commissionCurrency == old) {
                    _commissionCurrency = m.currency;
                  }
                }
              }),
            );
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: TextField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Сумма перевода',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Валюта',
                  helperText: 'из счёта',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(AppIcons.lock_outline, size: 18),
                  isDense: true,
                ),
                child: Text(
                  _currency,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: _CurrencyDropdown(
                value: _toCurrency,
                onChanged: (v) => setState(() => _toCurrency = v),
                label: 'Валюта получателя',
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _rateCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: InputDecoration(
                  labelText: _currency == _toCurrency
                      ? 'Курс (1.0 — без конвертации)'
                      : 'Курс $_currency → $_toCurrency',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        _sectionSubtitle('Комиссия'),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _commissionValueCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                ],
                decoration: InputDecoration(
                  labelText: _commissionType == CommissionType.percentage
                      ? 'Процент'
                      : 'Сумма',
                  suffixText: _commissionType == CommissionType.percentage
                      ? '%'
                      : _commissionCurrency,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: DropdownButtonFormField<CommissionType>(
                // ignore: deprecated_member_use
                value: _commissionType,
                decoration: const InputDecoration(
                  labelText: 'Тип',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: CommissionType.values
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Text(c.displayName),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _commissionType = v ?? _commissionType),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            if (_commissionType == CommissionType.fixed) ...[
              Expanded(
                child: _CurrencyDropdown(
                  value: _commissionCurrency,
                  onChanged: (v) => setState(() => _commissionCurrency = v),
                  label: 'Валюта комиссии',
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(
              flex: 2,
              child: DropdownButtonFormField<CommissionMode>(
                // ignore: deprecated_member_use
                value: _commissionMode,
                decoration: const InputDecoration(
                  labelText: 'Режим',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: CommissionMode.values
                    .map((m) => DropdownMenuItem(
                          value: m,
                          child: Text(m.displayName,
                              style: const TextStyle(fontSize: 12)),
                        ))
                    .toList(),
                onChanged: (v) =>
                    setState(() => _commissionMode = v ?? _commissionMode),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        StreamBuilder<List<BranchAccount>>(
          stream: sl<BranchRepository>().watchBranchAccounts(widget.transfer.toBranchId),
          builder: (ctx, snap) {
            final toAccs = snap.data ?? const <BranchAccount>[];
            final filtered =
                toAccs.where((a) => a.currency == _toCurrency).toList();
            return DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: filtered.any((a) => a.id == _toAccountId) ? _toAccountId : null,
              decoration: const InputDecoration(
                labelText: 'Счёт получателя (опционально)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('— укажет получатель при подтверждении —'),
                ),
                ...filtered.map((a) => DropdownMenuItem(
                      value: a.id,
                      child: Text('${a.name} (${a.currency})'),
                    )),
              ],
              onChanged: (v) => setState(() => _toAccountId = v),
            );
          },
        ),
      ],
    );
  }

  // ─── Контрагенты (все статусы) ─────────────────────────────────────────

  Widget _contactsSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Контрагенты'),
        const SizedBox(height: AppSpacing.sm),
        _twoColumn(
          TextField(
            controller: _senderNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Имя отправителя',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          TextField(
            controller: _senderPhoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Телефон отправителя',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _senderInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Реквизиты / карта отправителя',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _twoColumn(
          TextField(
            controller: _receiverNameCtrl,
            decoration: const InputDecoration(
              labelText: 'Имя получателя',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          TextField(
            controller: _receiverPhoneCtrl,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Телефон получателя',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _receiverInfoCtrl,
          decoration: const InputDecoration(
            labelText: 'Реквизиты / карта получателя',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  // ─── Метаданные ────────────────────────────────────────────────────────

  Widget _metaSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionTitle('Описание и комментарий'),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _descriptionCtrl,
          maxLines: 2,
          decoration: const InputDecoration(
            labelText: 'Назначение платежа',
            hintText: 'Оплата по договору...',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        if (_isFullEdit) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _noteCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Комментарий к правке (попадёт в историю)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ],
      ],
    );
  }

  Widget _sectionTitle(String t) => Text(
        t,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      );

  Widget _sectionSubtitle(String t) => Text(
        t,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
        ),
      );

  Widget _twoColumn(Widget a, Widget b) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: b),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.transfer, required this.fullEdit});
  final Transfer transfer;
  final bool fullEdit;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(AppIcons.edit, color: AppColors.primary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fullEdit
                      ? 'Редактировать перевод'
                      : 'Поправить реквизиты',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  fullEdit
                      ? '${transfer.transactionCode ?? transfer.id.substring(0, 8)} • меняйте всё: валюту, комиссию, счёт, контрагентов'
                      : '${transfer.transactionCode ?? transfer.id.substring(0, 8)} • меняются только имена/телефоны/реквизиты',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Маленькая обёртка над DropdownButtonFormField для выбора валюты.
/// Текущий список — короткий «частый» набор; пользователь может вписать
/// что угодно через текстовый ввод при создании, поэтому при редактировании
/// просто отображаем существующую + типовые.
class _CurrencyDropdown extends StatelessWidget {
  const _CurrencyDropdown({
    required this.value,
    required this.onChanged,
    required this.label,
  });

  final String value;
  final ValueChanged<String> onChanged;
  final String label;

  static const _options = ['USD', 'USDT', 'EUR', 'RUB', 'UZS', 'KZT', 'GBP', 'CNY'];

  @override
  Widget build(BuildContext context) {
    final items = {..._options, if (value.isNotEmpty) value}.toList()..sort();
    return DropdownButtonFormField<String>(
      // ignore: deprecated_member_use
      value: items.contains(value) ? value : null,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      items: items
          .map((c) => DropdownMenuItem(value: c, child: Text(c)))
          .toList(),
      onChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}
