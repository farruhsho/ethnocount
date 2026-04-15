/// System roles — only Creator (super admin) and Accountant.
enum SystemRole {
  creator,
  accountant;

  bool get canCreateTransfer => true;
  bool get canConfirmTransfer => true;
  bool get canRejectTransfer => true;
  bool get canViewLedger => true;
  bool get canViewAuditLog => this == creator;
  bool get canManageBranches => this == creator;
  bool get canManageAccounts => this == creator;

  /// Only Creator can create/edit/delete users.
  bool get canManageUsers => this == creator;

  /// Only Creator can change user branch assignments.
  bool get canChangeBranch => this == creator;

  bool get canSetExchangeRates => true;
  bool get canViewReports => true;
  bool get canManageClients => true;
  bool get canCreatePurchase => true;

  bool get isCreator => this == creator;

  /// Backward-compatible alias — now same as isCreator.
  bool get isAdminOrCreator => this == creator;

  String get displayName {
    switch (this) {
      case creator:
        return 'Creator';
      case accountant:
        return 'Accountant';
    }
  }

  String get displayNameRu {
    switch (this) {
      case creator:
        return 'Создатель (Creator)';
      case accountant:
        return 'Бухгалтер';
    }
  }
}

/// Commission type for transfers.
enum CommissionType {
  fixed,
  percentage;

  String get displayName {
    switch (this) {
      case fixed:
        return 'Фиксированная';
      case percentage:
        return 'Процент (%)';
    }
  }

  String get symbol {
    switch (this) {
      case fixed:
        return '';
      case percentage:
        return '%';
    }
  }
}

/// Commission mode: how commission is applied.
enum CommissionMode {
  /// Commission INSIDE transfer: sender pays 100,000$, we take 1% (1,000$) from it, recipient gets 99,000$.
  fromTransfer,

  /// Commission SEPARATE: sender pays 101$ (100$ + 1$), recipient gets 100$, we take 1$.
  fromSender,

  /// Commission added to recipient: 100$ → recipient gets 101$.
  toReceiver;

  String get displayName {
    switch (this) {
      case fromTransfer:
        return 'Внутри перевода';
      case fromSender:
        return 'Отдельно с отправителя';
      case toReceiver:
        return 'К получателю';
    }
  }

  String get description {
    switch (this) {
      case fromTransfer:
        return 'Комиссия из суммы: 100 000\$ → 1% = 1 000\$ нам, получателю 99 000\$';
      case fromSender:
        return 'Отдельная комиссия: отправитель платит 101\$ (100\$ + 1\$), получателю 100\$';
      case toReceiver:
        return 'Комиссия добавляется получателю (100\$ → получит 101\$)';
    }
  }
}

/// Branch account types.
enum AccountType {
  cash,
  card,
  reserve,
  transit;

  String get displayName {
    switch (this) {
      case cash:
        return 'Наличные';
      case card:
        return 'Карта';
      case reserve:
        return 'Резерв';
      case transit:
        return 'Транзит';
    }
  }

  String get icon {
    switch (this) {
      case cash:
        return '💵';
      case card:
        return '💳';
      case reserve:
        return '🏦';
      case transit:
        return '🔄';
    }
  }
}

/// Transfer lifecycle states.
enum TransferStatus {
  pending,
  confirmed,
  issued, // vidan — деньги выданы получателю
  rejected,
  cancelled;

  String get displayName {
    switch (this) {
      case pending:
        return 'Ожидает';
      case confirmed:
        return 'Принят';
      case issued:
        return 'Выдан';
      case rejected:
        return 'Отклонён';
      case cancelled:
        return 'Отменён';
    }
  }

  bool get isFinal =>
      this == confirmed || this == issued || this == rejected || this == cancelled;
}

/// Double-entry ledger entry types.
enum LedgerEntryType {
  debit,
  credit;

  String get displayName {
    switch (this) {
      case debit:
        return 'Дебет';
      case credit:
        return 'Кредит';
    }
  }
}

/// What caused a ledger entry.
enum LedgerReferenceType {
  transfer,
  commission,
  adjustment,
  openingBalance,
  clientDeposit,
  clientDebit,
  purchase,
  bankImport,
  branchTopUp;

  String get displayName {
    switch (this) {
      case transfer:
        return 'Перевод';
      case commission:
        return 'Комиссия';
      case adjustment:
        return 'Корректировка';
      case openingBalance:
        return 'Начальный баланс';
      case clientDeposit:
        return 'Пополнение клиента';
      case clientDebit:
        return 'Списание клиента';
      case purchase:
        return 'Покупка';
      case bankImport:
        return 'Импорт из банка';
      case branchTopUp:
        return 'Пополнение филиала';
    }
  }
}

/// Client transaction types.
enum ClientTransactionType {
  deposit,
  debit;

  String get displayName {
    switch (this) {
      case deposit:
        return 'Пополнение';
      case debit:
        return 'Списание';
    }
  }
}

/// Notification types for the internal notification system.
enum NotificationType {
  incomingTransfer,
  transferConfirmed,
  transferRejected,
  transferCancelled,
  transferIssued,
  transferAmended,
  systemAlert;

  String get displayName {
    switch (this) {
      case incomingTransfer:
        return 'Входящий перевод';
      case transferConfirmed:
        return 'Перевод подтверждён';
      case transferRejected:
        return 'Перевод отклонён';
      case transferCancelled:
        return 'Перевод отменён';
      case transferIssued:
        return 'Перевод выдан';
      case transferAmended:
        return 'Перевод изменён';
      case systemAlert:
        return 'Системное оповещение';
    }
  }
}

/// Purchase payment method (which type of account was used).
enum PaymentMethod {
  cash,
  card,
  bankTransfer,
  other;

  String get displayName {
    switch (this) {
      case cash:
        return 'Наличные';
      case card:
        return 'Карта';
      case bankTransfer:
        return 'Банковский перевод';
      case other:
        return 'Другое';
    }
  }

  String get icon {
    switch (this) {
      case cash:
        return '💵';
      case card:
        return '💳';
      case bankTransfer:
        return '🏦';
      case other:
        return '💰';
    }
  }
}
