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

class ClientConvertRequested extends ClientEvent {
  final String clientId;
  final String fromCurrency;
  final String toCurrency;
  final double amount;
  final double rate;
  final String? description;

  const ClientConvertRequested({
    required this.clientId,
    required this.fromCurrency,
    required this.toCurrency,
    required this.amount,
    required this.rate,
    this.description,
  });

  @override
  List<Object?> get props =>
      [clientId, fromCurrency, toCurrency, amount, rate, description];
}

class ClientDetailRequested extends ClientEvent {
  final String clientId;
  const ClientDetailRequested(this.clientId);
  @override
  List<Object?> get props => [clientId];
}

class ClientTelegramChatIdUpdated extends ClientEvent {
  final String clientId;
  final String? chatId;
  const ClientTelegramChatIdUpdated({
    required this.clientId,
    required this.chatId,
  });
  @override
  List<Object?> get props => [clientId, chatId];
}

class ClientTelegramTestRequested extends ClientEvent {
  final String clientId;
  const ClientTelegramTestRequested(this.clientId);
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
    on<ClientConvertRequested>(_onConvert);
    on<ClientDetailRequested>(_onDetail);
    on<ClientTelegramChatIdUpdated>(_onTelegramChatIdUpdated);
    on<ClientTelegramTestRequested>(_onTelegramTestRequested);
    on<_ClientBalancesUpdated>(_onBalancesUpdated);
  }

  Future<void> _onTelegramChatIdUpdated(
    ClientTelegramChatIdUpdated event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.setTelegramChatId(
      clientId: event.clientId,
      chatId: event.chatId,
    );
    await result.fold(
      (f) async => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) async {
        // Перечитать клиента, чтобы обновлённый telegram_chat_id отразился
        // в карточке и в списке без ожидания realtime broadcast.
        final fresh = await _repository.getClient(event.clientId);
        Client? updated;
        fresh.fold((_) => null, (c) => updated = c);

        Client? newSelected = state.selectedClient;
        List<Client> newList = state.clients;
        if (updated != null) {
          if (state.selectedClient?.id == event.clientId) {
            newSelected = updated;
          }
          newList = state.clients
              .map((c) => c.id == event.clientId ? updated! : c)
              .toList();
        }

        emit(state.copyWith(
          status: ClientBlocStatus.success,
          successMessage: (event.chatId == null || event.chatId!.isEmpty)
              ? 'Telegram-группа отвязана'
              : 'Telegram-группа сохранена',
          selectedClient: newSelected,
          clients: newList,
        ));
      },
    );
  }

  Future<void> _onTelegramTestRequested(
    ClientTelegramTestRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.sendTelegramTest(clientId: event.clientId);
    result.fold(
      (f) => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (_) => emit(state.copyWith(
        status: ClientBlocStatus.success,
        successMessage: 'Тестовое сообщение отправлено',
      )),
    );
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
      (_) async => _emitWithRefreshedBalance(
        emit, event.clientId, 'Пополнение выполнено',
      ),
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
      (_) async => _emitWithRefreshedBalance(
        emit, event.clientId, 'Списание выполнено',
      ),
    );
  }

  Future<void> _onConvert(
    ClientConvertRequested event,
    Emitter<ClientBlocState> emit,
  ) async {
    emit(state.copyWith(status: ClientBlocStatus.operating));
    final result = await _repository.convertClientCurrency(
      clientId: event.clientId,
      fromCurrency: event.fromCurrency,
      toCurrency: event.toCurrency,
      amount: event.amount,
      rate: event.rate,
      description: event.description,
    );
    await result.fold(
      (f) async => emit(state.copyWith(
        status: ClientBlocStatus.error,
        errorMessage: f.message,
      )),
      (r) async => _emitWithRefreshedBalance(
        emit,
        event.clientId,
        'Конвертация ${r.fromCurrency} → ${r.toCurrency} выполнена',
      ),
    );
  }

  /// Перечитывает баланс клиента и публикует его сразу в двух местах:
  ///   * `selectedBalance` — для правой панели,
  ///   * `balancesByClientId[clientId]` — для строки в таблице/списке.
  /// Без этого пользователю приходилось перезаходить в карточку, чтобы
  /// увидеть свежий баланс — realtime-канал догоняет с задержкой.
  Future<void> _emitWithRefreshedBalance(
    Emitter<ClientBlocState> emit,
    String clientId,
    String successMessage,
  ) async {
    final balanceResult = await _repository.getClientBalance(clientId);
    final newBalance = balanceResult.fold((_) => null, (b) => b);

    final updatedMap = Map<String, ClientBalance>.from(state.balancesByClientId);
    if (newBalance != null) {
      updatedMap[clientId] = newBalance;
    }

    emit(state.copyWith(
      status: ClientBlocStatus.success,
      successMessage: successMessage,
      selectedBalance: state.selectedClient?.id == clientId
          ? (newBalance ?? state.selectedBalance)
          : state.selectedBalance,
      balancesByClientId: updatedMap,
    ));
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
