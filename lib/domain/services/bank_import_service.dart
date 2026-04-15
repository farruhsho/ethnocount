import 'package:excel/excel.dart';
import 'package:flutter/foundation.dart';
import '../entities/bank_transaction.dart';

/// Column mapping for flexible bank statement import.
/// Banks use different column names; we detect common patterns.
class BankImportColumnMap {
  int? dateCol;
  int? amountCol;
  int? descriptionCol;
  int? typeCol;
  int? counterpartyCol;
  int? currencyCol;

  BankImportColumnMap({
    this.dateCol,
    this.amountCol,
    this.descriptionCol,
    this.typeCol,
    this.counterpartyCol,
    this.currencyCol,
  });

  /// Auto-detect columns from header row (Russian/English).
  static BankImportColumnMap detect(List<String> headers) {
    final map = BankImportColumnMap();
    final lower = headers.map((h) => h.toLowerCase().trim()).toList();

    for (var i = 0; i < lower.length; i++) {
      final h = lower[i];
      if (map.dateCol == null &&
          (h.contains('дата') || h.contains('date') || h == 'дата')) {
        map.dateCol = i;
      }
      if (map.amountCol == null &&
          (h.contains('сумма') || h.contains('amount') || h.contains('сумм'))) {
        map.amountCol = i;
      }
      if (map.descriptionCol == null &&
          (h.contains('описание') || h.contains('description') ||
              h.contains('назначение') || h.contains('комментарий'))) {
        map.descriptionCol = i;
      }
      if (map.typeCol == null &&
          (h.contains('тип') || h.contains('type') || h.contains('приход') ||
              h.contains('расход') || h.contains('операция'))) {
        map.typeCol = i;
      }
      if (map.counterpartyCol == null &&
          (h.contains('контрагент') || h.contains('counterparty') ||
              h.contains('получатель') || h.contains('отправитель'))) {
        map.counterpartyCol = i;
      }
      if (map.currencyCol == null &&
          (h.contains('валюта') || h.contains('currency') || h == 'валюта')) {
        map.currencyCol = i;
      }
    }

    // Fallbacks: first col = date, second = amount, third = description
    if (map.dateCol == null && headers.isNotEmpty) map.dateCol = 0;
    if (map.amountCol == null && headers.length > 1) map.amountCol = 1;
    if (map.descriptionCol == null && headers.length > 2) map.descriptionCol = 2;

    return map;
  }
}

/// Parses bank statement files (CSV, Excel) into [BankTransaction] list.
class BankImportService {
  /// Parse CSV text. Delimiter auto-detected (; or ,).
  List<BankTransaction> parseCsv(String text, {String? bankName}) {
    final lines = text.split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];

    final delimiter = text.contains(';') ? ';' : ',';
    final rows = lines.map((l) => _splitCsvLine(l, delimiter)).toList();
    final headers = rows.first;
    final map = BankImportColumnMap.detect(headers);

    final result = <BankTransaction>[];
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length < 2) continue;

      final tx = _rowToTransaction(row, map, bankName);
      if (tx != null) result.add(tx);
    }
    return result;
  }

  List<String> _splitCsvLine(String line, String delimiter) {
    final result = <String>[];
    var current = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (!inQuotes && c == delimiter) {
        result.add(current.toString().trim());
        current = StringBuffer();
      } else {
        current.write(c);
      }
    }
    result.add(current.toString().trim());
    return result;
  }

  BankTransaction? _rowToTransaction(
    List<String> row,
    BankImportColumnMap map,
    String? bankName,
  ) {
    final dateStr = map.dateCol != null && map.dateCol! < row.length
        ? row[map.dateCol!].trim()
        : '';
    final amountStr = map.amountCol != null && map.amountCol! < row.length
        ? row[map.amountCol!].trim()
        : '0';
    final desc = map.descriptionCol != null && map.descriptionCol! < row.length
        ? row[map.descriptionCol!].trim()
        : '';
    final typeStr = map.typeCol != null && map.typeCol! < row.length
        ? row[map.typeCol!].trim().toLowerCase()
        : '';
    final counterparty = map.counterpartyCol != null && map.counterpartyCol! < row.length
        ? row[map.counterpartyCol!].trim()
        : null;
    final currency = map.currencyCol != null && map.currencyCol! < row.length
        ? row[map.currencyCol!].trim()
        : 'RUB';

    final date = _parseDate(dateStr);
    if (date == null) return null;

    final amount = _parseAmount(amountStr);
    if (amount == null || amount <= 0) return null;

    final isCredit = _parseIsCredit(typeStr, amountStr);

    return BankTransaction(
      date: date,
      amount: amount,
      currency: currency.isEmpty ? 'RUB' : currency,
      description: desc.isEmpty ? 'Банковская операция' : desc,
      isCredit: isCredit,
      counterpartyRaw: counterparty?.isEmpty == true ? null : counterparty,
      bankName: bankName,
    );
  }

  DateTime? _parseDate(String s) {
    if (s.isEmpty) return null;
    // DD.MM.YYYY, DD/MM/YYYY, YYYY-MM-DD
    final parts = s.split(RegExp(r'[./\-]'));
    if (parts.length >= 3) {
      int? d, m, y;
      if (parts[0].length == 4) {
        y = int.tryParse(parts[0]);
        m = int.tryParse(parts[1]);
        d = int.tryParse(parts[2]);
      } else {
        d = int.tryParse(parts[0]);
        m = int.tryParse(parts[1]);
        y = int.tryParse(parts[2]);
      }
      if (d != null && m != null && y != null) {
        if (y < 100) y += 2000;
        try {
          return DateTime(y, m, d);
        } catch (_) {}
      }
    }
    return null;
  }

  double? _parseAmount(String s) {
    if (s.isEmpty) return null;
    final cleaned = s.replaceAll(RegExp(r'[\s\u00A0]'), '').replaceAll(',', '.');
    return double.tryParse(cleaned);
  }

  bool _parseIsCredit(String typeStr, String amountStr) {
    if (typeStr.contains('приход') || typeStr.contains('credit') ||
        typeStr.contains('поступ') || typeStr.contains('входящ')) {
      return true;
    }
    if (typeStr.contains('расход') || typeStr.contains('debit') ||
        typeStr.contains('списан') || typeStr.contains('исходящ')) {
      return false;
    }
    // If amount has minus, it's debit
    final a = _parseAmount(amountStr);
    if (a != null && a < 0) return false;
    // Default: positive = credit (incoming), negative = debit
    return a != null && a > 0;
  }

  /// Parse Excel file bytes.
  List<BankTransaction> parseExcel(List<int> bytes, {String? bankName}) {
    try {
      final excel = Excel.decodeBytes(bytes);
      final sheet = excel.tables.keys.isNotEmpty ? excel.tables[excel.tables.keys.first]! : null;
      if (sheet == null || sheet.rows.isEmpty) return [];

      final rows = sheet.rows.map((r) => r.map((c) => c?.value?.toString() ?? '').toList()).toList();
      final headers = rows.first.map((c) => c.toString()).toList();
      final map = BankImportColumnMap.detect(headers);

      final result = <BankTransaction>[];
      for (var i = 1; i < rows.length; i++) {
        final row = rows[i].map((c) => c.toString()).toList();
        if (row.length < 2) continue;
        final tx = _rowToTransaction(row, map, bankName);
        if (tx != null) result.add(tx);
      }
      return result;
    } catch (e) {
      debugPrint('BankImportService parseExcel: $e');
      return [];
    }
  }
}
