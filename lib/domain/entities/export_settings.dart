/// Настройки экспорта: колонки и лимит строк.
class ExportSettings {
  const ExportSettings({
    required this.enabledColumns,
    this.rowLimit,
  });

  /// Включённые колонки (ключ — id колонки).
  final Set<String> enabledColumns;

  /// Лимит строк (null = все).
  final int? rowLimit;

  ExportSettings copyWith({
    Set<String>? enabledColumns,
    int? rowLimit,
  }) =>
      ExportSettings(
        enabledColumns: enabledColumns ?? this.enabledColumns,
        rowLimit: rowLimit ?? this.rowLimit,
      );
}

/// Описание колонки для экспорта.
class ExportColumnDef {
  const ExportColumnDef(this.id, this.label, {this.defaultEnabled = true});
  final String id;
  final String label;
  final bool defaultEnabled;
}

/// Предустановки колонок по типам отчётов.
class ExportColumnPresets {
  static const transfers = [
    ExportColumnDef('num', '№', defaultEnabled: true),
    ExportColumnDef('code', 'Код', defaultEnabled: true),
    ExportColumnDef('date', 'Дата', defaultEnabled: true),
    ExportColumnDef('from', 'Откуда (филиал)', defaultEnabled: true),
    ExportColumnDef('senderName', 'Имя отправителя', defaultEnabled: true),
    ExportColumnDef('senderPhone', 'Телефон отправителя', defaultEnabled: true),
    ExportColumnDef('to', 'Куда (филиал)', defaultEnabled: true),
    ExportColumnDef('receiverName', 'Имя получателя', defaultEnabled: true),
    ExportColumnDef('receiverPhone', 'Телефон получателя', defaultEnabled: true),
    ExportColumnDef('amount', 'Сумма', defaultEnabled: true),
    ExportColumnDef('currency', 'Валюта', defaultEnabled: true),
    ExportColumnDef('rate', 'Курс', defaultEnabled: true),
    ExportColumnDef('converted', 'Конвертировано', defaultEnabled: true),
    ExportColumnDef('commission', 'Комиссия', defaultEnabled: true),
    ExportColumnDef('commissionCurrency', 'Валюта комиссии', defaultEnabled: true),
    ExportColumnDef('status', 'Статус', defaultEnabled: true),
    ExportColumnDef('createdBy', 'Создал', defaultEnabled: true),
    ExportColumnDef('confirmedBy', 'Принял', defaultEnabled: true),
  ];

  static const ledger = [
    ExportColumnDef('num', '№ п/п', defaultEnabled: true),
    ExportColumnDef('date', 'Дата', defaultEnabled: true),
    ExportColumnDef('doc', 'Документ', defaultEnabled: true),
    ExportColumnDef('account', 'Счёт', defaultEnabled: true),
    ExportColumnDef('accountName', 'Наименование счёта', defaultEnabled: true),
    ExportColumnDef('type', 'Тип операции', defaultEnabled: true),
    ExportColumnDef('description', 'Описание', defaultEnabled: true),
    ExportColumnDef('debit', 'Дебет', defaultEnabled: true),
    ExportColumnDef('credit', 'Кредит', defaultEnabled: true),
    ExportColumnDef('currency', 'Валюта', defaultEnabled: true),
  ];

  static const rowLimitOptions = [100, 500, 1000, 5000, 10000];
}
