import 'package:flutter/material.dart';

import 'package:ethnocount/core/constants/app_spacing.dart';
import 'package:ethnocount/core/di/injection.dart';
import 'package:ethnocount/core/extensions/context_x.dart';
import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/domain/repositories/approval_repository.dart';

/// Универсальный диалог запроса согласования у директора.
///
/// Используется в местах, где accountant пытается выполнить деструктивную
/// или денежную операцию: вместо прямого вызова RPC мы отправляем заявку
/// в pending_approvals и показываем "Заявка отправлена".
class RequestApprovalDialog extends StatefulWidget {
  const RequestApprovalDialog({
    super.key,
    required this.action,
    required this.targetId,
    required this.summary,
    this.payload = const {},
  });

  /// Что будет сделано после одобрения.
  final ApprovalAction action;

  /// ID цели — перевод/клиент/счёт.
  final String targetId;

  /// Краткое описание для директора: "Удалить перевод ELX-2026-000010".
  final String summary;

  /// Параметры, которые approve_request передаст в нижележащий RPC.
  final Map<String, dynamic> payload;

  static Future<bool> show(
    BuildContext context, {
    required ApprovalAction action,
    required String targetId,
    required String summary,
    Map<String, dynamic> payload = const {},
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => RequestApprovalDialog(
        action: action,
        targetId: targetId,
        summary: summary,
        payload: payload,
      ),
    );
    return ok ?? false;
  }

  @override
  State<RequestApprovalDialog> createState() => _RequestApprovalDialogState();
}

class _RequestApprovalDialogState extends State<RequestApprovalDialog> {
  final _reasonCtrl = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reasonCtrl.text.trim();
    if (reason.length < 3) {
      setState(() => _error = 'Минимум 3 символа');
      return;
    }
    setState(() {
      _error = null;
      _submitting = true;
    });
    final res = await sl<ApprovalRepository>().request(
      action: widget.action,
      targetId: widget.targetId,
      reason: reason,
      payload: widget.payload,
    );
    if (!mounted) return;
    res.fold(
      (f) => setState(() {
        _error = f.message;
        _submitting = false;
      }),
      (_) {
        Navigator.of(context).pop(true);
        context.showSuccessSnackBar(
          'Заявка отправлена директору на согласование',
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.shield_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(child: Text('Требуется согласование')),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.summary,
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '${widget.action.label}: операция выполнится автоматически после одобрения директора.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _reasonCtrl,
              enabled: !_submitting,
              autofocus: true,
              minLines: 2,
              maxLines: 4,
              decoration: InputDecoration(
                labelText: 'Причина *',
                hintText: 'Чтобы директор понимал контекст',
                errorText: _error,
              ),
              textInputAction: TextInputAction.newline,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded, size: 16),
          label: const Text('Отправить'),
        ),
      ],
    );
  }
}
