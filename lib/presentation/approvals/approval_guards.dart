import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/presentation/approvals/widgets/request_approval_dialog.dart';
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';

/// Расширения над BuildContext, которые принимают денежные/удаляющие
/// операции и, в зависимости от роли пользователя, либо выполняют их
/// напрямую (creator/director), либо отправляют заявку директору.
///
/// Этот слой инкапсулирует все правила [[project-director-approval]] —
/// callsite просто говорит "выполни это" и не думает о ролях.
extension TransferApprovalGuard on BuildContext {
  bool get _isAccountant {
    try {
      final role = read<AuthBloc>().state.user?.role;
      return role == SystemRole.accountant;
    } catch (_) {
      return false;
    }
  }

  /// Запрос на изменение суммы перевода.
  Future<bool> guardAmendTransferAmount(
    Transfer t, {
    required double newAmount,
    String? note,
  }) async {
    if (!_isAccountant) return true;
    await RequestApprovalDialog.show(
      this,
      action: ApprovalAction.transferAmendAmount,
      targetId: t.id,
      summary:
          'Изменить сумму перевода ${t.transactionCode ?? t.id}: ${t.amount} → $newAmount ${t.currency}',
      payload: {
        'amount': newAmount,
        if (note != null && note.isNotEmpty) 'note': note,
      },
    );
    return false;
  }
}

extension ClientApprovalGuard on BuildContext {
  bool get _isAccountantClient {
    try {
      final role = read<AuthBloc>().state.user?.role;
      return role == SystemRole.accountant;
    } catch (_) {
      return false;
    }
  }

  Future<bool> guardArchiveClient(Client c) async {
    if (!_isAccountantClient) return true;
    await RequestApprovalDialog.show(
      this,
      action: ApprovalAction.clientArchive,
      targetId: c.id,
      summary: 'Удалить клиента «${c.name}» (${c.phone})',
      payload: const {'archive': true},
    );
    return false;
  }

  Future<bool> guardUpdateClient(
    Client c, {
    String? name,
    String? phone,
    String? country,
    String? currency,
    String? branchId,
    List<String>? walletCurrencies,
  }) async {
    if (!_isAccountantClient) return true;
    final changes = <String, dynamic>{
      if (name != null && name != c.name) 'name': name,
      if (phone != null && phone != c.phone) 'phone': phone,
      if (country != null && country != c.country) 'country': country,
      if (currency != null && currency != c.currency) 'currency': currency,
      if (branchId != null && branchId != c.branchId) 'branch_id': branchId,
      'wallet_currencies': ?walletCurrencies,
    };
    if (changes.isEmpty) return false;
    await RequestApprovalDialog.show(
      this,
      action: ApprovalAction.clientUpdate,
      targetId: c.id,
      summary: 'Изменить клиента «${c.name}»',
      payload: changes,
    );
    return false;
  }
}

extension BranchAccountApprovalGuard on BuildContext {
  bool get _isAccountantAccount {
    try {
      final role = read<AuthBloc>().state.user?.role;
      return role == SystemRole.accountant;
    } catch (_) {
      return false;
    }
  }

  Future<bool> guardArchiveBranchAccount(BranchAccount a) async {
    if (!_isAccountantAccount) return true;
    await RequestApprovalDialog.show(
      this,
      action: ApprovalAction.branchAccountArchive,
      targetId: a.id,
      summary:
          'Архивировать счёт «${a.name}» (${a.currency})',
      payload: const {'archive': true},
    );
    return false;
  }

  Future<bool> guardUpdateBranchAccount(
    BranchAccount a, {
    String? name,
    AccountType? type,
    String? currency,
    String? cardNumber,
    bool clearCardNumber = false,
    String? cardholderName,
    String? bankName,
    int? expiryMonth,
    int? expiryYear,
    String? notes,
    int? sortOrder,
  }) async {
    if (!_isAccountantAccount) return true;
    final payload = <String, dynamic>{
      'name': ?name,
      if (type != null) 'type': type.name,
      'currency': ?currency,
      'card_number': ?cardNumber,
      if (clearCardNumber) 'clear_card_number': true,
      'cardholder_name': ?cardholderName,
      'bank_name': ?bankName,
      'expiry_month': ?expiryMonth,
      'expiry_year': ?expiryYear,
      'notes': ?notes,
      'sort_order': ?sortOrder,
    };
    if (payload.isEmpty) return false;
    await RequestApprovalDialog.show(
      this,
      action: ApprovalAction.branchAccountUpdate,
      targetId: a.id,
      summary: 'Изменить счёт «${a.name}»',
      payload: payload,
    );
    return false;
  }
}
