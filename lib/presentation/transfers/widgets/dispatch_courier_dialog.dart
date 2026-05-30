import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/icons/app_icons.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';

/// Диалог "Отдать курьеру": бухгалтер ОТПРАВЛЯЮЩЕГО филиала фиксирует, что
/// деньги переданы курьеру. Имя/телефон курьера опциональны.
Future<void> showDispatchCourierDialog(BuildContext context, Transfer t) async {
  final nameCtrl = TextEditingController();
  final phoneCtrl = TextEditingController();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: const [
          Icon(AppIcons.local_shipping, size: 22),
          SizedBox(width: AppSpacing.sm),
          Text('Отдать курьеру'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Перевод ${t.transactionCode ?? t.id.substring(0, 8)}\n'
              '${t.amount} ${t.currency} → ${t.toCurrency ?? t.currency}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Имя курьера (необязательно)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Телефон курьера (необязательно)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: () {
            final name = nameCtrl.text.trim();
            final phone = phoneCtrl.text.trim();
            Navigator.pop(ctx);
            context.read<TransferBloc>().add(TransferDispatchRequested(
                  t.id,
                  courierName: name.isEmpty ? null : name,
                  courierPhone: phone.isEmpty ? null : phone,
                ));
          },
          icon: const Icon(AppIcons.local_shipping, size: 18),
          label: const Text('Отдать курьеру'),
        ),
      ],
    ),
  );
}
