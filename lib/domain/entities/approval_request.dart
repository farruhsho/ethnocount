import 'package:equatable/equatable.dart';

/// Тип согласовываемой операции. Совпадает 1:1 с public.approval_action_t
/// из migration 021 — порядок и имена не менять без миграции.
enum ApprovalAction {
  transferReject,
  transferAmendAmount,
  clientUpdate,
  clientArchive,
  branchAccountUpdate,
  branchAccountArchive;

  String toWire() {
    switch (this) {
      case ApprovalAction.transferReject:
        return 'transfer_reject';
      case ApprovalAction.transferAmendAmount:
        return 'transfer_amend_amount';
      case ApprovalAction.clientUpdate:
        return 'client_update';
      case ApprovalAction.clientArchive:
        return 'client_archive';
      case ApprovalAction.branchAccountUpdate:
        return 'branch_account_update';
      case ApprovalAction.branchAccountArchive:
        return 'branch_account_archive';
    }
  }

  static ApprovalAction? tryFromWire(String? value) {
    switch (value) {
      case 'transfer_reject':
        return ApprovalAction.transferReject;
      case 'transfer_amend_amount':
        return ApprovalAction.transferAmendAmount;
      case 'client_update':
        return ApprovalAction.clientUpdate;
      case 'client_archive':
        return ApprovalAction.clientArchive;
      case 'branch_account_update':
        return ApprovalAction.branchAccountUpdate;
      case 'branch_account_archive':
        return ApprovalAction.branchAccountArchive;
    }
    return null;
  }

  /// Локализованное название — для UI карточек и notifications.
  String get label {
    switch (this) {
      case ApprovalAction.transferReject:
        return 'Отмена перевода';
      case ApprovalAction.transferAmendAmount:
        return 'Изменение суммы перевода';
      case ApprovalAction.clientUpdate:
        return 'Изменение клиента';
      case ApprovalAction.clientArchive:
        return 'Удаление клиента';
      case ApprovalAction.branchAccountUpdate:
        return 'Изменение счёта';
      case ApprovalAction.branchAccountArchive:
        return 'Архив счёта';
    }
  }
}

enum ApprovalStatus {
  pending,
  approved,
  rejected;

  String toWire() => name;

  static ApprovalStatus tryFromWire(String? value) {
    switch (value) {
      case 'approved':
        return ApprovalStatus.approved;
      case 'rejected':
        return ApprovalStatus.rejected;
      default:
        return ApprovalStatus.pending;
    }
  }
}

class ApprovalRequest extends Equatable {
  final String id;
  final ApprovalAction action;
  final String targetId;
  final Map<String, dynamic> payload;
  final String? reason;
  final String requestedBy;
  final DateTime requestedAt;
  final ApprovalStatus status;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reviewNote;
  final Map<String, dynamic>? executionResult;

  const ApprovalRequest({
    required this.id,
    required this.action,
    required this.targetId,
    required this.payload,
    required this.reason,
    required this.requestedBy,
    required this.requestedAt,
    required this.status,
    this.reviewedBy,
    this.reviewedAt,
    this.reviewNote,
    this.executionResult,
  });

  bool get isPending => status == ApprovalStatus.pending;

  @override
  List<Object?> get props => [
        id,
        action,
        targetId,
        status,
        reviewedAt,
        requestedAt,
      ];
}
