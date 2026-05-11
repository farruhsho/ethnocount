import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Тонко-настраиваемая матрица доступа для роли «бухгалтер».
///
/// Принцип:
/// - `can*View` — только просмотр
/// - `canManage*` — создание / редактирование / удаление
/// - матрица применяется поверх списка `assignedBranchIds` (RLS).
///   Можно дать доступ ко всем филиалам, но запретить отдельные категории
///   данных (например карты, аудит, другие филиалы).
class AccountantPermissions {
  const AccountantPermissions({
    // ── переводы / покупки / пополнения ──
    this.canTransfers = true,
    this.canPurchases = true,
    this.canManageTransfers = false,
    this.canManagePurchases = false,
    this.canBranchTopUp = false,
    this.canDeleteTransactions = false,
    // ── справочники / навигация ──
    this.canClients = true,
    this.canManageClients = false,
    this.canLedger = true,
    this.canAnalytics = true,
    this.canReports = true,
    this.canExchangeRates = true,
    this.canManageExchangeRates = false,
    this.canBranchesView = true,
    // ── чувствительные данные ──
    this.canViewBalances = true,
    this.canViewCardDetails = false,
    this.canViewAuditLog = false,
    this.canExportData = true,
    this.canViewNotifications = true,
    // ── межфилиальные операции ──
    this.canCrossBranchTransfers = true,
  });

  // operations
  final bool canTransfers;
  final bool canPurchases;

  /// Создание и редактирование переводов (сумма, номер карты и т.д.).
  final bool canManageTransfers;

  /// Создание, редактирование и удаление покупок (включая сумму).
  final bool canManagePurchases;

  /// Пополнение филиала (за счёт источника или без).
  final bool canBranchTopUp;

  /// Удаление транзакций (soft-delete).
  final bool canDeleteTransactions;

  // directories
  final bool canClients;

  /// Создание / редактирование клиентов и контрагентов.
  final bool canManageClients;

  final bool canLedger;
  final bool canAnalytics;
  final bool canReports;
  final bool canExchangeRates;

  /// Изменение курсов валют вручную / в настройках.
  final bool canManageExchangeRates;

  final bool canBranchesView;

  // sensitive data
  /// Видеть числовые балансы счетов и филиалов.
  final bool canViewBalances;

  /// Видеть полные номера карт, держателей, банковские реквизиты.
  final bool canViewCardDetails;

  /// Видеть журнал аудита (audit_logs).
  final bool canViewAuditLog;

  /// Экспорт данных (CSV / Excel).
  final bool canExportData;

  /// Доступ к экрану уведомлений.
  final bool canViewNotifications;

  // cross-branch operations
  /// Создавать переводы из своих филиалов в любые другие филиалы.
  /// Если выключено — переводы только между filling-флагом assigned филиалами.
  final bool canCrossBranchTransfers;

  static const all = AccountantPermissions(
    canManageTransfers: true,
    canManagePurchases: true,
    canBranchTopUp: true,
    canDeleteTransactions: true,
    canManageClients: true,
    canManageExchangeRates: true,
    canViewBalances: true,
    canViewCardDetails: true,
    canViewAuditLog: true,
    canExportData: true,
  );

  static const none = AccountantPermissions(
    canTransfers: false,
    canPurchases: false,
    canClients: false,
    canLedger: false,
    canAnalytics: false,
    canReports: false,
    canExchangeRates: false,
    canBranchesView: false,
    canViewBalances: false,
    canViewNotifications: false,
    canCrossBranchTransfers: false,
  );

  Map<String, dynamic> toMap() => {
        'canTransfers': canTransfers,
        'canPurchases': canPurchases,
        'canManageTransfers': canManageTransfers,
        'canManagePurchases': canManagePurchases,
        'canBranchTopUp': canBranchTopUp,
        'canDeleteTransactions': canDeleteTransactions,
        'canClients': canClients,
        'canManageClients': canManageClients,
        'canLedger': canLedger,
        'canAnalytics': canAnalytics,
        'canReports': canReports,
        'canExchangeRates': canExchangeRates,
        'canManageExchangeRates': canManageExchangeRates,
        'canBranchesView': canBranchesView,
        'canViewBalances': canViewBalances,
        'canViewCardDetails': canViewCardDetails,
        'canViewAuditLog': canViewAuditLog,
        'canExportData': canExportData,
        'canViewNotifications': canViewNotifications,
        'canCrossBranchTransfers': canCrossBranchTransfers,
      };

  static AccountantPermissions fromMap(Map<String, dynamic>? m) {
    if (m == null) return const AccountantPermissions();
    bool b(String k, bool def) => m[k] is bool ? m[k] as bool : def;
    return AccountantPermissions(
      canTransfers: b('canTransfers', true),
      canPurchases: b('canPurchases', true),
      canManageTransfers: b('canManageTransfers', false),
      canManagePurchases: b('canManagePurchases', false),
      canBranchTopUp: b('canBranchTopUp', false),
      canDeleteTransactions: b('canDeleteTransactions', false),
      canClients: b('canClients', true),
      canManageClients: b('canManageClients', false),
      canLedger: b('canLedger', true),
      canAnalytics: b('canAnalytics', true),
      canReports: b('canReports', true),
      canExchangeRates: b('canExchangeRates', true),
      canManageExchangeRates: b('canManageExchangeRates', false),
      canBranchesView: b('canBranchesView', true),
      canViewBalances: b('canViewBalances', true),
      canViewCardDetails: b('canViewCardDetails', false),
      canViewAuditLog: b('canViewAuditLog', false),
      canExportData: b('canExportData', true),
      canViewNotifications: b('canViewNotifications', true),
      canCrossBranchTransfers: b('canCrossBranchTransfers', true),
    );
  }

  AccountantPermissions copyWith({
    bool? canTransfers,
    bool? canPurchases,
    bool? canManageTransfers,
    bool? canManagePurchases,
    bool? canBranchTopUp,
    bool? canDeleteTransactions,
    bool? canClients,
    bool? canManageClients,
    bool? canLedger,
    bool? canAnalytics,
    bool? canReports,
    bool? canExchangeRates,
    bool? canManageExchangeRates,
    bool? canBranchesView,
    bool? canViewBalances,
    bool? canViewCardDetails,
    bool? canViewAuditLog,
    bool? canExportData,
    bool? canViewNotifications,
    bool? canCrossBranchTransfers,
  }) =>
      AccountantPermissions(
        canTransfers: canTransfers ?? this.canTransfers,
        canPurchases: canPurchases ?? this.canPurchases,
        canManageTransfers: canManageTransfers ?? this.canManageTransfers,
        canManagePurchases: canManagePurchases ?? this.canManagePurchases,
        canBranchTopUp: canBranchTopUp ?? this.canBranchTopUp,
        canDeleteTransactions:
            canDeleteTransactions ?? this.canDeleteTransactions,
        canClients: canClients ?? this.canClients,
        canManageClients: canManageClients ?? this.canManageClients,
        canLedger: canLedger ?? this.canLedger,
        canAnalytics: canAnalytics ?? this.canAnalytics,
        canReports: canReports ?? this.canReports,
        canExchangeRates: canExchangeRates ?? this.canExchangeRates,
        canManageExchangeRates:
            canManageExchangeRates ?? this.canManageExchangeRates,
        canBranchesView: canBranchesView ?? this.canBranchesView,
        canViewBalances: canViewBalances ?? this.canViewBalances,
        canViewCardDetails: canViewCardDetails ?? this.canViewCardDetails,
        canViewAuditLog: canViewAuditLog ?? this.canViewAuditLog,
        canExportData: canExportData ?? this.canExportData,
        canViewNotifications:
            canViewNotifications ?? this.canViewNotifications,
        canCrossBranchTransfers:
            canCrossBranchTransfers ?? this.canCrossBranchTransfers,
      );
}

/// Authenticated user entity with role and branch assignment.
class AppUser extends Equatable {
  final String id;
  final String displayName;
  final String email;
  final String? photoUrl;
  final String? phone;
  final SystemRole role;
  final List<String> assignedBranchIds;
  final AccountantPermissions permissions;
  final bool isActive;
  final DateTime createdAt;

  const AppUser({
    required this.id,
    required this.displayName,
    required this.email,
    this.photoUrl,
    this.phone,
    required this.role,
    this.assignedBranchIds = const [],
    this.permissions = const AccountantPermissions(),
    this.isActive = true,
    required this.createdAt,
  });

  /// Whether this user can operate on a specific branch.
  /// Creator/Director — все филиалы; бухгалтер — только из assignedBranchIds.
  bool canAccessBranch(String branchId) =>
      role.isAdminOrCreator || assignedBranchIds.contains(branchId);

  /// Может ли пользователь быть отправителем перевода в данный филиал.
  /// Для бухгалтера — нужен явный assigned доступ.
  bool canSendFromBranch(String branchId) => canAccessBranch(branchId);

  /// Может ли пользователь выбрать произвольный филиал получателем.
  /// Бухгалтер — только если включён `canCrossBranchTransfers` (по умолчанию да).
  bool canSendToBranch(String branchId) {
    if (role.isAdminOrCreator) return true;
    if (assignedBranchIds.contains(branchId)) return true;
    return permissions.canCrossBranchTransfers;
  }

  /// Creator или Director: Управление пользователями.
  bool get canManageUsers => role.canManageUsers;

  /// Creator-only: полное управление филиалами и счетами.
  bool get canManageBranches => role.isCreator;

  /// Creator или бухгалтер с правом управления переводами.
  bool get canManageTransfers => role.isCreator || permissions.canManageTransfers;

  /// Creator или бухгалтер с правом управления покупками.
  bool get canManagePurchases => role.isCreator || permissions.canManagePurchases;

  /// Creator или бухгалтер с правом пополнения филиала.
  bool get canBranchTopUp => role.isCreator || permissions.canBranchTopUp;

  /// Creator или бухгалтер с правом видеть полные карточные данные.
  bool get canViewCardDetails =>
      role.isAdminOrCreator || permissions.canViewCardDetails;

  /// Creator или бухгалтер с правом видеть аудит.
  bool get canViewAuditLog =>
      role.isAdminOrCreator || permissions.canViewAuditLog;

  /// Creator или бухгалтер с правом изменять курсы.
  bool get canManageExchangeRates =>
      role.isCreator || permissions.canManageExchangeRates;

  /// Creator или бухгалтер с правом видеть балансы.
  bool get canViewBalances =>
      role.isAdminOrCreator || permissions.canViewBalances;

  /// Creator или бухгалтер с правом экспорта.
  bool get canExportData =>
      role.isAdminOrCreator || permissions.canExportData;

  @override
  List<Object?> get props => [
        id,
        displayName,
        email,
        photoUrl,
        phone,
        role,
        assignedBranchIds,
        permissions,
        isActive,
        createdAt,
      ];
}
