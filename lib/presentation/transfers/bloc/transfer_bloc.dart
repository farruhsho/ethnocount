import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/usecases/transfer/create_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/confirm_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/issue_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/issue_partial_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/reject_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/update_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/watch_transfers.dart';

// ─── Events ───

abstract class TransferEvent extends Equatable {
  const TransferEvent();
  @override
  List<Object?> get props => [];
}

class TransfersLoadRequested extends TransferEvent {
  final String? branchId;
  final TransferStatus? statusFilter;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool loadMore;

  const TransfersLoadRequested({
    this.branchId,
    this.statusFilter,
    this.startDate,
    this.endDate,
    this.loadMore = false,
  });

  @override
  List<Object?> get props => [branchId, statusFilter, startDate, endDate, loadMore];
}

class TransferCreateRequested extends TransferEvent {
  final String fromBranchId;
  final String toBranchId;
  final String fromAccountId;
  final String? toAccountId;
  final String? toCurrency;
  final double amount;
  final String currency;
  final double exchangeRate;
  final String commissionType;
  final double commissionValue;
  final String commissionCurrency;
  final String commissionMode;
  final String idempotencyKey;
  final String? description;
  final String? clientId;
  final String? senderName;
  final String? senderPhone;
  final String? senderInfo;
  final String? receiverName;
  final String? receiverPhone;
  final String? receiverInfo;

  const TransferCreateRequested({
    required this.fromBranchId,
    required this.toBranchId,
    required this.fromAccountId,
    this.toAccountId,
    this.toCurrency,
    required this.amount,
    required this.currency,
    required this.exchangeRate,
    this.commissionType = 'fixed',
    this.commissionValue = 0,
    required this.commissionCurrency,
    this.commissionMode = 'fromSender',
    required this.idempotencyKey,
    this.description,
    this.clientId,
    this.senderName,
    this.senderPhone,
    this.senderInfo,
    this.receiverName,
    this.receiverPhone,
    this.receiverInfo,
  });

  @override
  List<Object?> get props => [fromBranchId, toBranchId, amount, idempotencyKey];
}

class TransferConfirmRequested extends TransferEvent {
  final String transferId;
  final String? toAccountId;
  final List<MapEntry<String, double>>? toAccountSplits;
  const TransferConfirmRequested(this.transferId, {this.toAccountId, this.toAccountSplits});
  @override
  List<Object?> get props => [transferId, toAccountId, toAccountSplits];
}

class TransferIssueRequested extends TransferEvent {
  final String transferId;
  const TransferIssueRequested(this.transferId);
  @override
  List<Object?> get props => [transferId];
}

/// Pay out one tranche of a confirmed transfer.
/// `amount` is in receiver currency; `note` is optional bookkeeping comment.
/// [fromAccountId] — счёт получающего филиала, с которого выданы деньги.
class TransferIssuePartialRequested extends TransferEvent {
  final String transferId;
  final double amount;
  final String? note;
  final String? fromAccountId;
  const TransferIssuePartialRequested({
    required this.transferId,
    required this.amount,
    this.note,
    this.fromAccountId,
  });
  @override
  List<Object?> get props => [transferId, amount, note, fromAccountId];
}

class TransferRejectRequested extends TransferEvent {
  final String transferId;
  final String reason;
  const TransferRejectRequested(this.transferId, this.reason);
  @override
  List<Object?> get props => [transferId, reason];
}

class TransferUpdateRequested extends TransferEvent {
  final String transferId;
  final double? amount;
  final String? description;
  final String? senderName;
  final String? senderPhone;
  final String? senderInfo;
  final String? receiverName;
  final String? receiverPhone;
  final String? receiverInfo;
  final String? toAccountId;
  final String? toCurrency;
  final double? exchangeRate;
  final String? amendmentNote;

  const TransferUpdateRequested({
    required this.transferId,
    this.amount,
    this.description,
    this.senderName,
    this.senderPhone,
    this.senderInfo,
    this.receiverName,
    this.receiverPhone,
    this.receiverInfo,
    this.toAccountId,
    this.toCurrency,
    this.exchangeRate,
    this.amendmentNote,
  });

  @override
  List<Object?> get props => [
        transferId,
        amount,
        description,
        senderInfo,
        receiverInfo,
        toAccountId,
        toCurrency,
        exchangeRate,
        amendmentNote,
      ];
}

// ─── State ───

enum TransferBlocStatus { initial, loading, loaded, creating, success, error }

class TransferBlocState extends Equatable {
  final TransferBlocStatus status;
  final List<Transfer> transfers;
  final bool hasReachedMax;
  final String? errorMessage;
  final String? successMessage;

  const TransferBlocState({
    this.status = TransferBlocStatus.initial,
    this.transfers = const [],
    this.hasReachedMax = false,
    this.errorMessage,
    this.successMessage,
  });

  TransferBlocState copyWith({
    TransferBlocStatus? status,
    List<Transfer>? transfers,
    bool? hasReachedMax,
    String? errorMessage,
    String? successMessage,
  }) {
    return TransferBlocState(
      status: status ?? this.status,
      transfers: transfers ?? this.transfers,
      hasReachedMax: hasReachedMax ?? this.hasReachedMax,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  @override
  List<Object?> get props => [status, transfers, hasReachedMax, errorMessage, successMessage];
}

// ─── BLoC ───

class TransferBloc extends Bloc<TransferEvent, TransferBlocState> {
  final CreateTransferUseCase _createTransfer;
  final UpdateTransferUseCase _updateTransfer;
  final ConfirmTransferUseCase _confirmTransfer;
  final IssueTransferUseCase _issueTransfer;
  final IssuePartialTransferUseCase _issuePartialTransfer;
  final RejectTransferUseCase _rejectTransfer;
  final WatchTransfersUseCase _watchTransfers;

  TransferBloc({
    required CreateTransferUseCase createTransfer,
    required UpdateTransferUseCase updateTransfer,
    required ConfirmTransferUseCase confirmTransfer,
    required IssueTransferUseCase issueTransfer,
    required IssuePartialTransferUseCase issuePartialTransfer,
    required RejectTransferUseCase rejectTransfer,
    required WatchTransfersUseCase watchTransfers,
  })  : _createTransfer = createTransfer,
        _updateTransfer = updateTransfer,
        _confirmTransfer = confirmTransfer,
        _issueTransfer = issueTransfer,
        _issuePartialTransfer = issuePartialTransfer,
        _rejectTransfer = rejectTransfer,
        _watchTransfers = watchTransfers,
        super(const TransferBlocState()) {
    on<TransfersLoadRequested>(_onLoad);
    on<TransferCreateRequested>(_onCreate);
    on<TransferUpdateRequested>(_onUpdate);
    on<TransferConfirmRequested>(_onConfirm);
    on<TransferIssueRequested>(_onIssue);
    on<TransferIssuePartialRequested>(_onIssuePartial);
    on<TransferRejectRequested>(_onReject);
  }

  Future<void> _onLoad(
    TransfersLoadRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    if (state.hasReachedMax && event.loadMore) return;

    if (!event.loadMore) {
      emit(state.copyWith(status: TransferBlocStatus.loading, transfers: [], hasReachedMax: false));
    }

    final currentLimit = event.loadMore ? state.transfers.length + 50 : 50;

    await emit.forEach(
      _watchTransfers(
        branchId: event.branchId,
        statusFilter: event.statusFilter,
        startDate: event.startDate,
        endDate: event.endDate,
        limit: currentLimit,
      ),
      onData: (transfers) => state.copyWith(
        status: TransferBlocStatus.loaded,
        transfers: transfers,
        hasReachedMax: transfers.length < currentLimit,
      ),
      onError: (error, _) => state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  Future<void> _onCreate(
    TransferCreateRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.creating));

    final result = await _createTransfer(
      fromBranchId: event.fromBranchId,
      toBranchId: event.toBranchId,
      fromAccountId: event.fromAccountId,
      toAccountId: event.toAccountId,
      toCurrency: event.toCurrency,
      amount: event.amount,
      currency: event.currency,
      exchangeRate: event.exchangeRate,
      commissionType: event.commissionType,
      commissionValue: event.commissionValue,
      commissionCurrency: event.commissionCurrency,
      commissionMode: event.commissionMode,
      idempotencyKey: event.idempotencyKey,
      description: event.description,
      clientId: event.clientId,
      senderName: event.senderName,
      senderPhone: event.senderPhone,
      senderInfo: event.senderInfo,
      receiverName: event.receiverName,
      receiverPhone: event.receiverPhone,
      receiverInfo: event.receiverInfo,
    );

    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (transfer) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: 'Transfer created — pending confirmation',
      )),
    );
  }

  Future<void> _onUpdate(
    TransferUpdateRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.loading));

    final result = await _updateTransfer(
      transferId: event.transferId,
      amount: event.amount,
      description: event.description,
      senderName: event.senderName,
      senderPhone: event.senderPhone,
      senderInfo: event.senderInfo,
      receiverName: event.receiverName,
      receiverPhone: event.receiverPhone,
      receiverInfo: event.receiverInfo,
      toAccountId: event.toAccountId,
      toCurrency: event.toCurrency,
      exchangeRate: event.exchangeRate,
      amendmentNote: event.amendmentNote,
    );
    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (_) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: 'Перевод обновлён',
      )),
    );
  }

  Future<void> _onConfirm(
    TransferConfirmRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.loading));

    final result = await _confirmTransfer(
      transferId: event.transferId,
      toAccountId: event.toAccountId,
      toAccountSplits: event.toAccountSplits,
    );
    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (_) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: 'Transfer confirmed',
      )),
    );
  }

  Future<void> _onIssue(
    TransferIssueRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.loading));

    final result = await _issueTransfer(transferId: event.transferId);
    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (_) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: 'Перевод отмечен как выдан',
      )),
    );
  }

  Future<void> _onIssuePartial(
    TransferIssuePartialRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.loading));

    final result = await _issuePartialTransfer(
      transferId: event.transferId,
      amount: event.amount,
      note: event.note,
      fromAccountId: event.fromAccountId,
    );
    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (fullyIssued) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: fullyIssued
            ? 'Перевод полностью выдан'
            : 'Выдано ${event.amount.toStringAsFixed(2)} — перевод остаётся открытым',
      )),
    );
  }

  Future<void> _onReject(
    TransferRejectRequested event,
    Emitter<TransferBlocState> emit,
  ) async {
    emit(state.copyWith(status: TransferBlocStatus.loading));

    final result = await _rejectTransfer(
      transferId: event.transferId,
      reason: event.reason,
    );
    result.fold(
      (failure) => emit(state.copyWith(
        status: TransferBlocStatus.error,
        errorMessage: failure.message,
      )),
      (_) => emit(state.copyWith(
        status: TransferBlocStatus.success,
        successMessage: 'Transfer rejected — funds unlocked',
      )),
    );
  }
}
