/// Route names as constants to avoid typos.
class RouteNames {
  RouteNames._();

  // ─── Auth ───
  static const String splash = 'splash';
  static const String login = 'login';
  static const String register = 'register';
  static const String forgotPassword = 'forgot-password';

  // ─── Main Shell ───
  static const String dashboard = 'dashboard';
  static const String transfers = 'transfers';
  static const String createTransfer = 'create-transfer';
  static const String acceptedTransfers = 'accepted-transfers';
  static const String manageTransfers = 'manage-transfers';
  static const String transferDetail = 'transfer-detail';
  static const String ledger = 'ledger';
  static const String bankImport = 'bank-import';
  static const String branchTopUp = 'branch-topup';
  static const String notifications = 'notifications';
  static const String auditLog = 'audit-log';
  static const String settings = 'settings';

  // ─── Branch Management ───
  static const String branches = 'branches';
  static const String branchDetail = 'branch-detail';

  // ─── Client Accounts ───
  static const String clients = 'clients';

  // ─── Purchases ───
  static const String purchases = 'purchases';

  // ─── User Management ───
  static const String users = 'users';

  // ─── Exchange Rates ───
  static const String exchangeRates = 'exchange-rates';

  // ─── Analytics ───
  static const String analytics = 'analytics';

  // ─── Reports ───
  static const String reports = 'reports';
}
