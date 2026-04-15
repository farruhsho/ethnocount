import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ethnocount/data/datasources/remote/analytics_remote_ds.dart';

// ─── Events ───

abstract class AnalyticsEvent extends Equatable {
  const AnalyticsEvent();
  @override
  List<Object?> get props => [];
}

class AnalyticsLoadRequested extends AnalyticsEvent {
  final String scope;
  final bool excludeCounterpartyAccounts;
  const AnalyticsLoadRequested({
    this.scope = 'full',
    this.excludeCounterpartyAccounts = false,
  });
  @override
  List<Object?> get props => [scope, excludeCounterpartyAccounts];
}

// ─── State ───

class AnalyticsBlocState extends Equatable {
  final bool isLoading;
  final String? errorMessage;
  final bool excludeCounterpartyAccounts;
  final List<BranchAnalyticsModel> branches;
  final TransferAnalyticsModel? transfers;
  final List<CurrencyAnalyticsModel> currencies;
  final TreasuryOverviewModel? treasury;
  final String? generatedAt;

  const AnalyticsBlocState({
    this.isLoading = false,
    this.errorMessage,
    this.excludeCounterpartyAccounts = false,
    this.branches = const [],
    this.transfers,
    this.currencies = const [],
    this.treasury,
    this.generatedAt,
  });

  AnalyticsBlocState copyWith({
    bool? isLoading,
    String? errorMessage,
    bool? excludeCounterpartyAccounts,
    List<BranchAnalyticsModel>? branches,
    TransferAnalyticsModel? transfers,
    List<CurrencyAnalyticsModel>? currencies,
    TreasuryOverviewModel? treasury,
    String? generatedAt,
  }) {
    return AnalyticsBlocState(
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      excludeCounterpartyAccounts:
          excludeCounterpartyAccounts ?? this.excludeCounterpartyAccounts,
      branches: branches ?? this.branches,
      transfers: transfers ?? this.transfers,
      currencies: currencies ?? this.currencies,
      treasury: treasury ?? this.treasury,
      generatedAt: generatedAt ?? this.generatedAt,
    );
  }

  @override
  List<Object?> get props =>
      [isLoading, errorMessage, excludeCounterpartyAccounts, branches, transfers, currencies, treasury, generatedAt];
}

// ─── Models ───

class BranchAnalyticsModel {
  final String branchId;
  final String branchName;
  final double totalBalance;
  /// Per-currency balances from CF / Firestore; may be empty for legacy payloads.
  final Map<String, double> balancesByCurrency;
  final Map<String, dynamic> accounts;
  final int pendingTransfersCount;
  final int confirmedTransfersCount;
  final double totalCommissions;
  final Map<String, dynamic> monthlySummary;

  const BranchAnalyticsModel({
    required this.branchId,
    required this.branchName,
    required this.totalBalance,
    required this.balancesByCurrency,
    required this.accounts,
    required this.pendingTransfersCount,
    required this.confirmedTransfersCount,
    required this.totalCommissions,
    required this.monthlySummary,
  });

  factory BranchAnalyticsModel.fromMap(Map<String, dynamic> m) {
    final accounts = Map<String, dynamic>.from(m['accounts'] ?? {});
    final balancesByCurrency = <String, double>{};
    final rawBal = m['balancesByCurrency'];
    if (rawBal is Map) {
      rawBal.forEach((k, v) {
        balancesByCurrency[k.toString()] = (v as num).toDouble();
      });
    }

    return BranchAnalyticsModel(
      branchId: m['branchId'] ?? '',
      branchName: m['branchName'] ?? '',
      totalBalance: (m['totalBalance'] ?? 0).toDouble(),
      balancesByCurrency: balancesByCurrency,
      accounts: accounts,
      pendingTransfersCount: (m['pendingTransfersCount'] ?? 0).toInt(),
      confirmedTransfersCount: (m['confirmedTransfersCount'] ?? 0).toInt(),
      totalCommissions: (m['totalCommissions'] ?? 0).toDouble(),
      monthlySummary: Map<String, dynamic>.from(m['monthlySummary'] ?? {}),
    );
  }
}

class TransferAnalyticsModel {
  final double totalVolume;
  final Map<String, double> volumeByCurrency;
  final int totalCount;
  final int pendingCount;
  final int confirmedCount;
  final int issuedCount;
  final int rejectedCount;
  final int cancelledCount;
  final double totalCommissions;
  final int avgProcessingMs;

  const TransferAnalyticsModel({
    required this.totalVolume,
    required this.volumeByCurrency,
    required this.totalCount,
    required this.pendingCount,
    required this.confirmedCount,
    required this.issuedCount,
    required this.rejectedCount,
    required this.cancelledCount,
    required this.totalCommissions,
    required this.avgProcessingMs,
  });

  factory TransferAnalyticsModel.fromMap(Map<String, dynamic> m) {
    final volByCur = <String, double>{};
    final rawVol = m['volumeByCurrency'];
    if (rawVol is Map) {
      rawVol.forEach((k, v) {
        volByCur[k.toString()] = (v as num).toDouble();
      });
    }

    return TransferAnalyticsModel(
      totalVolume: (m['totalVolume'] ?? 0).toDouble(),
      volumeByCurrency: volByCur,
      totalCount: (m['totalCount'] ?? 0).toInt(),
      pendingCount: (m['pendingCount'] ?? 0).toInt(),
      confirmedCount: (m['confirmedCount'] ?? 0).toInt(),
      issuedCount: (m['issuedCount'] ?? 0).toInt(),
      rejectedCount: (m['rejectedCount'] ?? 0).toInt(),
      cancelledCount: (m['cancelledCount'] ?? 0).toInt(),
      totalCommissions: (m['totalCommissions'] ?? 0).toDouble(),
      avgProcessingMs: (m['avgProcessingMs'] ?? 0).toInt(),
    );
  }

  String get avgProcessingFormatted {
    final mins = avgProcessingMs ~/ 60000;
    if (mins < 60) return '$mins мин';
    return '${mins ~/ 60} ч ${mins % 60} мин';
  }
}

class CurrencyAnalyticsModel {
  final String pair;
  final double latestRate;
  final List<Map<String, dynamic>> rateHistory;
  final double conversionVolume;

  const CurrencyAnalyticsModel({
    required this.pair,
    required this.latestRate,
    required this.rateHistory,
    required this.conversionVolume,
  });

  factory CurrencyAnalyticsModel.fromMap(Map<String, dynamic> m) {
    return CurrencyAnalyticsModel(
      pair: m['pair'] ?? '',
      latestRate: (m['latestRate'] ?? 0).toDouble(),
      rateHistory: (m['rateHistory'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
      conversionVolume: (m['conversionVolume'] ?? 0).toDouble(),
    );
  }
}

class TreasuryOverviewModel {
  final Map<String, double> totalLiquidity;
  final Map<String, Map<String, double>> capitalByBranchByCurrency;
  final Map<String, double> pendingLockedByCurrency;
  final List<Map<String, dynamic>> largeTransfers;

  const TreasuryOverviewModel({
    required this.totalLiquidity,
    required this.capitalByBranchByCurrency,
    required this.pendingLockedByCurrency,
    required this.largeTransfers,
  });

  factory TreasuryOverviewModel.fromMap(Map<String, dynamic> m) {
    final liquidity = <String, double>{};
    final rawLiq = Map<String, dynamic>.from(m['totalLiquidity'] ?? {});
    rawLiq.forEach((k, v) => liquidity[k] = (v as num).toDouble());

    final capitalByBranchByCurrency = <String, Map<String, double>>{};
    final rawNested = m['capitalByBranchByCurrency'];
    if (rawNested is Map) {
      rawNested.forEach((bid, inner) {
        if (inner is! Map) return;
        final byCur = <String, double>{};
        inner.forEach((c, amt) {
          byCur[c.toString()] = (amt as num).toDouble();
        });
        capitalByBranchByCurrency[bid.toString()] = byCur;
      });
    }
    if (capitalByBranchByCurrency.isEmpty) {
      final rawCap = Map<String, dynamic>.from(m['capitalByBranch'] ?? {});
      rawCap.forEach((k, v) {
        capitalByBranchByCurrency[k.toString()] = {
          '\u2014': (v as num).toDouble(),
        };
      });
    }

    final pendingLockedByCurrency = <String, double>{};
    final rawPending = m['pendingLockedByCurrency'];
    if (rawPending is Map) {
      rawPending.forEach((k, v) {
        pendingLockedByCurrency[k.toString()] = (v as num).toDouble();
      });
    }
    if (pendingLockedByCurrency.isEmpty &&
        m['pendingLocked'] != null) {
      pendingLockedByCurrency['\u2014'] =
          (m['pendingLocked'] as num).toDouble();
    }

    return TreasuryOverviewModel(
      totalLiquidity: liquidity,
      capitalByBranchByCurrency: capitalByBranchByCurrency,
      pendingLockedByCurrency: pendingLockedByCurrency,
      largeTransfers: (m['largeTransfers'] as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList() ??
          [],
    );
  }
}

// ─── BLoC ───

class AnalyticsBloc extends Bloc<AnalyticsEvent, AnalyticsBlocState> {
  final AnalyticsRemoteDataSource _remote;

  AnalyticsBloc({required AnalyticsRemoteDataSource remote})
      : _remote = remote,
        super(const AnalyticsBlocState()) {
    on<AnalyticsLoadRequested>(_onLoad);
  }

  Future<void> _onLoad(
      AnalyticsLoadRequested event, Emitter<AnalyticsBlocState> emit) async {
    emit(state.copyWith(
      isLoading: true,
      errorMessage: null,
      excludeCounterpartyAccounts: event.excludeCounterpartyAccounts,
    ));

    try {
      final data = await _remote.fetchAnalytics(
        scope: event.scope,
        excludeCounterpartyAccounts: event.excludeCounterpartyAccounts,
      );

      final branches = (data['branches'] as List?)
              ?.map((e) => BranchAnalyticsModel.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          [];

      final transfers = data['transfers'] != null
          ? TransferAnalyticsModel.fromMap(Map<String, dynamic>.from(data['transfers'] as Map))
          : null;

      final currencies = (data['currency'] as List?)
              ?.map((e) => CurrencyAnalyticsModel.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList() ??
          [];

      final treasury = data['treasury'] != null
          ? TreasuryOverviewModel.fromMap(Map<String, dynamic>.from(data['treasury'] as Map))
          : null;

      emit(state.copyWith(
        isLoading: false,
        excludeCounterpartyAccounts: event.excludeCounterpartyAccounts,
        branches: branches,
        transfers: transfers,
        currencies: currencies,
        treasury: treasury,
        generatedAt: DateTime.now().toIso8601String(),
      ));
    } catch (e) {
      emit(state.copyWith(
        isLoading: false,
        errorMessage: 'Ошибка загрузки аналитики: $e',
      ));
    }
  }
}
