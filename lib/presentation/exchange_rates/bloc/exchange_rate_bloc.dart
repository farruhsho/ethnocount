import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/domain/entities/exchange_rate.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';

// ─── Events ───

abstract class ExchangeRateEvent extends Equatable {
  const ExchangeRateEvent();
  @override
  List<Object?> get props => [];
}

class ExchangeRateLoadRequested extends ExchangeRateEvent {
  final String? fromCurrency;
  final String? toCurrency;
  const ExchangeRateLoadRequested({this.fromCurrency, this.toCurrency});
  @override
  List<Object?> get props => [fromCurrency, toCurrency];
}

class ExchangeRateSetRequested extends ExchangeRateEvent {
  final String fromCurrency;
  final String toCurrency;
  final double rate;
  const ExchangeRateSetRequested({
    required this.fromCurrency,
    required this.toCurrency,
    required this.rate,
  });
  @override
  List<Object?> get props => [fromCurrency, toCurrency, rate];
}

class _RatesUpdated extends ExchangeRateEvent {
  final List<ExchangeRate> rates;
  const _RatesUpdated(this.rates);
}

class ExchangeRateCurrenciesRequested extends ExchangeRateEvent {
  const ExchangeRateCurrenciesRequested();
}

// ─── State ───

class ExchangeRateBlocState extends Equatable {
  final List<ExchangeRate> rates;
  final List<String> currencies;
  final bool isLoading;
  final bool isSubmitting;
  final String? errorMessage;
  final String? successMessage;

  const ExchangeRateBlocState({
    this.rates = const [],
    this.currencies = const [],
    this.isLoading = false,
    this.isSubmitting = false,
    this.errorMessage,
    this.successMessage,
  });

  ExchangeRateBlocState copyWith({
    List<ExchangeRate>? rates,
    List<String>? currencies,
    bool? isLoading,
    bool? isSubmitting,
    String? errorMessage,
    String? successMessage,
  }) {
    return ExchangeRateBlocState(
      rates: rates ?? this.rates,
      currencies: currencies ?? this.currencies,
      isLoading: isLoading ?? this.isLoading,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }

  @override
  List<Object?> get props =>
      [rates, currencies, isLoading, isSubmitting, errorMessage, successMessage];
}

// ─── BLoC ───

class ExchangeRateBloc extends Bloc<ExchangeRateEvent, ExchangeRateBlocState> {
  final ExchangeRateRepository _repository;
  StreamSubscription<List<ExchangeRate>>? _ratesSub;

  ExchangeRateBloc({required ExchangeRateRepository repository})
      : _repository = repository,
        super(const ExchangeRateBlocState()) {
    on<ExchangeRateLoadRequested>(_onLoad);
    on<_RatesUpdated>(_onRatesUpdated);
    on<ExchangeRateSetRequested>(_onSetRate);
    on<ExchangeRateCurrenciesRequested>(_onLoadCurrencies);
  }

  void _onLoad(ExchangeRateLoadRequested event, Emitter<ExchangeRateBlocState> emit) {
    emit(state.copyWith(isLoading: true));

    _ratesSub?.cancel();
    _ratesSub = _repository
        .watchRates(
          fromCurrency: event.fromCurrency,
          toCurrency: event.toCurrency,
        )
        .listen(
          (rates) => add(_RatesUpdated(rates)),
          onError: (e) => add(const _RatesUpdated([])),
        );
  }

  void _onRatesUpdated(_RatesUpdated event, Emitter<ExchangeRateBlocState> emit) {
    emit(state.copyWith(rates: event.rates, isLoading: false));
  }

  Future<void> _onSetRate(
      ExchangeRateSetRequested event, Emitter<ExchangeRateBlocState> emit) async {
    emit(state.copyWith(isSubmitting: true, errorMessage: null, successMessage: null));

    final result = await _repository.setRate(
      fromCurrency: event.fromCurrency,
      toCurrency: event.toCurrency,
      rate: event.rate,
    );

    result.fold(
      (failure) => emit(state.copyWith(
        isSubmitting: false,
        errorMessage: failure.message,
      )),
      (data) => emit(state.copyWith(
        isSubmitting: false,
        successMessage:
            'Курс ${event.fromCurrency}/${event.toCurrency} = ${event.rate} установлен',
      )),
    );
  }

  Future<void> _onLoadCurrencies(
      ExchangeRateCurrenciesRequested event, Emitter<ExchangeRateBlocState> emit) async {
    final result = await _repository.getAvailableCurrencies();
    result.fold(
      (failure) => emit(state.copyWith(errorMessage: failure.message)),
      (list) => emit(state.copyWith(currencies: list)),
    );
  }

  @override
  Future<void> close() {
    _ratesSub?.cancel();
    return super.close();
  }
}
