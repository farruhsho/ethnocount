import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/branch.dart';
import 'package:ethnocount/domain/entities/branch_account.dart';
import 'package:ethnocount/domain/entities/transfer.dart';
import 'package:ethnocount/domain/entities/enums.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';

// ─── Events ───

abstract class DashboardEvent extends Equatable {
  const DashboardEvent();
  @override
  List<Object?> get props => [];
}

class DashboardStarted extends DashboardEvent {
  const DashboardStarted();
}

class DashboardBranchSelected extends DashboardEvent {
  final String branchId;
  const DashboardBranchSelected(this.branchId);
  @override
  List<Object?> get props => [branchId];
}

class DashboardRefreshRequested extends DashboardEvent {
  const DashboardRefreshRequested();
}

class _BalancesUpdated extends DashboardEvent {
  final Map<String, double> balances;
  const _BalancesUpdated(this.balances);
  @override
  List<Object?> get props => [balances];
}

class _BalancesListenFailed extends DashboardEvent {
  final String message;
  const _BalancesListenFailed(this.message);
  @override
  List<Object?> get props => [message];
}

class _PendingTransfersUpdated extends DashboardEvent {
  final List<Transfer> transfers;
  const _PendingTransfersUpdated(this.transfers);
  @override
  List<Object?> get props => [transfers];
}

// ─── State ───

enum DashboardStatus { initial, loading, loaded, error }

class DashboardState extends Equatable {
  final DashboardStatus status;
  final List<Branch> branches;
  final Map<String, List<BranchAccount>> branchAccounts;
  final Map<String, double> accountBalances;
  final List<Transfer> pendingTransfers;
  final String? selectedBranchId;
  final String? errorMessage;

  /// Realtime stream error for [accountBalances] (e.g. permission-denied).
  final String? balanceStreamError;

  const DashboardState({
    this.status = DashboardStatus.initial,
    this.branches = const [],
    this.branchAccounts = const {},
    this.accountBalances = const {},
    this.pendingTransfers = const [],
    this.selectedBranchId,
    this.errorMessage,
    this.balanceStreamError,
  });

  double get totalBalance {
    if (selectedBranchId != null) {
      final accounts = branchAccounts[selectedBranchId] ?? [];
      return accounts.fold<double>(
          0, (sum, a) => sum + (accountBalances[a.id] ?? 0));
    }
    return accountBalances.values.fold<double>(0, (sum, b) => sum + b);
  }

  int get pendingCount => pendingTransfers.length;

  DashboardState copyWith({
    DashboardStatus? status,
    List<Branch>? branches,
    Map<String, List<BranchAccount>>? branchAccounts,
    Map<String, double>? accountBalances,
    List<Transfer>? pendingTransfers,
    String? selectedBranchId,
    String? errorMessage,
    bool clearErrorMessage = false,
    String? balanceStreamError,
    bool clearBalanceStreamError = false,
  }) {
    return DashboardState(
      status: status ?? this.status,
      branches: branches ?? this.branches,
      branchAccounts: branchAccounts ?? this.branchAccounts,
      accountBalances: accountBalances ?? this.accountBalances,
      pendingTransfers: pendingTransfers ?? this.pendingTransfers,
      selectedBranchId: selectedBranchId ?? this.selectedBranchId,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      balanceStreamError: clearBalanceStreamError
          ? null
          : (balanceStreamError ?? this.balanceStreamError),
    );
  }

  @override
  List<Object?> get props => [
        status,
        branches,
        branchAccounts,
        accountBalances,
        pendingTransfers,
        selectedBranchId,
        errorMessage,
        balanceStreamError,
      ];
}

// ─── BLoC ───

class DashboardBloc extends Bloc<DashboardEvent, DashboardState> {
  final BranchRepository _branchRepository;
  final LedgerRepository _ledgerRepository;
  final TransferRepository _transferRepository;

  StreamSubscription<Map<String, double>>? _balancesSub;
  StreamSubscription<List<Transfer>>? _pendingTransfersSub;

  DashboardBloc({
    required BranchRepository branchRepository,
    required LedgerRepository ledgerRepository,
    required TransferRepository transferRepository,
  })  : _branchRepository = branchRepository,
        _ledgerRepository = ledgerRepository,
        _transferRepository = transferRepository,
        super(const DashboardState()) {
    on<DashboardStarted>(_onStarted);
    on<DashboardBranchSelected>(_onBranchSelected);
    on<DashboardRefreshRequested>(_onRefreshRequested);
    on<_BalancesUpdated>(_onBalancesUpdated);
    on<_BalancesListenFailed>(_onBalancesListenFailed);
    on<_PendingTransfersUpdated>(_onPendingTransfersUpdated);
    on<_AccountsLoaded>(_onAccountsLoaded);
  }

  Future<void> _onStarted(
    DashboardStarted event,
    Emitter<DashboardState> emit,
  ) async {
    emit(state.copyWith(status: DashboardStatus.loading));

    _balancesSub?.cancel();
    _balancesSub = _ledgerRepository.watchAccountBalances().listen(
      (balances) => add(_BalancesUpdated(balances)),
      onError: (Object e, _) {
        if (!isClosed) {
          add(_BalancesListenFailed(e.toString()));
        }
      },
    );

    _pendingTransfersSub?.cancel();
    _pendingTransfersSub = _transferRepository
        .watchTransfers(statusFilter: TransferStatus.pending)
        .listen(
      (transfers) => add(_PendingTransfersUpdated(transfers)),
    );

    await emit.forEach(
      _branchRepository.watchBranches(),
      onData: (branches) {
        _loadAccountsForBranches(branches);
        return state.copyWith(
          status: DashboardStatus.loaded,
          branches: branches,
        );
      },
      onError: (error, _) => state.copyWith(
        status: DashboardStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  void _onBalancesUpdated(
    _BalancesUpdated event,
    Emitter<DashboardState> emit,
  ) {
    emit(state.copyWith(
      accountBalances: event.balances,
      clearBalanceStreamError: true,
    ));
  }

  void _onBalancesListenFailed(
    _BalancesListenFailed event,
    Emitter<DashboardState> emit,
  ) {
    final msg = event.message;
    final short = msg.contains('permission') || msg.contains('denied') || msg.contains('policy')
        ? 'Нет доступа к балансам. Проверьте RLS-политики Supabase и авторизацию.'
        : msg;
    emit(state.copyWith(
      accountBalances: const {},
      balanceStreamError: short,
    ));
  }

  void _onPendingTransfersUpdated(
    _PendingTransfersUpdated event,
    Emitter<DashboardState> emit,
  ) {
    emit(state.copyWith(pendingTransfers: event.transfers));
  }

  Future<void> _onBranchSelected(
    DashboardBranchSelected event,
    Emitter<DashboardState> emit,
  ) async {
    emit(state.copyWith(selectedBranchId: event.branchId));
    await _loadBranchDetails(event.branchId, emit);
  }

  Future<void> _onRefreshRequested(
    DashboardRefreshRequested event,
    Emitter<DashboardState> emit,
  ) async {
    add(const DashboardStarted());
  }

  Future<void> _loadBranchDetails(
    String branchId,
    Emitter<DashboardState> emit,
  ) async {
    await emit.forEach(
      _branchRepository.watchBranchAccounts(branchId),
      onData: (accounts) {
        final updatedAccounts =
            Map<String, List<BranchAccount>>.from(state.branchAccounts);
        updatedAccounts[branchId] = accounts;
        return state.copyWith(branchAccounts: updatedAccounts);
      },
      onError: (error, _) => state,
    );
  }

  void _onAccountsLoaded(
    _AccountsLoaded event,
    Emitter<DashboardState> emit,
  ) {
    emit(state.copyWith(branchAccounts: event.accounts));
  }

  void _loadAccountsForBranches(List<Branch> branches) {
    if (branches.isEmpty) {
      add(_AccountsLoaded(<String, List<BranchAccount>>{}));
      return;
    }
    Future.wait(
      branches.map((b) => _branchRepository.watchBranchAccounts(b.id).first),
    ).then((accountLists) {
      if (isClosed) return;
      final updated = <String, List<BranchAccount>>{};
      for (var i = 0; i < branches.length; i++) {
        updated[branches[i].id] = accountLists[i];
      }
      add(_AccountsLoaded(updated));
    });
  }

  @override
  Future<void> close() {
    _balancesSub?.cancel();
    _pendingTransfersSub?.cancel();
    return super.close();
  }
}

class _AccountsLoaded extends DashboardEvent {
  final Map<String, List<BranchAccount>> accounts;
  const _AccountsLoaded(this.accounts);
  @override
  List<Object?> get props => [accounts];
}
