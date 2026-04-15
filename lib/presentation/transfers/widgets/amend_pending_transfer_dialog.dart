import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';

/// Correct pending transfer: currency, receiver account, rate — with history + peer notify on save.
Future<void> showAmendPendingTransferDialog(
  BuildContext context,
  Transfer transfer,
) async {
  if (!transfer.isPending) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => _AmendPendingTransferBody(transfer: transfer),
  );
}

class _AmendPendingTransferBody extends StatefulWidget {
  const _AmendPendingTransferBody({required this.transfer});

  final Transfer transfer;

  @override
  State<_AmendPendingTransferBody> createState() =>
      _AmendPendingTransferBodyState();
}

class _AmendPendingTransferBodyState extends State<_AmendPendingTransferBody> {
  late String _currency;
  String? _accountId;
  late final TextEditingController _rateCtrl;
  late final TextEditingController _noteCtrl;
  String? _inlineError;

  Transfer get t => widget.transfer;

  /// Валюта в документе перевода (всегда доступна в списке, даже если счёта в ней нет).
  String get _declaredCurrency => t.toCurrency ?? t.currency;

  @override
  void initState() {
    super.initState();
    _currency = _declaredCurrency;
    _accountId = t.toAccountId.isEmpty ? null : t.toAccountId;
    _rateCtrl = TextEditingController(text: t.exchangeRate.toString());
    _noteCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _rateCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  List<BranchAccount> _accountsForCurrency(List<BranchAccount> all) =>
      all.where((a) => a.currency == _currency).toList();

  void _submit(BuildContext context, List<BranchAccount> accounts) {
    setState(() => _inlineError = null);
    final note = _noteCtrl.text.trim();
    final rateParsed = double.tryParse(_rateCtrl.text.replaceAll(',', '.'));
    final oldCur = t.toCurrency ?? t.currency;
    String? newToCurrency;
    if (_currency != oldCur) newToCurrency = _currency;

    String? newToAccount;
    final effectiveAcc = _accountId ?? '';
    if (effectiveAcc != t.toAccountId) {
      newToAccount = effectiveAcc;
    }

    double? newRate;
    if (rateParsed != null && (rateParsed - t.exchangeRate).abs() > 1e-9) {
      newRate = rateParsed;
    }

    if (newToCurrency == null &&
        newToAccount == null &&
        newRate == null &&
        note.isEmpty) {
      Navigator.pop(context);
      return;
    }

    if (newToAccount != null &&
        newToAccount.isNotEmpty &&
        !accounts.any((a) => a.id == newToAccount)) {
      setState(() => _inlineError =
          'Выберите счёт из списка филиала получателя.');
      return;
    }

    context.read<TransferBloc>().add(TransferUpdateRequested(
          transferId: t.id,
          toCurrency: newToCurrency,
          toAccountId: newToAccount,
          exchangeRate: newRate,
          amendmentNote: note.isEmpty ? null : note,
        ));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Исправить перевод (до подтверждения)'),
      content: SizedBox(
        width: 440,
        child: StreamBuilder<List<BranchAccount>>(
          stream: sl<BranchRepository>().watchBranchAccounts(t.toBranchId),
          builder: (context, snapshot) {
            final all = snapshot.data ?? [];
            final currencies = all.map((a) => a.currency).toSet().toList()
              ..add(_declaredCurrency)
              ..sort();

            final forCurrency = _accountsForCurrency(all);
            final currencyValue =
                currencies.contains(_currency) ? _currency : _declaredCurrency;
            final accountValue = _accountId != null &&
                    forCurrency.any((a) => a.id == _accountId)
                ? _accountId
                : null;

            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Код: ${t.transactionCode ?? t.id}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (currencies.isNotEmpty)
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: currencyValue,
                      decoration: const InputDecoration(
                        labelText: 'Валюта зачисления',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: currencies
                          .map((c) =>
                              DropdownMenuItem(value: c, child: Text(c)))
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setState(() {
                          _inlineError = null;
                          _currency = v;
                          final next = all.where((a) => a.currency == v).toList();
                          _accountId =
                              next.isNotEmpty ? next.first.id : null;
                        });
                      },
                    )
                  else
                    Text(
                      'Нет счетов в филиале получателя — можно сменить только '
                      'валюту документа, счёт укажут позже.',
                      style: TextStyle(color: AppColors.warning),
                    ),
                  const SizedBox(height: 12),
                  if (forCurrency.isEmpty)
                    Text(
                      'В валюте $currencyValue пока нет счёта — при сохранении '
                      'счёт в документе сбросится, выбор — при подтверждении.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.75),
                      ),
                    )
                  else
                    DropdownButtonFormField<String>(
                      // ignore: deprecated_member_use
                      value: accountValue,
                      decoration: const InputDecoration(
                        labelText: 'Счёт получателя',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: forCurrency
                          .map((a) => DropdownMenuItem(
                                value: a.id,
                                child: Text('${a.name} (${a.currency})'),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() {
                            _inlineError = null;
                            _accountId = v;
                          }),
                    ),
                  if (_inlineError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _inlineError!,
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _rateCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Курс (если нужно изменить)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Комментарий для коллег (в уведомление)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'После сохранения коллеги получат уведомление, а правки '
                    'появятся в истории перевода.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        StreamBuilder<List<BranchAccount>>(
          stream: sl<BranchRepository>().watchBranchAccounts(t.toBranchId),
          builder: (context, snapshot) {
            final all = snapshot.data ?? [];
            return FilledButton(
              onPressed: () => _submit(context, all),
              child: const Text('Сохранить'),
            );
          },
        ),
      ],
    );
  }
}
