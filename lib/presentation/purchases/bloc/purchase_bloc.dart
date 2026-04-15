import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/purchase.dart';
import 'package:ethnocount/domain/repositories/purchase_repository.dart';

// ─── Events ───

abstract class PurchaseEvent extends Equatable {
  const PurchaseEvent();
  @override
  List<Object?> get props => [];
}

class PurchasesLoadRequested extends PurchaseEvent {
  final String? branchId;
  final DateTime? startDate;
  final DateTime? endDate;

  const PurchasesLoadRequested({
    this.branchId,
    this.startDate,
    this.endDate,
  });

  @override
  List<Object?> get props => [branchId, startDate, endDate];
}

class PurchaseCreateRequested extends PurchaseEvent {
  final String branchId;
  final String? clientId;
  final String? clientName;
  final String description;
  final String? category;
  final double totalAmount;
  final String currency;
  final List<Map<String, dynamic>> payments;

  const PurchaseCreateRequested({
    required this.branchId,
    this.clientId,
    this.clientName,
    required this.description,
    this.category,
    required this.totalAmount,
    required this.currency,
    required this.payments,
  });

  @override
  List<Object?> get props =>
      [branchId, description, totalAmount, currency];
}

class PurchaseUpdateRequested extends PurchaseEvent {
  final String purchaseId;
  final String? description;
  final String? category;
  final double? totalAmount;
  final List<Map<String, dynamic>>? payments;

  const PurchaseUpdateRequested({
    required this.purchaseId,
    this.description,
    this.category,
    this.totalAmount,
    this.payments,
  });

  @override
  List<Object?> get props => [purchaseId, description, category, totalAmount, payments];
}

class PurchaseDeleteRequested extends PurchaseEvent {
  final String purchaseId;
  final String? reason;

  const PurchaseDeleteRequested({
    required this.purchaseId,
    this.reason,
  });

  @override
  List<Object?> get props => [purchaseId, reason];
}

// ─── State ───

enum PurchaseBlocStatus { initial, loading, loaded, creating, success, error }

class PurchaseBlocState extends Equatable {
  final PurchaseBlocStatus status;
  final List<Purchase> purchases;
  final String? errorMessage;
  final String? successMessage;

  const PurchaseBlocState({
    this.status = PurchaseBlocStatus.initial,
    this.purchases = const [],
    this.errorMessage,
    this.successMessage,
  });

  PurchaseBlocState copyWith({
    PurchaseBlocStatus? status,
    List<Purchase>? purchases,
    String? errorMessage,
    String? successMessage,
  }) {
    return PurchaseBlocState(
      status: status ?? this.status,
      purchases: purchases ?? this.purchases,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  @override
  List<Object?> get props =>
      [status, purchases, errorMessage, successMessage];
}

// ─── BLoC ───

class PurchaseBloc extends Bloc<PurchaseEvent, PurchaseBlocState> {
  final PurchaseRepository _repository;

  PurchaseBloc({required PurchaseRepository repository})
      : _repository = repository,
        super(const PurchaseBlocState()) {
    on<PurchasesLoadRequested>(_onLoad);
    on<PurchaseCreateRequested>(_onCreate);
    on<PurchaseUpdateRequested>(_onUpdate);
    on<PurchaseDeleteRequested>(_onDelete);
  }

  Future<void> _onLoad(
    PurchasesLoadRequested event,
    Emitter<PurchaseBlocState> emit,
  ) async {
    emit(state.copyWith(status: PurchaseBlocStatus.loading));
    await emit.forEach(
      _repository.watchPurchases(
        branchId: event.branchId,
        startDate: event.startDate,
        endDate: event.endDate,
      ),
      onData: (purchases) => state.copyWith(
        status: PurchaseBlocStatus.loaded,
        purchases: purchases,
      ),
      onError: (error, _) => state.copyWith(
        status: PurchaseBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  Future<void> _onCreate(
    PurchaseCreateRequested event,
    Emitter<PurchaseBlocState> emit,
  ) async {
    emit(state.copyWith(status: PurchaseBlocStatus.creating));
    final result = await _repository.createPurchase(
      branchId: event.branchId,
      clientId: event.clientId,
      clientName: event.clientName,
      description: event.description,
      category: event.category,
      totalAmount: event.totalAmount,
      currency: event.currency,
      payments: event.payments,
    );
    result.fold(
      (f) => emit(state.copyWith(
        status: PurchaseBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: PurchaseBlocStatus.success,
        successMessage: 'Покупка записана',
      )),
    );
  }

  Future<void> _onUpdate(
    PurchaseUpdateRequested event,
    Emitter<PurchaseBlocState> emit,
  ) async {
    emit(state.copyWith(status: PurchaseBlocStatus.creating));
    final result = await _repository.updatePurchase(
      purchaseId: event.purchaseId,
      description: event.description,
      category: event.category,
      totalAmount: event.totalAmount,
      payments: event.payments,
    );
    result.fold(
      (f) => emit(state.copyWith(
        status: PurchaseBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: PurchaseBlocStatus.success,
        successMessage: 'Покупка обновлена',
      )),
    );
  }

  Future<void> _onDelete(
    PurchaseDeleteRequested event,
    Emitter<PurchaseBlocState> emit,
  ) async {
    emit(state.copyWith(status: PurchaseBlocStatus.creating));
    final result = await _repository.deletePurchase(
      purchaseId: event.purchaseId,
      reason: event.reason,
    );
    result.fold(
      (f) => emit(state.copyWith(
        status: PurchaseBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: PurchaseBlocStatus.success,
        successMessage: 'Покупка удалена',
      )),
    );
  }
}
