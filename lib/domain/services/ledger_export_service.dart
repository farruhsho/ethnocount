import 'package:flutter/foundation.dart';
import 'package:excel/excel.dart';
import 'package:file_saver/file_saver.dart';
import '../entities/commission.dart';
import '../entities/transfer.dart';
import '../entities/ledger_entry.dart';
import '../entities/export_settings.dart';
import '../entities/enums.dart';

/// Форматирование для бухгалтерских отчётов: дата ДД.ММ.ГГГГ, числа с разделителями.
String _fmtDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

String _fmtNum(double v) {
  if (v == 0) return '0,00';
  final s = v.toStringAsFixed(2);
  final parts = s.split('.');
  var intPart = parts[0];
  final neg = intPart.startsWith('-');
  if (neg) intPart = intPart.substring(1);
  final len = intPart.length;
  final buf = StringBuffer();
  for (var i = 0; i < len; i++) {
    if (i > 0 && (len - i) % 3 == 0) buf.write(' ');
    buf.write(intPart[i]);
  }
  return '${neg ? '-' : ''}${buf.toString()},${parts[1]}';
}

class LedgerExportService {
  Future<bool> exportTransfersToExcel(
    List<Transfer> transfers,
    String fileName, {
    Map<String, String> branchNames = const {},
    Map<String, String> accountNames = const {},
    Map<String, String> userNames = const {},
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) async {
    try {
      final bytes = await compute(
        _generateTransfersExcel,
        _TransferExportParams(
          transfers,
          branchNames,
          accountNames,
          userNames,
          startDate,
          endDate,
          exportSettings,
        ),
      );

      if (bytes != null) {
        await FileSaver.instance.saveFile(
          name: '$fileName.xlsx',
          bytes: Uint8List.fromList(bytes),
          mimeType: MimeType.microsoftExcel,
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Export error: $e');
      return false;
    }
  }

  Future<bool> exportLedgerToExcel(
    List<LedgerEntry> entries,
    String fileName, {
    Map<String, String> accountNames = const {},
    String? branchName,
    DateTime? startDate,
    DateTime? endDate,
    ExportSettings? exportSettings,
  }) async {
    try {
      final bytes = await compute(
        _generateLedgerExcel,
        _LedgerExportParams(
          entries,
          accountNames,
          branchName ?? '',
          startDate,
          endDate,
          exportSettings,
        ),
      );

      if (bytes != null) {
        await FileSaver.instance.saveFile(
          name: '$fileName.xlsx',
          bytes: Uint8List.fromList(bytes),
          mimeType: MimeType.microsoftExcel,
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Export error: $e');
      return false;
    }
  }

  static const _transferColDefs = [
    ('num', '№', 6.0),
    ('code', 'Код', 14.0),
    ('date', 'Дата', 10.0),
    ('from', 'Откуда (филиал)', 14.0),
    ('senderName', 'Имя отправителя', 14.0),
    ('senderPhone', 'Телефон отправителя', 12.0),
    ('to', 'Куда (филиал)', 14.0),
    ('receiverName', 'Имя получателя', 14.0),
    ('receiverPhone', 'Телефон получателя', 12.0),
    ('amount', 'Сумма', 12.0),
    ('currency', 'Валюта', 8.0),
    ('rate', 'Курс', 8.0),
    ('converted', 'Конвертировано', 12.0),
    ('commission', 'Комиссия', 10.0),
    ('commissionCurrency', 'Валюта комиссии', 10.0),
    ('status', 'Статус', 10.0),
    ('createdBy', 'Создал', 12.0),
    ('confirmedBy', 'Принял', 12.0),
  ];

  static List<int>? _generateTransfersExcel(_TransferExportParams params) {
    try {
      var excel = Excel.createExcel();
      Sheet sheet = excel['Переводы'];
      excel.setDefaultSheet('Переводы');
      if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');

      final enabled = params.exportSettings?.enabledColumns ??
          _transferColDefs.map((c) => c.$1).toSet();
      final cols = _transferColDefs.where((c) => enabled.contains(c.$1)).toList();
      var data = params.transfers;
      final limit = params.exportSettings?.rowLimit;
      if (limit != null && data.length > limit) data = data.take(limit).toList();

      final period = params.startDate != null && params.endDate != null
          ? ' за период ${_fmtDate(params.startDate!)} — ${_fmtDate(params.endDate!)}'
          : '';

      sheet.appendRow([TextCellValue('Ведомость переводов$period')]);
      sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
          CellIndex.indexByColumnRow(columnIndex: cols.length - 1, rowIndex: 0));
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle =
          CellStyle(bold: true, fontSize: 14);
      sheet.appendRow([]);

      final headers = cols.map((c) => TextCellValue(c.$2)).toList();
      sheet.appendRow(headers);
      final headerStyle = CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
      for (var c = 0; c < cols.length; c++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 2)).cellStyle = headerStyle;
        sheet.setColumnWidth(c, cols[c].$3);
      }

      double totalAmount = 0, totalCommission = 0;
      var n = 1;
      final altStyle = CellStyle(backgroundColorHex: ExcelColor.grey50);
      for (var i = 0; i < data.length; i++) {
        final t = data[i];
        totalAmount += t.amount;
        totalCommission += t.commission;
        final row = <CellValue>[];
        for (final col in cols) {
          switch (col.$1) {
            case 'num': row.add(IntCellValue(n++)); break;
            case 'code': row.add(TextCellValue(t.transactionCode ?? t.id.substring(0, 8))); break;
            case 'date': row.add(TextCellValue(_fmtDate(t.createdAt))); break;
            case 'from': row.add(TextCellValue(params.branchNames[t.fromBranchId] ?? t.fromBranchId)); break;
            case 'senderName': row.add(TextCellValue(t.senderName ?? '')); break;
            case 'senderPhone': row.add(TextCellValue(t.senderPhone ?? '')); break;
            case 'to': row.add(TextCellValue(params.branchNames[t.toBranchId] ?? t.toBranchId)); break;
            case 'receiverName': row.add(TextCellValue(t.receiverName ?? '')); break;
            case 'receiverPhone': row.add(TextCellValue(t.receiverPhone ?? '')); break;
            case 'amount': row.add(TextCellValue(_fmtNum(t.amount))); break;
            case 'currency': row.add(TextCellValue(t.currency)); break;
            case 'rate': row.add(TextCellValue(_fmtNum(t.exchangeRate))); break;
            case 'converted': row.add(TextCellValue(_fmtNum(t.convertedAmount))); break;
            case 'commission': row.add(TextCellValue(_fmtNum(t.commission))); break;
            case 'commissionCurrency': row.add(TextCellValue(t.commissionCurrency)); break;
            case 'status': row.add(TextCellValue(t.status.displayName)); break;
            case 'createdBy': row.add(TextCellValue(params.userNames[t.createdBy] ?? t.createdBy)); break;
            case 'confirmedBy': row.add(TextCellValue(t.confirmedBy != null ? (params.userNames[t.confirmedBy!] ?? t.confirmedBy!) : '')); break;
            default: row.add(TextCellValue(''));
          }
        }
        sheet.appendRow(row);
        if (i % 2 == 1) {
          for (var c = 0; c < cols.length; c++) {
            sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 3 + i)).cellStyle = altStyle;
          }
        }
      }

      sheet.appendRow([]);
      final footerRow = 3 + data.length + 1;
      sheet.appendRow([TextCellValue('Сформировано: ${_fmtDate(DateTime.now())}')]);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: footerRow)).cellStyle =
          CellStyle(fontSize: 10, fontColorHex: ExcelColor.grey600);

      _addTransfersSummarySheet(excel, data, totalAmount, totalCommission);

      return excel.encode();
    } catch (e) {
      debugPrint('Isolate Excel error: $e');
      return null;
    }
  }

  static void _addTransfersSummarySheet(Excel excel, List<Transfer> transfers, double totalAmount, double totalCommission) {
    final sheet = excel['Сводка'];
    var r = 0;

    sheet.appendRow([TextCellValue('Сводка по переводам')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, fontSize: 14);
    r++;
    sheet.appendRow([]);
    r++;

    final byStatus = <TransferStatus, _TransferStat>{};
    for (final s in TransferStatus.values) {
      byStatus[s] = _TransferStat();
    }
    final byCurrency = <String, double>{};
    double minAmount = double.infinity, maxAmount = 0;
    DateTime? firstDate, lastDate;
    double totalConverted = 0;

    for (final t in transfers) {
      byStatus[t.status]!.count++;
      byStatus[t.status]!.amount += t.amount;
      byStatus[t.status]!.commission += t.commission;
      byCurrency[t.currency] = (byCurrency[t.currency] ?? 0) + t.amount;
      if (t.amount < minAmount) minAmount = t.amount;
      if (t.amount > maxAmount) maxAmount = t.amount;
      totalConverted += t.convertedAmount;
      if (firstDate == null || t.createdAt.isBefore(firstDate)) firstDate = t.createdAt;
      if (lastDate == null || t.createdAt.isAfter(lastDate)) lastDate = t.createdAt;
    }
    if (minAmount == double.infinity) minAmount = 0;

    sheet.appendRow([TextCellValue('Основные показатели')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Показатель'), TextCellValue('Значение')]);
    for (var c = 0; c < 2; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    r++;
    sheet.appendRow([TextCellValue('Количество операций'), IntCellValue(transfers.length)]);
    sheet.appendRow([TextCellValue('Сумма переводов'), TextCellValue(_fmtNum(totalAmount))]);
    sheet.appendRow([TextCellValue('Сумма конвертированная'), TextCellValue(_fmtNum(totalConverted))]);
    sheet.appendRow([TextCellValue('Сумма комиссий'), TextCellValue(_fmtNum(totalCommission))]);
    sheet.appendRow([TextCellValue('Итого (сумма + комиссии)'), TextCellValue(_fmtNum(totalAmount + totalCommission))]);
    sheet.appendRow([TextCellValue('Средняя сумма перевода'), TextCellValue(_fmtNum(transfers.isEmpty ? 0 : totalAmount / transfers.length))]);
    sheet.appendRow([TextCellValue('Мин. сумма'), TextCellValue(_fmtNum(minAmount))]);
    sheet.appendRow([TextCellValue('Макс. сумма'), TextCellValue(_fmtNum(maxAmount))]);
    if (firstDate != null && lastDate != null) {
      sheet.appendRow([TextCellValue('Период данных'), TextCellValue('${_fmtDate(firstDate)} — ${_fmtDate(lastDate)}')]);
    }
    r += 9;

    sheet.appendRow([]);
    r++;
    sheet.appendRow([TextCellValue('По статусам')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Статус'), TextCellValue('Кол-во'), TextCellValue('Сумма'), TextCellValue('Комиссия')]);
    for (var c = 0; c < 4; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    r++;
    for (final s in TransferStatus.values) {
      final stat = byStatus[s]!;
      if (stat.count > 0) {
        sheet.appendRow([
          TextCellValue(s.displayName),
          IntCellValue(stat.count),
          TextCellValue(_fmtNum(stat.amount)),
          TextCellValue(_fmtNum(stat.commission)),
        ]);
        r++;
      }
    }

    sheet.appendRow([]);
    r++;
    sheet.appendRow([TextCellValue('По валютам')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Валюта'), TextCellValue('Сумма')]);
    for (var c = 0; c < 2; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    for (final e in byCurrency.entries.toList()..sort((a, b) => b.value.compareTo(a.value))) {
      sheet.appendRow([TextCellValue(e.key), TextCellValue(_fmtNum(e.value))]);
    }

    sheet.setColumnWidth(0, 28);
    sheet.setColumnWidth(1, 18);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 14);
  }

  static const _ledgerColDefs = [
    ('num', '№ п/п', 8.0),
    ('date', 'Дата', 12.0),
    ('doc', 'Документ', 14.0),
    ('account', 'Счёт', 14.0),
    ('accountName', 'Наименование счёта', 20.0),
    ('type', 'Тип операции', 14.0),
    ('description', 'Описание', 30.0),
    ('debit', 'Дебет', 14.0),
    ('credit', 'Кредит', 14.0),
    ('currency', 'Валюта', 10.0),
  ];

  static List<int>? _generateLedgerExcel(_LedgerExportParams params) {
    try {
      var excel = Excel.createExcel();
      Sheet sheet = excel['Журнал операций'];
      excel.setDefaultSheet('Журнал операций');
      if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');

      final enabled = params.exportSettings?.enabledColumns ??
          _ledgerColDefs.map((c) => c.$1).toSet();
      final cols = _ledgerColDefs.where((c) => enabled.contains(c.$1)).toList();
      var sorted = List<LedgerEntry>.from(params.entries)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final limit = params.exportSettings?.rowLimit;
      if (limit != null && sorted.length > limit) {
        sorted = sorted.take(limit).toList();
      }

      final period = params.startDate != null && params.endDate != null
          ? ' за период ${_fmtDate(params.startDate!)} — ${_fmtDate(params.endDate!)}'
          : '';
      final title = params.branchName.isNotEmpty
          ? 'Журнал хозяйственных операций. ${params.branchName}$period'
          : 'Журнал хозяйственных операций$period';

      sheet.appendRow([TextCellValue(title)]);
      sheet.merge(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0),
          CellIndex.indexByColumnRow(columnIndex: cols.length - 1, rowIndex: 0));
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0)).cellStyle =
          CellStyle(bold: true, fontSize: 14);
      sheet.appendRow([]);

      final headers = cols.map((c) => TextCellValue(c.$2)).toList();
      sheet.appendRow(headers);
      final headerStyle = CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
      for (var c = 0; c < cols.length; c++) {
        sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 2)).cellStyle = headerStyle;
        sheet.setColumnWidth(c, cols[c].$3);
      }

      double totalDebit = 0, totalCredit = 0;
      var n = 1;
      final altStyle = CellStyle(backgroundColorHex: ExcelColor.grey50);
      for (var i = 0; i < sorted.length; i++) {
        final e = sorted[i];
        final debit = e.type == LedgerEntryType.debit ? e.amount : 0.0;
        final credit = e.type == LedgerEntryType.credit ? e.amount : 0.0;
        totalDebit += debit;
        totalCredit += credit;
        final row = <CellValue>[];
        for (final col in cols) {
          switch (col.$1) {
            case 'num': row.add(IntCellValue(n++)); break;
            case 'date': row.add(TextCellValue(_fmtDate(e.createdAt))); break;
            case 'doc': row.add(TextCellValue(e.referenceId)); break;
            case 'account': row.add(TextCellValue(e.accountId)); break;
            case 'accountName': row.add(TextCellValue(params.accountNames[e.accountId] ?? e.accountId)); break;
            case 'type': row.add(TextCellValue(e.referenceType.displayName)); break;
            case 'description': row.add(TextCellValue(e.description)); break;
            case 'debit': row.add(TextCellValue(_fmtNum(debit))); break;
            case 'credit': row.add(TextCellValue(_fmtNum(credit))); break;
            case 'currency': row.add(TextCellValue(e.currency)); break;
            default: row.add(TextCellValue(''));
          }
        }
        sheet.appendRow(row);
        if (i % 2 == 1) {
          for (var c = 0; c < cols.length; c++) {
            sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 3 + i)).cellStyle = altStyle;
          }
        }
      }

      sheet.appendRow([]);
      final footerRow = 3 + sorted.length + 1;
      sheet.appendRow([TextCellValue('Сформировано: ${_fmtDate(DateTime.now())}')]);
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: footerRow)).cellStyle =
          CellStyle(fontSize: 10, fontColorHex: ExcelColor.grey600);

      _addLedgerSummarySheet(excel, sorted, totalDebit, totalCredit);

      return excel.encode();
    } catch (e) {
      debugPrint('Isolate Excel error: $e');
      return null;
    }
  }

  static void _addLedgerSummarySheet(Excel excel, List<LedgerEntry> entries, double totalDebit, double totalCredit) {
    final sheet = excel['Сводка'];
    var r = 0;

    sheet.appendRow([TextCellValue('Сводка по журналу операций')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, fontSize: 14);
    r++;
    sheet.appendRow([]);
    r++;

    final byType = <LedgerReferenceType, _LedgerStat>{};
    for (final t in LedgerReferenceType.values) {
      byType[t] = _LedgerStat();
    }
    final byCurrency = <String, _LedgerStat>{};
    double minAmt = double.infinity, maxAmt = 0;
    DateTime? firstDate, lastDate;
    final accountIds = <String>{};

    for (final e in entries) {
      final amt = e.amount;
      byType[e.referenceType]!.count++;
      if (e.type == LedgerEntryType.debit) byType[e.referenceType]!.debit += amt;
      if (e.type == LedgerEntryType.credit) byType[e.referenceType]!.credit += amt;
      byCurrency.putIfAbsent(e.currency, () => _LedgerStat());
      byCurrency[e.currency]!.count++;
      if (e.type == LedgerEntryType.debit) byCurrency[e.currency]!.debit += amt;
      if (e.type == LedgerEntryType.credit) byCurrency[e.currency]!.credit += amt;
      if (amt < minAmt) minAmt = amt;
      if (amt > maxAmt) maxAmt = amt;
      accountIds.add(e.accountId);
      if (firstDate == null || e.createdAt.isBefore(firstDate)) firstDate = e.createdAt;
      if (lastDate == null || e.createdAt.isAfter(lastDate)) lastDate = e.createdAt;
    }
    if (minAmt == double.infinity) minAmt = 0;

    sheet.appendRow([TextCellValue('Основные показатели')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Показатель'), TextCellValue('Значение')]);
    for (var c = 0; c < 2; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    r++;
    sheet.appendRow([TextCellValue('Количество операций'), IntCellValue(entries.length)]);
    sheet.appendRow([TextCellValue('Уникальных счетов'), IntCellValue(accountIds.length)]);
    sheet.appendRow([TextCellValue('Оборот по дебету'), TextCellValue(_fmtNum(totalDebit))]);
    sheet.appendRow([TextCellValue('Оборот по кредиту'), TextCellValue(_fmtNum(totalCredit))]);
    sheet.appendRow([TextCellValue('Сальдо (кредит - дебет)'), TextCellValue(_fmtNum(totalCredit - totalDebit))]);
    sheet.appendRow([TextCellValue('Средняя сумма операции'), TextCellValue(_fmtNum(entries.isEmpty ? 0 : (totalDebit + totalCredit) / entries.length))]);
    sheet.appendRow([TextCellValue('Мин. сумма'), TextCellValue(_fmtNum(minAmt))]);
    sheet.appendRow([TextCellValue('Макс. сумма'), TextCellValue(_fmtNum(maxAmt))]);
    if (firstDate != null && lastDate != null) {
      sheet.appendRow([TextCellValue('Период данных'), TextCellValue('${_fmtDate(firstDate)} — ${_fmtDate(lastDate)}')]);
    }
    r += 9;

    sheet.appendRow([]);
    r++;
    sheet.appendRow([TextCellValue('По типам операций')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Тип'), TextCellValue('Кол-во'), TextCellValue('Дебет'), TextCellValue('Кредит')]);
    for (var c = 0; c < 4; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    r++;
    for (final t in LedgerReferenceType.values) {
      final stat = byType[t]!;
      if (stat.count > 0) {
        sheet.appendRow([
          TextCellValue(t.displayName),
          IntCellValue(stat.count),
          TextCellValue(_fmtNum(stat.debit)),
          TextCellValue(_fmtNum(stat.credit)),
        ]);
        r++;
      }
    }

    sheet.appendRow([]);
    r++;
    sheet.appendRow([TextCellValue('По валютам')]);
    sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r)).cellStyle =
        CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    r++;
    sheet.appendRow([TextCellValue('Валюта'), TextCellValue('Кол-во'), TextCellValue('Дебет'), TextCellValue('Кредит'), TextCellValue('Сальдо')]);
    for (var c = 0; c < 5; c++) {
      sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).cellStyle =
          CellStyle(bold: true, backgroundColorHex: ExcelColor.grey200);
    }
    for (final e in byCurrency.entries.toList()..sort((a, b) => (b.value.debit + b.value.credit).compareTo(a.value.debit + a.value.credit))) {
      final s = e.value;
      sheet.appendRow([
        TextCellValue(e.key),
        IntCellValue(s.count),
        TextCellValue(_fmtNum(s.debit)),
        TextCellValue(_fmtNum(s.credit)),
        TextCellValue(_fmtNum(s.credit - s.debit)),
      ]);
    }

    sheet.setColumnWidth(0, 25);
    sheet.setColumnWidth(1, 14);
    sheet.setColumnWidth(2, 14);
    sheet.setColumnWidth(3, 14);
    sheet.setColumnWidth(4, 14);
  }

  Future<bool> exportCommissionsToExcel(
    List<Commission> commissions,
    String fileName, {
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final bytes = await compute(
        _generateCommissionsExcel,
        _CommissionsExportParams(commissions, startDate, endDate),
      );
      if (bytes != null) {
        await FileSaver.instance.saveFile(
          name: '$fileName.xlsx',
          bytes: Uint8List.fromList(bytes),
          mimeType: MimeType.microsoftExcel,
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Export commissions error: $e');
      return false;
    }
  }

  Future<bool> exportMonthlySummaryToExcel(
    List<LedgerEntry> entries,
    String fileName, {
    Map<String, String> accountNames = const {},
    String? branchName,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final bytes = await compute(
        _generateMonthlySummaryExcel,
        _MonthlySummaryParams(
          entries,
          accountNames,
          branchName ?? '',
          startDate,
          endDate,
        ),
      );
      if (bytes != null) {
        await FileSaver.instance.saveFile(
          name: '$fileName.xlsx',
          bytes: Uint8List.fromList(bytes),
          mimeType: MimeType.microsoftExcel,
        );
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('Export monthly summary error: $e');
      return false;
    }
  }

  static List<int>? _generateCommissionsExcel(_CommissionsExportParams params) {
    try {
      var excel = Excel.createExcel();
      Sheet sheet = excel['Комиссии'];
      excel.setDefaultSheet('Комиссии');
      if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');

      final period = params.startDate != null && params.endDate != null
          ? ' за период ${_fmtDate(params.startDate!)} — ${_fmtDate(params.endDate!)}'
          : '';

      sheet.appendRow([TextCellValue('Отчёт по комиссиям$period')]);
      sheet.appendRow([]);

      sheet.appendRow([
        TextCellValue('№'),
        TextCellValue('Дата'),
        TextCellValue('Сумма'),
        TextCellValue('Валюта'),
        TextCellValue('Тип'),
      ]);

      double total = 0;
      var n = 1;
      for (var c in params.commissions) {
        total += c.amount;
        sheet.appendRow([
          IntCellValue(n++),
          TextCellValue(_fmtDate(c.createdAt)),
          TextCellValue(_fmtNum(c.amount)),
          TextCellValue(c.currency),
          TextCellValue(c.type),
        ]);
      }
      sheet.appendRow([
        TextCellValue(''),
        TextCellValue('ИТОГО'),
        TextCellValue(_fmtNum(total)),
        TextCellValue(''),
        TextCellValue(''),
      ]);

      return excel.encode();
    } catch (e) {
      debugPrint('Commissions Excel error: $e');
      return null;
    }
  }

  static List<int>? _generateMonthlySummaryExcel(_MonthlySummaryParams params) {
    try {
      var excel = Excel.createExcel();
      Sheet sheet = excel['Оборотно-сальдовая'];
      excel.setDefaultSheet('Оборотно-сальдовая');
      if (excel.sheets.containsKey('Sheet1')) excel.delete('Sheet1');

      final period = params.startDate != null && params.endDate != null
          ? ' за период ${_fmtDate(params.startDate!)} — ${_fmtDate(params.endDate!)}'
          : '';
      final title = params.branchName.isNotEmpty
          ? 'Оборотно-сальдовая ведомость. ${params.branchName}$period'
          : 'Оборотно-сальдовая ведомость$period';

      sheet.appendRow([TextCellValue(title)]);
      sheet.appendRow([]);

      sheet.appendRow([
        TextCellValue('Счёт'),
        TextCellValue('Наименование счёта'),
        TextCellValue('Валюта'),
        TextCellValue('Оборот по дебету'),
        TextCellValue('Оборот по кредиту'),
        TextCellValue('Сальдо'),
        TextCellValue('Кол-во операций'),
      ]);

      final Map<String, _AccountSummary> summary = {};
      for (var e in params.entries) {
        summary.putIfAbsent(e.accountId, () => _AccountSummary(e.currency));
        final s = summary[e.accountId]!;
        if (e.type == LedgerEntryType.debit) s.debit += e.amount;
        if (e.type == LedgerEntryType.credit) s.credit += e.amount;
        s.count++;
      }

      double grandDebit = 0, grandCredit = 0;
      for (var entry in summary.entries) {
        final s = entry.value;
        final net = s.credit - s.debit;
        grandDebit += s.debit;
        grandCredit += s.credit;
        sheet.appendRow([
          TextCellValue(entry.key),
          TextCellValue(params.accountNames[entry.key] ?? entry.key),
          TextCellValue(s.currency),
          TextCellValue(_fmtNum(s.debit)),
          TextCellValue(_fmtNum(s.credit)),
          TextCellValue(_fmtNum(net)),
          IntCellValue(s.count),
        ]);
      }
      sheet.appendRow([
        TextCellValue('ИТОГО'),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(_fmtNum(grandDebit)),
        TextCellValue(_fmtNum(grandCredit)),
        TextCellValue(_fmtNum(grandCredit - grandDebit)),
        IntCellValue(params.entries.length),
      ]);

      return excel.encode();
    } catch (e) {
      debugPrint('Monthly summary Excel error: $e');
      return null;
    }
  }
}

class _AccountSummary {
  String currency;
  double debit = 0;
  double credit = 0;
  int count = 0;
  _AccountSummary(this.currency);
}

class _TransferStat {
  int count = 0;
  double amount = 0;
  double commission = 0;
}

class _LedgerStat {
  int count = 0;
  double debit = 0;
  double credit = 0;
}

class _TransferExportParams {
  final List<Transfer> transfers;
  final Map<String, String> branchNames;
  final Map<String, String> accountNames;
  final Map<String, String> userNames;
  final DateTime? startDate;
  final DateTime? endDate;
  final ExportSettings? exportSettings;
  const _TransferExportParams(
    this.transfers,
    this.branchNames,
    this.accountNames,
    this.userNames,
    this.startDate,
    this.endDate,
    this.exportSettings,
  );
}

class _LedgerExportParams {
  final List<LedgerEntry> entries;
  final Map<String, String> accountNames;
  final String branchName;
  final DateTime? startDate;
  final DateTime? endDate;
  final ExportSettings? exportSettings;
  const _LedgerExportParams(
    this.entries,
    this.accountNames,
    this.branchName,
    this.startDate,
    this.endDate,
    this.exportSettings,
  );
}

class _CommissionsExportParams {
  final List<Commission> commissions;
  final DateTime? startDate;
  final DateTime? endDate;
  const _CommissionsExportParams(
    this.commissions,
    this.startDate,
    this.endDate,
  );
}

class _MonthlySummaryParams {
  final List<LedgerEntry> entries;
  final Map<String, String> accountNames;
  final String branchName;
  final DateTime? startDate;
  final DateTime? endDate;
  const _MonthlySummaryParams(
    this.entries,
    this.accountNames,
    this.branchName,
    this.startDate,
    this.endDate,
  );
}
