/// System roles: Creator (super admin), Director (manages accountants), Accountant.
enum SystemRole {
  creator,
  director,
  accountant;

  bool get canCreateTransfer => true;
  bool get canConfirmTransfer => true;
  bool get canRejectTransfer => true;
  bool get canViewLedger => true;
  bool get canViewAuditLog => this == creator;
  bool get canManageBranches => this == creator;
  bool get canManageAccounts => this == creator;

  /// Creator and Director can create/edit/delete users.
  /// Director is restricted to managing accountants only (enforced by RLS + RPC).
  bool get canManageUsers => this == creator || this == director;

  /// Creator and Director can change user branch assignments
  /// (Director can only assign branches to accountants).
  bool get canChangeBranch => this == creator || this == director;

  bool get canSetExchangeRates => true;
  bool get canViewReports => true;
  bool get canManageClients => true;
  bool get canCreatePurchase => true;

  bool get isCreator => this == creator;
  bool get isDirector => this == director;

  /// True for roles with all-branch operational access.
  /// Director focuses on user management, not operations, so this stays creator-only.
  bool get isAdminOrCreator => this == creator;

  String get displayName {
    switch (this) {
      case creator:
        return 'Creator';
      case director:
        return 'Director';
      case accountant:
        return 'Accountant';
    }
  }

  String get displayNameRu {
    switch (this) {
      case creator:
        return 'Создатель (Creator)';
      case director:
        return 'Директор';
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
  toReceiver,

  /// Commission goes as INCOME to a separate account (any account of the
  /// sending branch). Currency of commission is taken from that account.
  /// Семантика: «копилка комиссий» — на выбранный счёт начисляется
  /// заработанная сумма (CREDIT, не DEBIT). См. миграцию 032.
  fromAccount;

  String get displayName {
    switch (this) {
      case fromTransfer:
        return 'Внутри перевода';
      case fromSender:
        return 'Отдельно с отправителя';
      case toReceiver:
        return 'К получателю';
      case fromAccount:
        return 'На отдельный счёт';
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
      case fromAccount:
        return 'Комиссия начисляется на выбранный счёт как доход. Валюта — этого счёта.';
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
///
/// Workflow:
///   created   — отправитель создал перевод (раньше `pending`)
///   toDelivery — приёмный филиал подтвердил, готов к выдаче (раньше `confirmed`)
///   withCourier — отправитель отдал деньги курьеру для доставки получателю
///   delivered — получатель получил деньги (раньше `issued`)
///
/// Старые `rejected` / `cancelled` удалены из workflow.
enum TransferStatus {
  created,
  toDelivery,
  withCourier,
  delivered;

  String get displayName {
    switch (this) {
      case created:
        return 'Создан';
      case toDelivery:
        return 'К выдаче';
      case withCourier:
        return 'У курьера';
      case delivered:
        return 'Выдан';
    }
  }

  /// Final = деньги дошли до получателя. Только `delivered` — финал.
  bool get isFinal => this == delivered;
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
  transferDispatched,
  transferIssued,
  transferAmended,
  systemAlert;

  String get displayName {
    switch (this) {
      case incomingTransfer:
        return 'Входящий перевод';
      case transferConfirmed:
        return 'Перевод подтверждён';
      case transferDispatched:
        return 'Перевод отдан курьеру';
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
