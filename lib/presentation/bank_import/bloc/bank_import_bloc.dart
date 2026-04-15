import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/bank_transaction.dart';
import 'package:ethnocount/domain/services/bank_import_service.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';

// ─── Events ───

abstract class BankImportEvent extends Equatable {
  const BankImportEvent();
  @override
  List<Object?> get props => [];
}

class BankImportFilePicked extends BankImportEvent {
  final String path;
  final List<int> bytes;
  final String? bankName;
  const BankImportFilePicked(this.path, this.bytes, {this.bankName});
  @override
  List<Object?> get props => [path, bankName];
}

class BankImportReset extends BankImportEvent {
  const BankImportReset();
}

class BankImportExecute extends BankImportEvent {
  final String branchId;
  final String accountId;
  final String createdBy;
  final String? category;
  const BankImportExecute({
    required this.branchId,
    required this.accountId,
    required this.createdBy,
    this.category,
  });
  @override
  List<Object?> get props => [branchId, accountId, createdBy, category];
}

// ─── State ───

enum BankImportStatus { initial, parsed, importing, success, error }

class BankImportState extends Equatable {
  final BankImportStatus status;
  final List<BankTransaction> transactions;
  final String? errorMessage;
  final int? importedCount;

  const BankImportState({
    this.status = BankImportStatus.initial,
    this.transactions = const [],
    this.errorMessage,
    this.importedCount,
  });

  @override
  List<Object?> get props => [status, transactions.length, errorMessage, importedCount];
}

class BankImportBloc extends Bloc<BankImportEvent, BankImportState> {
  final BankImportService _importService;
  final LedgerRemoteDataSource _ledgerDs;

  BankImportBloc({
    required BankImportService importService,
    required LedgerRemoteDataSource ledgerDs,
  })  : _importService = importService,
        _ledgerDs = ledgerDs,
        super(const BankImportState()) {
    on<BankImportFilePicked>(_onFilePicked);
    on<BankImportReset>(_onReset);
    on<BankImportExecute>(_onExecute);
  }

  void _onFilePicked(BankImportFilePicked event, Emitter<BankImportState> emit) async {
    emit(const BankImportState(status: BankImportStatus.initial));
    List<BankTransaction> transactions;
    final ext = event.path.toLowerCase();
    if (ext.endsWith('.csv')) {
      final text = String.fromCharCodes(event.bytes);
      transactions = _importService.parseCsv(text, bankName: event.bankName);
    } else if (ext.endsWith('.xlsx') || ext.endsWith('.xls')) {
      transactions = _importService.parseExcel(event.bytes, bankName: event.bankName);
    } else {
      emit(BankImportState(
        status: BankImportStatus.error,
        errorMessage: 'Поддерживаются только CSV и Excel (.xlsx, .xls)',
      ));
      return;
    }

    if (transactions.isEmpty) {
      emit(BankImportState(
        status: BankImportStatus.error,
        errorMessage: 'Не удалось распознать операции. Проверьте формат файла.',
      ));
      return;
    }

    emit(BankImportState(status: BankImportStatus.parsed, transactions: transactions));
  }

  void _onReset(BankImportReset event, Emitter<BankImportState> emit) {
    emit(const BankImportState());
  }

  void _onExecute(BankImportExecute event, Emitter<BankImportState> emit) async {
    if (state.transactions.isEmpty) return;
    emit(state.copyWith(status: BankImportStatus.importing));

    try {
      final count = await _ledgerDs.importBankTransactions(
        branchId: event.branchId,
        accountId: event.accountId,
        transactions: state.transactions,
        createdBy: event.createdBy,
        categoryPrefix: event.category,
      );
      emit(BankImportState(
        status: BankImportStatus.success,
        transactions: state.transactions,
        importedCount: count,
      ));
    } catch (e) {
      emit(BankImportState(
        status: BankImportStatus.error,
        transactions: state.transactions,
        errorMessage: e.toString(),
      ));
    }
  }
}

extension _BankImportStateX on BankImportState {
  BankImportState copyWith({
    BankImportStatus? status,
    List<BankTransaction>? transactions,
    String? errorMessage,
    int? importedCount,
  }) {
    return BankImportState(
      status: status ?? this.status,
      transactions: transactions ?? this.transactions,
      errorMessage: errorMessage ?? this.errorMessage,
      importedCount: importedCount ?? this.importedCount,
    );
  }
}
