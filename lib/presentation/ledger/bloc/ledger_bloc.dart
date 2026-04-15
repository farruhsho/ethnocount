import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/ledger_entry.dart';
import 'package:ethnocount/domain/usecases/ledger/watch_ledger.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';

// ─── Events ───

abstract class LedgerEvent extends Equatable {
  const LedgerEvent();
  @override
  List<Object?> get props => [];
}

class LedgerLoadRequested extends LedgerEvent {
  final String branchId;
  final String? accountId;
  final DateTime? startDate;
  final DateTime? endDate;
  const LedgerLoadRequested({
    required this.branchId,
    this.accountId,
    this.startDate,
    this.endDate,
  });
  @override
  List<Object?> get props => [branchId, accountId, startDate, endDate];
}

// ─── State ───

enum LedgerBlocStatus { initial, loading, loaded, error }

class LedgerBlocState extends Equatable {
  final LedgerBlocStatus status;
  final List<LedgerEntry> entries;
  final double? accountBalance;
  final String? errorMessage;

  const LedgerBlocState({
    this.status = LedgerBlocStatus.initial,
    this.entries = const [],
    this.accountBalance,
    this.errorMessage,
  });

  LedgerBlocState copyWith({
    LedgerBlocStatus? status,
    List<LedgerEntry>? entries,
    double? accountBalance,
    String? errorMessage,
  }) {
    return LedgerBlocState(
      status: status ?? this.status,
      entries: entries ?? this.entries,
      accountBalance: accountBalance ?? this.accountBalance,
      errorMessage: errorMessage,
    );
  }

  @override
  List<Object?> get props => [status, entries, accountBalance];
}

// ─── BLoC ───

class LedgerBloc extends Bloc<LedgerEvent, LedgerBlocState> {
  final WatchLedgerUseCase _watchLedger;
  final LedgerRepository _ledgerRepository;

  LedgerBloc({
    required WatchLedgerUseCase watchLedger,
    required LedgerRepository ledgerRepository,
  })  : _watchLedger = watchLedger,
        _ledgerRepository = ledgerRepository,
        super(const LedgerBlocState()) {
    on<LedgerLoadRequested>(_onLoad);
  }

  Future<void> _onLoad(
    LedgerLoadRequested event,
    Emitter<LedgerBlocState> emit,
  ) async {
    emit(state.copyWith(status: LedgerBlocStatus.loading));

    // Load balance if specific account
    if (event.accountId != null) {
      final balanceResult =
          await _ledgerRepository.getAccountBalance(event.accountId!);
      balanceResult.fold(
        (_) {},
        (balance) => emit(state.copyWith(accountBalance: balance)),
      );
    }

    await emit.forEach(
      _watchLedger(
        branchId: event.branchId,
        accountId: event.accountId,
        startDate: event.startDate,
        endDate: event.endDate,
      ),
      onData: (entries) => state.copyWith(
        status: LedgerBlocStatus.loaded,
        entries: entries,
      ),
      onError: (error, _) => state.copyWith(
        status: LedgerBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }
}
