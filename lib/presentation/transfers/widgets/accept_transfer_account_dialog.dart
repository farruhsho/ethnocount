import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/core/constants/app_colors.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';

/// Shows a dialog to select recipient account(s) when confirming a transfer
/// that was created without toAccountId.
void showAcceptTransferAccountDialog(BuildContext context, Transfer t) {
  final totalToReceive =
      t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;
  final rows = <MapEntry<String, double>>[MapEntry('', totalToReceive)];

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setState) {
        void tryAutoCorrect(int editedIndex) {
          var sum = rows.fold<double>(0, (s, e) => s + e.value);
          if (sum <= totalToReceive + 0.01) return;
          final overflow = sum - totalToReceive;
          // Find row to reduce: prefer first row, or one with enough value
          int reduceIdx = -1;
          for (var j = 0; j < rows.length; j++) {
            if (j != editedIndex && rows[j].value >= overflow) {
              reduceIdx = j;
              break;
            }
          }
          if (reduceIdx < 0) {
            for (var j = 0; j < rows.length; j++) {
              if (j != editedIndex && rows[j].value > 0) {
                reduceIdx = j;
                break;
              }
            }
          }
          if (reduceIdx >= 0) {
            final oldVal = rows[reduceIdx].value;
            final newVal = (oldVal - overflow).clamp(0.0, double.infinity);
            rows[reduceIdx] = MapEntry(rows[reduceIdx].key, newVal);
            setState(() {});
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Сумма автоматически скорректирована: '
                      '${oldVal.toStringAsFixed(0)} → ${newVal.toStringAsFixed(0)}',
                    ),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            });
          }
        }

        return AlertDialog(
          title: const Text('Принять перевод'),
          content: SizedBox(
            width: 480,
            child: StreamBuilder<List<BranchAccount>>(
              stream: sl<BranchRepository>().watchBranchAccounts(t.toBranchId),
              builder: (context, snapshot) {
                final accounts = snapshot.data ?? [];
                if (accounts.isEmpty &&
                    snapshot.connectionState == ConnectionState.done) {
                  return const Text('Нет счетов в филиале получателя');
                }
                final expectCur = t.toCurrency ?? t.currency;
                final accountsForCur =
                    accounts.where((a) => a.currency == expectCur).toList();
                final accountsForPicker =
                    accountsForCur.isNotEmpty ? accountsForCur : accounts;
                if (rows.length == 1 &&
                    rows.first.key.isEmpty &&
                    accountsForPicker.isNotEmpty) {
                  rows[0] = MapEntry(accountsForPicker.first.id, totalToReceive);
                }
                final sum = rows.fold<double>(0, (s, e) => s + e.value);
                final isValid = sum >= totalToReceive - 0.01 &&
                    sum <= totalToReceive + 0.01;
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Распределите ${totalToReceive.toStringAsFixed(2)} ${t.toCurrency ?? t.currency}',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.isDark
                              ? AppColors.darkTextSecondary
                              : AppColors.lightTextSecondary,
                        ),
                      ),
                      if (accountsForCur.isEmpty && accounts.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Нет счёта в валюте $expectCur. Нажмите «Исправить» на '
                          'странице управления или выберите другой счёт ниже.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.warning,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      ...rows.asMap().entries.map((e) {
                        final i = e.key;
                        final r = e.value;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Flexible(
                                flex: 2,
                                child: DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  // ignore: deprecated_member_use
                                  value: r.key.isEmpty ||
                                          !accountsForPicker
                                              .any((a) => a.id == r.key)
                                      ? null
                                      : r.key,
                                  decoration: const InputDecoration(
                                    labelText: 'Счёт',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  items: accountsForPicker
                                      .map((a) => DropdownMenuItem(
                                            value: a.id,
                                            child: Text(
                                              '${a.name} (${a.currency})',
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ))
                                      .toList(),
                                  onChanged: (v) => setState(() {
                                    rows[i] = MapEntry(v ?? '', r.value);
                                  }),
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 90,
                                child: TextFormField(
                                  key: ValueKey('amt-$i-${r.value}'),
                                  initialValue:
                                      r.value > 0 ? r.value.toString() : '',
                                  decoration: const InputDecoration(
                                    labelText: 'Сумма',
                                    isDense: true,
                                    border: OutlineInputBorder(),
                                  ),
                                  keyboardType: const TextInputType.numberWithOptions(
                                      decimal: true),
                                  onChanged: (v) {
                                    final newVal = double.tryParse(v) ?? 0;
                                    rows[i] = MapEntry(r.key, newVal);
                                    setState(() {});
                                    tryAutoCorrect(i);
                                  },
                                ),
                              ),
                              if (rows.length > 1)
                                IconButton(
                                  icon: const Icon(Icons.remove_circle_outline,
                                      size: 20),
                                  constraints: const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 36,
                                  ),
                                  onPressed: () =>
                                      setState(() => rows.removeAt(i)),
                                ),
                            ],
                          ),
                        );
                      }),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => rows.add(const MapEntry('', 0))),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Добавить счёт'),
                      ),
                      if (!isValid && sum > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Сумма должна быть ${totalToReceive.toStringAsFixed(2)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(ctx).colorScheme.error,
                            ),
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
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final sum = rows.fold<double>(0, (s, e) => s + e.value);
                if ((sum - totalToReceive).abs() > 0.01) return;
                final valid = rows
                    .where((r) => r.key.isNotEmpty && r.value > 0)
                    .map((r) => MapEntry(r.key, r.value))
                    .toList();
                if (valid.isEmpty) return;
                if (valid.length == 1) {
                  context.read<TransferBloc>().add(
                        TransferConfirmRequested(t.id,
                            toAccountId: valid.first.key),
                      );
                } else {
                  context.read<TransferBloc>().add(
                        TransferConfirmRequested(t.id,
                            toAccountSplits: valid),
                      );
                }
                Navigator.pop(ctx);
              },
              child: const Text('Принять'),
            ),
          ],
        );
      },
    ),
  );
}
