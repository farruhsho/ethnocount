import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';

/// Диалог редактирования перевода. Для принятых/выданных — только имена, телефоны, карты.
class EditTransferDialog extends StatefulWidget {
  const EditTransferDialog({
    super.key,
    required this.transfer,
    required this.onSaved,
    this.allowAmountEdit = true,
  });

  final Transfer transfer;
  final VoidCallback onSaved;
  /// false для принятых/выданных — сумма не редактируется
  final bool allowAmountEdit;

  @override
  State<EditTransferDialog> createState() => _EditTransferDialogState();
}

class _EditTransferDialogState extends State<EditTransferDialog> {
  late final TextEditingController _amountCtrl;
  late final TextEditingController _descriptionCtrl;
  late final TextEditingController _senderNameCtrl;
  late final TextEditingController _senderPhoneCtrl;
  late final TextEditingController _senderInfoCtrl;
  late final TextEditingController _receiverNameCtrl;
  late final TextEditingController _receiverPhoneCtrl;
  late final TextEditingController _receiverInfoCtrl;

  @override
  void initState() {
    super.initState();
    final t = widget.transfer;
    _amountCtrl = TextEditingController(text: t.amount.toString());
    _descriptionCtrl = TextEditingController(text: t.description ?? '');
    _senderNameCtrl = TextEditingController(text: t.senderName ?? '');
    _senderPhoneCtrl = TextEditingController(text: t.senderPhone ?? '');
    _senderInfoCtrl = TextEditingController(text: t.senderInfo ?? '');
    _receiverNameCtrl = TextEditingController(text: t.receiverName ?? '');
    _receiverPhoneCtrl = TextEditingController(text: t.receiverPhone ?? '');
    _receiverInfoCtrl = TextEditingController(text: t.receiverInfo ?? '');
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _descriptionCtrl.dispose();
    _senderNameCtrl.dispose();
    _senderPhoneCtrl.dispose();
    _senderInfoCtrl.dispose();
    _receiverNameCtrl.dispose();
    _receiverPhoneCtrl.dispose();
    _receiverInfoCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.allowAmountEdit) {
      final amount = double.tryParse(_amountCtrl.text.replaceAll(',', '.'));
      if (amount == null || amount <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Введите корректную сумму')),
        );
        return;
      }
    }
    context.read<TransferBloc>().add(TransferUpdateRequested(
          transferId: widget.transfer.id,
          amount: widget.allowAmountEdit ? double.tryParse(_amountCtrl.text.replaceAll(',', '.')) : null,
          description: _descriptionCtrl.text.trim().isNotEmpty ? _descriptionCtrl.text.trim() : null,
          senderName: _senderNameCtrl.text.trim(),
          senderPhone: _senderPhoneCtrl.text.trim(),
          senderInfo: _senderInfoCtrl.text.trim(),
          receiverName: _receiverNameCtrl.text.trim(),
          receiverPhone: _receiverPhoneCtrl.text.trim(),
          receiverInfo: _receiverInfoCtrl.text.trim(),
        ));
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.transfer;
    return BlocListener<TransferBloc, TransferBlocState>(
      listenWhen: (prev, curr) =>
          prev.status != curr.status &&
          (curr.status == TransferBlocStatus.success ||
              curr.status == TransferBlocStatus.error),
      listener: (context, state) {
        if (state.status == TransferBlocStatus.success) {
          Navigator.of(context).pop();
        }
      },
      child: AlertDialog(
        title: Text('Изменить перевод ${t.transactionCode ?? t.id.substring(0, 8)}'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.allowAmountEdit) ...[
                  TextField(
                    controller: _amountCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Сумма',
                      hintText: 'Введите сумму',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Сумма: ${t.totalDebitAmount.toStringAsFixed(0)} ${t.currency}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
                TextField(
                  controller: _descriptionCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Назначение платежа',
                    hintText: 'Оплата по договору...',
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _senderInfoCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Номер карты отправителя',
                    hintText: 'Номер карты или реквизиты',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _senderNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Имя отправителя',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _senderPhoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Телефон отправителя',
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _receiverInfoCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Номер карты получателя',
                    hintText: 'Номер карты или реквизиты',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _receiverNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Имя получателя',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _receiverPhoneCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Телефон получателя',
                  ),
                  keyboardType: TextInputType.phone,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => _submit(),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }
}
