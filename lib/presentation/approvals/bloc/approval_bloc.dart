import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:ethnocount/domain/entities/approval_request.dart';
import 'package:ethnocount/domain/repositories/approval_repository.dart';

// ─── Events ───

abstract class ApprovalEvent extends Equatable {
  const ApprovalEvent();
  @override
  List<Object?> get props => [];
}

class ApprovalsWatchRequested extends ApprovalEvent {
  /// null → все статусы (история). По умолчанию — только pending.
  final ApprovalStatus? statusFilter;
  const ApprovalsWatchRequested({this.statusFilter = ApprovalStatus.pending});
  @override
  List<Object?> get props => [statusFilter];
}

class ApprovalApproveRequested extends ApprovalEvent {
  final String approvalId;
  final String? note;
  const ApprovalApproveRequested(this.approvalId, {this.note});
  @override
  List<Object?> get props => [approvalId, note];
}

class ApprovalRejectRequested extends ApprovalEvent {
  final String approvalId;
  final String? note;
  const ApprovalRejectRequested(this.approvalId, {this.note});
  @override
  List<Object?> get props => [approvalId, note];
}

class ApprovalRequestCreateRequested extends ApprovalEvent {
  final ApprovalAction action;
  final String targetId;
  final String reason;
  final Map<String, dynamic> payload;
  const ApprovalRequestCreateRequested({
    required this.action,
    required this.targetId,
    required this.reason,
    this.payload = const {},
  });
  @override
  List<Object?> get props => [action, targetId, reason, payload];
}

// ─── State ───

enum ApprovalBlocStatus { initial, loading, loaded, submitting, error }

class ApprovalState extends Equatable {
  final ApprovalBlocStatus status;
  final List<ApprovalRequest> items;
  final String? errorMessage;
  final String? successMessage;

  const ApprovalState({
    this.status = ApprovalBlocStatus.initial,
    this.items = const [],
    this.errorMessage,
    this.successMessage,
  });

  int get pendingCount =>
      items.where((e) => e.status == ApprovalStatus.pending).length;

  ApprovalState copyWith({
    ApprovalBlocStatus? status,
    List<ApprovalRequest>? items,
    String? errorMessage,
    String? successMessage,
  }) {
    return ApprovalState(
      status: status ?? this.status,
      items: items ?? this.items,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  @override
  List<Object?> get props =>
      [status, items, errorMessage, successMessage];
}

// ─── BLoC ───

class ApprovalBloc extends Bloc<ApprovalEvent, ApprovalState> {
  final ApprovalRepository _repo;

  ApprovalBloc({required ApprovalRepository repository})
      : _repo = repository,
        super(const ApprovalState()) {
    on<ApprovalsWatchRequested>(_onWatch);
    on<ApprovalApproveRequested>(_onApprove);
    on<ApprovalRejectRequested>(_onReject);
    on<ApprovalRequestCreateRequested>(_onCreate);
  }

  Future<void> _onWatch(
    ApprovalsWatchRequested event,
    Emitter<ApprovalState> emit,
  ) async {
    emit(state.copyWith(status: ApprovalBlocStatus.loading));
    await emit.forEach(
      _repo.watch(status: event.statusFilter),
      onData: (items) => state.copyWith(
        status: ApprovalBlocStatus.loaded,
        items: items,
      ),
      onError: (e, _) => state.copyWith(
        status: ApprovalBlocStatus.error,
        errorMessage: e.toString(),
      ),
    );
  }

  Future<void> _onApprove(
    ApprovalApproveRequested event,
    Emitter<ApprovalState> emit,
  ) async {
    emit(state.copyWith(status: ApprovalBlocStatus.submitting));
    final res = await _repo.approve(
      approvalId: event.approvalId,
      note: event.note,
    );
    res.fold(
      (f) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        successMessage: 'Заявка одобрена',
      )),
    );
  }

  Future<void> _onReject(
    ApprovalRejectRequested event,
    Emitter<ApprovalState> emit,
  ) async {
    emit(state.copyWith(status: ApprovalBlocStatus.submitting));
    final res = await _repo.reject(
      approvalId: event.approvalId,
      note: event.note,
    );
    res.fold(
      (f) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        successMessage: 'Заявка отклонена',
      )),
    );
  }

  Future<void> _onCreate(
    ApprovalRequestCreateRequested event,
    Emitter<ApprovalState> emit,
  ) async {
    emit(state.copyWith(status: ApprovalBlocStatus.submitting));
    final res = await _repo.request(
      action: event.action,
      targetId: event.targetId,
      reason: event.reason,
      payload: event.payload,
    );
    res.fold(
      (f) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: ApprovalBlocStatus.loaded,
        successMessage: 'Заявка отправлена директору',
      )),
    );
  }
}
