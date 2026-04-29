import 'package:get_it/get_it.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ethnocount/core/network/connectivity_service.dart';

// ─── Services ───
import 'package:ethnocount/core/services/credential_storage_service.dart';
import 'package:ethnocount/core/services/session_service.dart';
import 'package:ethnocount/core/services/grid_column_preferences_service.dart';
import 'package:ethnocount/core/services/fcm_service.dart';
import 'package:ethnocount/core/services/notification_fx_service.dart';

// ─── Data Sources ───
import 'package:ethnocount/data/datasources/remote/auth_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/system_settings_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_session_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/branch_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/transfer_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/ledger_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/notification_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/audit_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/exchange_rate_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/analytics_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/client_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/user_remote_ds.dart';
import 'package:ethnocount/data/datasources/remote/purchase_remote_ds.dart';

// ─── Repositories (interface) ───
import 'package:ethnocount/domain/repositories/auth_repository.dart';
import 'package:ethnocount/domain/repositories/branch_repository.dart';
import 'package:ethnocount/domain/repositories/transfer_repository.dart';
import 'package:ethnocount/domain/repositories/ledger_repository.dart';
import 'package:ethnocount/domain/repositories/notification_repository.dart';
import 'package:ethnocount/domain/repositories/audit_repository.dart';
import 'package:ethnocount/domain/repositories/exchange_rate_repository.dart';
import 'package:ethnocount/domain/repositories/client_repository.dart';
import 'package:ethnocount/domain/repositories/purchase_repository.dart';

// ─── Repositories (implementation) ───
import 'package:ethnocount/data/repositories/auth_repo_impl.dart';
import 'package:ethnocount/data/repositories/branch_repo_impl.dart';
import 'package:ethnocount/data/repositories/transfer_repo_impl.dart';
import 'package:ethnocount/data/repositories/ledger_repo_impl.dart';
import 'package:ethnocount/data/repositories/notification_repo_impl.dart';
import 'package:ethnocount/data/repositories/audit_repo_impl.dart';
import 'package:ethnocount/data/repositories/exchange_rate_repo_impl.dart';
import 'package:ethnocount/data/repositories/client_repo_impl.dart';
import 'package:ethnocount/data/repositories/purchase_repo_impl.dart';

// ─── Services ───
import 'package:ethnocount/domain/services/server_export_service.dart';
import 'package:ethnocount/domain/services/ledger_export_service.dart';
import 'package:ethnocount/domain/services/transfer_invoice_service.dart';
import 'package:ethnocount/domain/services/bank_import_service.dart';
import 'package:ethnocount/domain/services/bank_api_registry.dart';
import 'package:ethnocount/data/services/sberbank_api_provider.dart';

// ─── Use Cases ───
import 'package:ethnocount/domain/usecases/auth/sign_in.dart';
import 'package:ethnocount/domain/usecases/transfer/create_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/confirm_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/issue_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/issue_partial_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/reject_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/update_transfer.dart';
import 'package:ethnocount/domain/usecases/transfer/watch_transfers.dart';
import 'package:ethnocount/domain/usecases/branch/watch_branches.dart';
import 'package:ethnocount/domain/usecases/branch/get_account_balance.dart';
import 'package:ethnocount/domain/usecases/ledger/watch_ledger.dart';
import 'package:ethnocount/domain/usecases/notification/watch_notifications.dart';

// ─── BLoCs ───
import 'package:ethnocount/presentation/auth/bloc/auth_bloc.dart';
import 'package:ethnocount/presentation/dashboard/bloc/dashboard_bloc.dart';
import 'package:ethnocount/presentation/transfers/bloc/transfer_bloc.dart';
import 'package:ethnocount/presentation/ledger/bloc/ledger_bloc.dart';
import 'package:ethnocount/presentation/notifications/bloc/notification_bloc.dart';
import 'package:ethnocount/presentation/exchange_rates/bloc/exchange_rate_bloc.dart';
import 'package:ethnocount/presentation/analytics/bloc/analytics_bloc.dart';
import 'package:ethnocount/presentation/clients/bloc/client_bloc.dart';
import 'package:ethnocount/presentation/purchases/bloc/purchase_bloc.dart';
import 'package:ethnocount/presentation/bank_import/bloc/bank_import_bloc.dart';

final sl = GetIt.instance;

/// Initialize all dependencies.
Future<void> initDependencies() async {
  // ─── External: Supabase Client ───
  final supabase = Supabase.instance.client;
  sl.registerLazySingleton<SupabaseClient>(() => supabase);

  // ─── Services ───
  sl.registerLazySingleton(() => CredentialStorageService());
  sl.registerLazySingleton(() => SessionService());
  sl.registerLazySingleton(() => GridColumnPreferencesService());
  sl.registerLazySingleton(() => FcmService(sl()));
  sl.registerLazySingleton(() => NotificationFxService());
  sl.registerLazySingleton(() => ConnectivityService());

  // ─── Data Sources (all take SupabaseClient) ───
  sl.registerLazySingleton(() => AuthRemoteDataSource(supabase));
  sl.registerLazySingleton(() => SystemSettingsRemoteDataSource(supabase));
  sl.registerLazySingleton(() => UserSessionRemoteDataSource(supabase));
  sl.registerLazySingleton(() => BranchRemoteDataSource(supabase));
  sl.registerLazySingleton(() => TransferRemoteDataSource(supabase));
  sl.registerLazySingleton(() => LedgerRemoteDataSource(supabase));
  sl.registerLazySingleton(() => NotificationRemoteDataSource(supabase));
  sl.registerLazySingleton(() => AuditRemoteDataSource(supabase));
  sl.registerLazySingleton(() => ExchangeRateRemoteDataSource(supabase));
  sl.registerLazySingleton(() => AnalyticsRemoteDataSource(supabase));
  sl.registerLazySingleton(() => ClientRemoteDataSource(supabase));
  sl.registerLazySingleton(() => UserRemoteDataSource(supabase));
  sl.registerLazySingleton(() => PurchaseRemoteDataSource(supabase));

  // ─── Repositories ───
  sl.registerLazySingleton<AuthRepository>(
    () => AuthRepoImpl(sl()),
  );
  sl.registerLazySingleton<BranchRepository>(
    () => BranchRepoImpl(sl(), sl()),
  );
  sl.registerLazySingleton<TransferRepository>(
    () => TransferRepoImpl(sl(), sl()),
  );
  sl.registerLazySingleton<LedgerRepository>(
    () => LedgerRepoImpl(sl()),
  );
  sl.registerLazySingleton<NotificationRepository>(
    () => NotificationRepoImpl(sl()),
  );
  sl.registerLazySingleton<AuditRepository>(
    () => AuditRepoImpl(sl()),
  );
  sl.registerLazySingleton<ExchangeRateRepository>(
    () => ExchangeRateRepoImpl(sl()),
  );
  sl.registerLazySingleton<ClientRepository>(
    () => ClientRepoImpl(sl()),
  );
  sl.registerLazySingleton<PurchaseRepository>(
    () => PurchaseRepoImpl(sl()),
  );

  // ─── Services ───
  sl.registerLazySingleton(() => LedgerExportService());
  sl.registerLazySingleton(() => TransferInvoiceService());
  sl.registerLazySingleton(() => BankImportService());
  BankApiRegistry.instance.register(SberbankApiProvider());
  sl.registerLazySingleton(() => ServerExportService(
    sl<LedgerRemoteDataSource>(),
    sl<TransferRemoteDataSource>(),
    sl<BranchRemoteDataSource>(),
    sl<UserRemoteDataSource>(),
    sl<LedgerExportService>(),
  ));

  // ─── Use Cases ───
  sl.registerLazySingleton(() => SignInUseCase(sl()));
  sl.registerLazySingleton(() => SignUpUseCase(sl()));
  sl.registerLazySingleton(() => SignOutUseCase(sl()));
  sl.registerLazySingleton(() => CreateTransferUseCase(sl()));
  sl.registerLazySingleton(() => ConfirmTransferUseCase(sl()));
  sl.registerLazySingleton(() => IssueTransferUseCase(sl()));
  sl.registerLazySingleton(() => IssuePartialTransferUseCase(sl()));
  sl.registerLazySingleton(() => RejectTransferUseCase(sl()));
  sl.registerLazySingleton(() => UpdateTransferUseCase(sl()));
  sl.registerLazySingleton(() => WatchTransfersUseCase(sl()));
  sl.registerLazySingleton(() => WatchBranchesUseCase(sl()));
  sl.registerLazySingleton(() => GetAccountBalanceUseCase(sl()));
  sl.registerLazySingleton(() => WatchLedgerUseCase(sl()));
  sl.registerLazySingleton(() => WatchNotificationsUseCase(sl()));

  // ─── BLoCs ───
  sl.registerFactory(() => AuthBloc(
        signIn: sl(),
        signUp: sl(),
        signOut: sl(),
        authRepository: sl(),
        credentialStorage: sl(),
        sessionService: sl(),
        systemSettingsDs: sl(),
        userSessionDs: sl(),
      ));
  sl.registerFactory(() => DashboardBloc(
        branchRepository: sl(),
        ledgerRepository: sl(),
        transferRepository: sl(),
      ));
  sl.registerFactory(() => TransferBloc(
        createTransfer: sl(),
        updateTransfer: sl(),
        confirmTransfer: sl(),
        issueTransfer: sl(),
        issuePartialTransfer: sl(),
        rejectTransfer: sl(),
        watchTransfers: sl(),
      ));
  sl.registerFactory(() => LedgerBloc(
        watchLedger: sl(),
        ledgerRepository: sl(),
      ));
  sl.registerFactory(() => NotificationBloc(
        repository: sl(),
        fx: sl(),
      ));
  sl.registerFactory(() => ExchangeRateBloc(
        repository: sl(),
      ));
  sl.registerFactory(() => AnalyticsBloc(
        remote: sl(),
      ));
  sl.registerFactory(() => ClientBloc(
        repository: sl(),
      ));
  sl.registerFactory(() => PurchaseBloc(
        repository: sl(),
      ));
  sl.registerFactory(() => BankImportBloc(
        importService: sl(),
        ledgerDs: sl(),
      ));
}
