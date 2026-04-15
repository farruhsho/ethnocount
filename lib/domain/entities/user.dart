import 'package:equatable/equatable.dart';
import 'package:ethnocount/domain/entities/enums.dart';

/// Features Creator can enable/disable for Accountant.
class AccountantPermissions {
  const AccountantPermissions({
    this.canTransfers = true,
    this.canPurchases = true,
    this.canManageTransfers = false,
    this.canManagePurchases = false,
    this.canBranchTopUp = false,
    this.canClients = true,
    this.canLedger = true,
    this.canAnalytics = true,
    this.canReports = true,
    this.canExchangeRates = true,
    this.canBranchesView = true,
  });

  final bool canTransfers;
  final bool canPurchases;

  /// Создание и редактирование переводов (сумма, номер карты и т.д.).
  final bool canManageTransfers;

  /// Создание, редактирование и удаление покупок (включая сумму).
  final bool canManagePurchases;

  /// Пополнение филиала (за счёт источника или без).
  final bool canBranchTopUp;

  final bool canClients;
  final bool canLedger;
  final bool canAnalytics;
  final bool canReports;
  final bool canExchangeRates;
  final bool canBranchesView;

  static const all = AccountantPermissions();
  static const none = AccountantPermissions(
    canTransfers: false,
    canPurchases: false,
    canClients: false,
    canLedger: false,
    canAnalytics: false,
    canReports: false,
    canExchangeRates: false,
    canBranchesView: false,
  );

  Map<String, dynamic> toMap() => {
        'canTransfers': canTransfers,
        'canPurchases': canPurchases,
        'canManageTransfers': canManageTransfers,
        'canManagePurchases': canManagePurchases,
        'canBranchTopUp': canBranchTopUp,
        'canClients': canClients,
        'canLedger': canLedger,
        'canAnalytics': canAnalytics,
        'canReports': canReports,
        'canExchangeRates': canExchangeRates,
        'canBranchesView': canBranchesView,
      };

  static AccountantPermissions fromMap(Map<String, dynamic>? m) {
    if (m == null) return all;
    return AccountantPermissions(
      canTransfers: m['canTransfers'] ?? true,
      canPurchases: m['canPurchases'] ?? true,
      canManageTransfers: m['canManageTransfers'] ?? false,
      canManagePurchases: m['canManagePurchases'] ?? false,
      canBranchTopUp: m['canBranchTopUp'] ?? false,
      canClients: m['canClients'] ?? true,
      canLedger: m['canLedger'] ?? true,
      canAnalytics: m['canAnalytics'] ?? true,
      canReports: m['canReports'] ?? true,
      canExchangeRates: m['canExchangeRates'] ?? true,
      canBranchesView: m['canBranchesView'] ?? true,
    );
  }

  AccountantPermissions copyWith({
    bool? canTransfers,
    bool? canPurchases,
    bool? canManageTransfers,
    bool? canManagePurchases,
    bool? canBranchTopUp,
    bool? canClients,
    bool? canLedger,
    bool? canAnalytics,
    bool? canReports,
    bool? canExchangeRates,
    bool? canBranchesView,
  }) =>
      AccountantPermissions(
        canTransfers: canTransfers ?? this.canTransfers,
        canPurchases: canPurchases ?? this.canPurchases,
        canManageTransfers: canManageTransfers ?? this.canManageTransfers,
        canManagePurchases: canManagePurchases ?? this.canManagePurchases,
        canBranchTopUp: canBranchTopUp ?? this.canBranchTopUp,
        canClients: canClients ?? this.canClients,
        canLedger: canLedger ?? this.canLedger,
        canAnalytics: canAnalytics ?? this.canAnalytics,
        canReports: canReports ?? this.canReports,
        canExchangeRates: canExchangeRates ?? this.canExchangeRates,
        canBranchesView: canBranchesView ?? this.canBranchesView,
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
    this.permissions = AccountantPermissions.all,
    this.isActive = true,
    required this.createdAt,
  });

  /// Whether this user can operate on a specific branch.
  bool canAccessBranch(String branchId) =>
      role.isAdminOrCreator || assignedBranchIds.contains(branchId);

  /// Creator-only: Управление пользователями.
  bool get canManageUsers => role.isCreator;

  /// Creator-only: полное управление филиалами и счетами.
  bool get canManageBranches => role.isCreator;

  /// Creator или бухгалтер с правом управления переводами.
  bool get canManageTransfers => role.isCreator || permissions.canManageTransfers;

  /// Creator или бухгалтер с правом управления покупками.
  bool get canManagePurchases => role.isCreator || permissions.canManagePurchases;

  /// Creator или бухгалтер с правом пополнения филиала.
  bool get canBranchTopUp => role.isCreator || permissions.canBranchTopUp;

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
