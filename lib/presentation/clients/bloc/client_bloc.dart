import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/client.dart';
import 'package:ethnocount/domain/repositories/client_repository.dart';

// ─── Events ───

abstract class ClientEvent extends Equatable {
  const ClientEvent();
  @override
  List<Object?> get props => [];
}

class ClientsLoadRequested extends ClientEvent {
  const ClientsLoadRequested();
}

class ClientCreateRequested extends ClientEvent {
  final String name;
  final String phone;
  final String country;
  final String currency;
  final String branchId;

  const ClientCreateRequested({
    required this.name,
    required this.phone,
    required this.country,
    required this.currency,
    required this.branchId,
  });

  @override
  List<Object?> get props => [name, phone, country, currency, branchId];
}

class ClientDepositRequested extends ClientEvent {
  final String clientId;
  final double amount;
  final String? description;
  final String? currency;

  const ClientDepositRequested({
    required this.clientId,
    required this.amount,
    this.description,
    this.currency,
  });

  @override
  List<Object?> get props => [clientId, amount, currency];
}

class ClientDebitRequested extends ClientEvent {
  final String clientId;
  final double amount;
  final String? description;
  final String? currency;

  const ClientDebitRequested({
    required this.clientId,
    required this.amount,
    this.description,
    this.currency,
  });

  @override
  List<Object?> get props => [clientId, amount, currency];
}

class ClientDetailRequested extends ClientEvent {
  final String clientId;
  const ClientDetailRequested(this.clientId);
  @override
  List<Object?> get props => [clientId];
}

/// Internal: pushed by the all-balances watcher each time the
/// `client_balances` table changes.
class _ClientBalancesUpdated extends ClientEvent {
  final List<ClientBalance> balances;
  const _ClientBalancesUpdated(this.balances);
  @override
  List<Object?> get props => [balances];
}

// ─── State ───

enum ClientBlocStatus { initial, loading, loaded, operating, success, error }

class ClientBlocState extends Equatable {
  final ClientBlocStatus status;
  final List<Client> clients;

  /// Map clientId → balance, used by the list to render per-client balances.
  final Map<String, ClientBalance> balancesByClientId;
  final Client? selectedClient;
  final ClientBalance? selectedBalance;
  final List<ClientTransaction> transactions;
  final String? errorMessage;
  final String? successMessage;

  const ClientBlocState({
    this.status = ClientBlocStatus.initial,
    this.clients = const [],
    this.balancesByClientId = const {},
    this.selectedClient,
    this.selectedBalance,
    this.transactions = const [],
    this.errorMessage,
    this.successMessage,
  });

  ClientBlocState copyWith({
    ClientBlocStatus? status,
    List<Client>? clients,
    Map<String, ClientBalance>? balancesByClientId,
    Client? selectedClient,
    ClientBalance? selectedBalance,
    List<ClientTransaction>? transactions,
    String? errorMessage,
    String? successMessage,
  }) {
    return ClientBlocState(
      status: status ?? this.status,
      clients: clients ?? this.clients,
      balancesByClientId: balancesByClientId ?? this.balancesByClientId,
      selectedClient: selectedClient ?? this.selectedClient,
      selectedBalance: selectedBalance ?? this.selectedBalance,
      transactions: transactions ?? this.transactions,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  @override
  List<Object?> get props => [
        status,
        clients,
        balancesByClientId,
        selectedClient,
        selectedBalance,
        transactions,
        errorMessage,
        successMessage,
      ];
}

// ─── BLoC ───

class ClientBloc extends Bloc<ClientEvent, ClientBlocState> {
  final ClientRepository _repository;
  StreamSubscription<List<Client>>? _clientsSub;
  StreamSubscription<List<ClientTransaction>>? _txSub;
  StreamSubscription<List<ClientBalance>>? _balancesSub;

  ClientBloc({required ClientRepository repository})
      : _repository = repository,
        super(const ClientBlocState()) {
    on<ClientsLoadRequested>(_onLoad);
    on<ClientCreateRequested>(_onCreate);
    on<ClientDepositRequested>(_onDeposit);
    on<ClientDebitRequested>(_onDebit);
    on<ClientDetailRequested>(_onDetail);
    on<_ClientBalancesUpdated>(_onBalancesUpdated);
  }

  Future<void> _onLoad(
    ClientsLoadRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.loading));

    // Side-channel: keep all balances in sync via a private event so the
    // list rows can show per-client amounts.
    await _balancesSub?.cancel();
    _balancesSub = _repository.watchAllClientBalances().listen(
      (balances) => add(_ClientBalancesUpdated(balances)),
      onError: (_) {/* keep last known balances on error */},
    );

    await emit.forEach(
      _repository.watchClients(),
      onData: (clients) =>
          state.copyWith(status: ClientBlocStatus.loaded, clients: clients),
      onError: (error, _) => state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  void _onBalancesUpdated(
    _ClientBalancesUpdated event,
    Emitter<ClientBlocState> emit,
  ) {
    final map = <String, ClientBalance>{
      for (final b in event.balances) b.clientId: b,
    };
    emit(state.copyWith(balancesByClientId: map));
  }

  Future<void> _onCreate(
    ClientCreateRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.createClient(
      name: event.name,
      phone: event.phone,
      country: event.country,
      currency: event.currency,
      branchId: event.branchId,
    );
    result.fold(
      (f) => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: ClientBlocStatus.success,
        successMessage: 'Клиент успешно создан',
      )),
    );
  }

  Future<void> _onDeposit(
    ClientDepositRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.depositClient(
      clientId: event.clientId,
      amount: event.amount,
      description: event.description,
      currency: event.currency,
    );
    await result.fold(
      (f) async => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) async {
        final balanceResult = await _repository.getClientBalance(event.clientId);
        final newBalance = balanceResult.fold((_) => null, (b) => b);
        emit(state.copyWith(
          status: ClientBlocStatus.success,
          successMessage: 'Пополнение выполнено',
          selectedBalance: newBalance ?? state.selectedBalance,
        ));
      },
    );
  }

  Future<void> _onDebit(
    ClientDebitRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.debitClient(
      clientId: event.clientId,
      amount: event.amount,
      description: event.description,
      currency: event.currency,
    );
    await result.fold(
      (f) async => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) async {
        final balanceResult = await _repository.getClientBalance(event.clientId);
        final newBalance = balanceResult.fold((_) => null, (b) => b);
        emit(state.copyWith(
          status: ClientBlocStatus.success,
          successMessage: 'Списание выполнено',
          selectedBalance: newBalance ?? state.selectedBalance,
        ));
      },
    );
  }

  Future<void> _onDetail(
    ClientDetailRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.loading));
    final clientResult = await _repository.getClient(event.clientId);
    final balanceResult = await _repository.getClientBalance(event.clientId);

    Client? client;
    ClientBalance? balance;

    clientResult.fold((f) => null, (c) => client = c);
    balanceResult.fold((f) => null, (b) => balance = b);

    if (client == null) {
      emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: 'Клиент не найден',
      ));
      return;
    }

    await _txSub?.cancel();
    await emit.forEach(
      _repository.watchClientTransactions(event.clientId),
      onData: (txs) => state.copyWith(
        status: ClientBlocStatus.loaded,
        selectedClient: client,
        selectedBalance: state.selectedBalance ?? balance,
        transactions: txs,
      ),
      onError: (error, _) => state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: error.toString(),
      ),
    );
  }

  @override
  Future<void> close() {
    _clientsSub?.cancel();
    _txSub?.cancel();
    _balancesSub?.cancel();
    return super.close();
  }
}
