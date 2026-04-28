import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';

import '../entities/enums.dart';
import '../entities/transfer.dart';
import '../entities/transfer_issuance.dart';

/// Generates a single-transfer invoice as a Microsoft Word `.docx` document.
///
/// A `.docx` is a ZIP package with a small set of XML parts. We assemble the
/// minimal valid set: `[Content_Types].xml`, `_rels/.rels`,
/// `word/_rels/document.xml.rels`, `word/styles.xml`, `word/document.xml`.
class TransferInvoiceService {
  Future<bool> exportInvoice(
    Transfer t, {
    Map<String, String> branchNames = const {},
    Map<String, String> accountNames = const {},
    Map<String, String> userNames = const {},
    List<TransferIssuance> issuances = const [],
    String? fileNameOverride,
  }) async {
    try {
      final bytes = await compute(
        _buildDocxBytes,
        _InvoiceParams(
          t,
          branchNames,
          accountNames,
          userNames,
          issuances,
        ),
      );
      if (bytes == null) return false;

      final code = (t.transactionCode != null && t.transactionCode!.isNotEmpty)
          ? t.transactionCode!
          : t.id.substring(0, 8);
      final fileName = fileNameOverride ?? 'Инвойс ${code}_${_safeDate(t.createdAt)}';

      await FileSaver.instance.saveFile(
        name: fileName,
        bytes: bytes,
        fileExtension: 'docx',
        mimeType: MimeType.microsoftWord,
      );
      return true;
    } catch (e) {
      debugPrint('Invoice DOCX export error: $e');
      return false;
    }
  }
}

class _InvoiceParams {
  final Transfer transfer;
  final Map<String, String> branchNames;
  final Map<String, String> accountNames;
  final Map<String, String> userNames;
  final List<TransferIssuance> issuances;
  const _InvoiceParams(
    this.transfer,
    this.branchNames,
    this.accountNames,
    this.userNames,
    this.issuances,
  );
}

Uint8List? _buildDocxBytes(_InvoiceParams p) {
  try {
    final document = _renderDocumentXml(p);
    final archive = Archive()
      ..addFile(_mkFile('[Content_Types].xml', _contentTypesXml))
      ..addFile(_mkFile('_rels/.rels', _rootRelsXml))
      ..addFile(_mkFile('word/_rels/document.xml.rels', _docRelsXml))
      ..addFile(_mkFile('word/styles.xml', _stylesXml))
      ..addFile(_mkFile('word/document.xml', document));

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) return null;
    return Uint8List.fromList(encoded);
  } catch (e) {
    debugPrint('DOCX build error: $e');
    return null;
  }
}

ArchiveFile _mkFile(String name, String content) {
  final bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

// ─── Formatting ───────────────────────────────────────────────────────────

String _safeDate(DateTime d) =>
    '${d.year}-${_pad(d.month)}-${_pad(d.day)}';

String _pad(int n) => n.toString().padLeft(2, '0');

String _fmtDateTime(DateTime d) =>
    '${_pad(d.day)}.${_pad(d.month)}.${d.year} ${_pad(d.hour)}:${_pad(d.minute)}';

String _fmtNum(double v) {
  final neg = v < 0;
  final abs = neg ? -v : v;
  final s = abs.toStringAsFixed(2);
  final parts = s.split('.');
  final intPart = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(' ');
    buf.write(intPart[i]);
  }
  final dec = parts[1];
  return '${neg ? '-' : ''}${buf.toString()},$dec';
}

String _fmtMoney(double v, String currency) =>
    '${_fmtNum(v)} $currency';

/// XML-escape a user-supplied string before injecting into the document.
String _xml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

String _branch(_InvoiceParams p, String id) =>
    p.branchNames[id]?.trim().isNotEmpty == true
        ? p.branchNames[id]!
        : id;

String _account(_InvoiceParams p, String id) =>
    p.accountNames[id]?.trim().isNotEmpty == true
        ? p.accountNames[id]!
        : id;

String _user(_InvoiceParams p, String? id) {
  if (id == null || id.isEmpty) return '—';
  final n = p.userNames[id];
  return (n != null && n.isNotEmpty) ? n : id.substring(0, id.length.clamp(0, 8));
}

String _statusRu(TransferStatus s) => s.displayName;

String _commissionModeRu(CommissionMode m) {
  switch (m) {
    case CommissionMode.fromSender:
      return 'Отдельно с отправителя';
    case CommissionMode.fromTransfer:
      return 'Внутри суммы перевода';
    case CommissionMode.toReceiver:
      return 'Сверх суммы (получателю)';
  }
}

// ─── Document body ────────────────────────────────────────────────────────

String _renderDocumentXml(_InvoiceParams p) {
  final t = p.transfer;
  final code = (t.transactionCode != null && t.transactionCode!.isNotEmpty)
      ? t.transactionCode!
      : t.id;

  final fromBranch = _branch(p, t.fromBranchId);
  final toBranch = _branch(p, t.toBranchId);

  final body = StringBuffer();

  // Header — title + meta
  body.write(_p('ИНВОЙС № ${_xml(code)}',
      bold: true, size: 36, align: 'center'));
  body.write(_p(
    'Дата создания: ${_fmtDateTime(t.createdAt)}    •    Статус: ${_statusRu(t.status)}',
    align: 'center', size: 20, color: '666666',
  ));
  body.write(_emptyParagraph());

  // Parties — two-column table
  body.write(_partiesTable(p, t, fromBranch, toBranch));
  body.write(_emptyParagraph());

  // Amounts — split parts or simple
  body.write(_p('Финансовые показатели', bold: true, size: 26));
  body.write(_amountsTable(p, t));
  body.write(_emptyParagraph());

  // Commission block
  if (t.commission > 0) {
    body.write(_p('Комиссия', bold: true, size: 26));
    body.write(_kvTable([
      ('Сумма комиссии', _fmtMoney(t.commission, t.commissionCurrency)),
      ('Тип', t.commissionType == CommissionType.fixed
          ? 'Фиксированная'
          : 'Процент: ${_fmtNum(t.commissionValue)} %'),
      ('Режим', _commissionModeRu(t.commissionMode)),
    ]));
    body.write(_emptyParagraph());
  }

  // Description
  if (t.description != null && t.description!.trim().isNotEmpty) {
    body.write(_p('Назначение платежа', bold: true, size: 26));
    body.write(_p(t.description!.trim(), size: 22));
    body.write(_emptyParagraph());
  }

  // Issuance progress and history (partial payouts).
  if (t.issuedAmount > 0 || p.issuances.isNotEmpty || t.isIssued) {
    body.write(_p('Выдача получателю', bold: true, size: 26));
    body.write(_issuanceSummaryTable(t));
    if (p.issuances.isNotEmpty) {
      body.write(_emptyParagraph());
      body.write(_p('История выдач', bold: true, size: 22));
      body.write(_issuanceHistoryTable(p));
    }
    body.write(_emptyParagraph());
  }

  // Lifecycle & signatures
  body.write(_p('Подписи и операции', bold: true, size: 26));
  body.write(_kvTable(_signatureRows(p, t)));
  body.write(_emptyParagraph());

  // Amendment history
  if (t.amendmentHistory.isNotEmpty) {
    body.write(_p('История изменений', bold: true, size: 26));
    body.write(_amendmentHistoryTable(p, t));
    body.write(_emptyParagraph());
  }

  // Footer
  body.write(_p(
    'Документ сформирован автоматически системой EthnoCount • ${_fmtDateTime(DateTime.now())}',
    align: 'center', size: 16, color: '888888', italic: true,
  ));

  return _wrapDocument(body.toString());
}

String _partiesTable(_InvoiceParams p, Transfer t, String fromBranch, String toBranch) {
  final fromCellInner = StringBuffer()
    ..write(_p('ОТПРАВИТЕЛЬ', bold: true, size: 22, color: '1F3A93'))
    ..write(_p('Филиал: ${_xml(fromBranch)}', size: 20))
    ..write(_p('Счёт: ${_xml(_account(p, t.fromAccountId))}', size: 20));
  if (t.senderName != null && t.senderName!.trim().isNotEmpty) {
    fromCellInner.write(_p('Имя: ${_xml(t.senderName!)}', size: 20));
  }
  if (t.senderPhone != null && t.senderPhone!.trim().isNotEmpty) {
    fromCellInner.write(_p('Телефон: ${_xml(t.senderPhone!)}', size: 20));
  }
  if (t.senderInfo != null && t.senderInfo!.trim().isNotEmpty) {
    fromCellInner.write(_p('Реквизиты: ${_xml(t.senderInfo!)}', size: 20));
  }

  final toCellInner = StringBuffer()
    ..write(_p('ПОЛУЧАТЕЛЬ', bold: true, size: 22, color: '1F3A93'))
    ..write(_p('Филиал: ${_xml(toBranch)}', size: 20));
  if (t.toAccountId.isNotEmpty) {
    toCellInner.write(_p('Счёт: ${_xml(_account(p, t.toAccountId))}', size: 20));
  }
  if (t.receiverName != null && t.receiverName!.trim().isNotEmpty) {
    toCellInner.write(_p('Имя: ${_xml(t.receiverName!)}', size: 20));
  }
  if (t.receiverPhone != null && t.receiverPhone!.trim().isNotEmpty) {
    toCellInner.write(_p('Телефон: ${_xml(t.receiverPhone!)}', size: 20));
  }
  if (t.receiverInfo != null && t.receiverInfo!.trim().isNotEmpty) {
    toCellInner.write(_p('Реквизиты: ${_xml(t.receiverInfo!)}', size: 20));
  }

  // Wrap each side as a pre-shaded "cellPara" so the table builder applies
  // background colour consistently with other tables.
  final fromMarked = '__SHADE__:F0F4FF__START__${fromCellInner.toString()}__END__';
  final toMarked = '__SHADE__:F0F4FF__START__${toCellInner.toString()}__END__';
  return _tableRaw(
    widthsTwips: [4500, 4500],
    rows: [[fromMarked, toMarked]],
    border: true,
  );
}

String _amountsTable(_InvoiceParams p, Transfer t) {
  final rows = <List<String>>[];

  // Header row
  rows.add([
    _cellPara('Показатель', bold: true, shade: 'E8ECF7'),
    _cellPara('Сумма', bold: true, align: 'right', shade: 'E8ECF7'),
    _cellPara('Валюта', bold: true, align: 'center', shade: 'E8ECF7'),
  ]);

  if (t.isSplitCurrency) {
    rows.add([
      _cellPara('Разделение по счетам отправителя', bold: true, italic: true),
      _cellPara('', italic: true),
      _cellPara('', italic: true),
    ]);
    for (final part in t.transferParts!) {
      final accName = part.accountName.isNotEmpty
          ? part.accountName
          : _account(p, part.accountId);
      rows.add([
        _cellPara('  • Счёт «${_xml(accName)}»'),
        _cellPara(_fmtNum(part.amount), align: 'right', mono: true),
        _cellPara(part.currency, align: 'center'),
      ]);
    }
    rows.add([
      _cellPara('Итого по переводу (отправитель)', bold: true, shade: 'F7F8FA'),
      _cellPara(_fmtNum(t.amount), bold: true, align: 'right', mono: true, shade: 'F7F8FA'),
      _cellPara(t.currency, bold: true, align: 'center', shade: 'F7F8FA'),
    ]);
  } else {
    rows.add([
      _cellPara('Сумма перевода'),
      _cellPara(_fmtNum(t.amount), align: 'right', mono: true),
      _cellPara(t.currency, align: 'center'),
    ]);
  }

  // Cross-currency
  final recvCur = t.toCurrency ?? t.currency;
  if (recvCur != t.currency) {
    rows.add([
      _cellPara('Курс ${t.currency} → $recvCur'),
      _cellPara(_fmtNum(t.exchangeRate), align: 'right', mono: true),
      _cellPara('—', align: 'center'),
    ]);
    rows.add([
      _cellPara('Конвертированная сумма'),
      _cellPara(_fmtNum(t.convertedAmount), align: 'right', mono: true),
      _cellPara(recvCur, align: 'center'),
    ]);
  }

  if (t.commission > 0) {
    rows.add([
      _cellPara('Комиссия (${_commissionModeRu(t.commissionMode)})'),
      _cellPara(_fmtNum(t.commission), align: 'right', mono: true),
      _cellPara(t.commissionCurrency, align: 'center'),
    ]);
  }

  // Totals
  rows.add([
    _cellPara('Списание с отправителя (Дебет)',
        bold: true, shade: 'FFF1F0', color: '8B2A1F'),
    _cellPara(_fmtNum(t.totalDebitAmount),
        bold: true, align: 'right', mono: true, shade: 'FFF1F0', color: '8B2A1F'),
    _cellPara(t.currency,
        bold: true, align: 'center', shade: 'FFF1F0', color: '8B2A1F'),
  ]);

  final receiverGets = t.status.isFinal ? t.convertedAmount : t.receiverGetsConverted;
  rows.add([
    _cellPara('Получатель получит (Кредит)',
        bold: true, shade: 'EFFAEC', color: '1F6B2C'),
    _cellPara(_fmtNum(receiverGets),
        bold: true, align: 'right', mono: true, shade: 'EFFAEC', color: '1F6B2C'),
    _cellPara(recvCur, bold: true, align: 'center', shade: 'EFFAEC', color: '1F6B2C'),
  ]);

  return _tableRaw(
    widthsTwips: [4800, 2400, 1800],
    rows: rows,
    border: true,
  );
}

List<(String, String)> _signatureRows(_InvoiceParams p, Transfer t) {
  final rows = <(String, String)>[];
  rows.add(('Создал перевод',
      '${_user(p, t.createdBy)}    ${_fmtDateTime(t.createdAt)}'));

  if (t.confirmedAt != null) {
    rows.add(('Подтвердил (принял)',
        '${_user(p, t.confirmedBy)}    ${_fmtDateTime(t.confirmedAt!)}'));
  }
  if (t.issuedAt != null) {
    rows.add(('Выдал получателю',
        '${_user(p, t.issuedBy)}    ${_fmtDateTime(t.issuedAt!)}'));
  }
  if (t.rejectedAt != null) {
    final reason = (t.rejectionReason != null && t.rejectionReason!.trim().isNotEmpty)
        ? '    Причина: ${t.rejectionReason!.trim()}'
        : '';
    rows.add(('Отклонил',
        '${_user(p, t.rejectedBy)}    ${_fmtDateTime(t.rejectedAt!)}$reason'));
  }
  if (t.cancelledAt != null) {
    final reason = (t.cancellationReason != null && t.cancellationReason!.trim().isNotEmpty)
        ? '    Причина: ${t.cancellationReason!.trim()}'
        : '';
    rows.add(('Отменил',
        '${_user(p, t.cancelledBy)}    ${_fmtDateTime(t.cancelledAt!)}$reason'));
  }
  return rows;
}

String _issuanceSummaryTable(Transfer t) {
  final cur = t.toCurrency ?? t.currency;
  final remaining = t.convertedAmount - t.issuedAmount < 0
      ? 0.0
      : t.convertedAmount - t.issuedAmount;
  final pct = t.convertedAmount > 0
      ? ((t.issuedAmount / t.convertedAmount) * 100).clamp(0, 100)
      : 0.0;

  String shadeForRemaining;
  String colorForRemaining;
  if (remaining <= 1e-6) {
    shadeForRemaining = 'EFFAEC';
    colorForRemaining = '1F6B2C';
  } else if (t.issuedAmount > 0) {
    shadeForRemaining = 'FFF7E6';
    colorForRemaining = '8A5A00';
  } else {
    shadeForRemaining = 'F4F6FB';
    colorForRemaining = '000000';
  }

  return _tableRaw(
    widthsTwips: [4800, 2400, 1800],
    rows: [
      [
        _cellPara('Показатель', bold: true, shade: 'E8ECF7'),
        _cellPara('Сумма', bold: true, align: 'right', shade: 'E8ECF7'),
        _cellPara('Валюта', bold: true, align: 'center', shade: 'E8ECF7'),
      ],
      [
        _cellPara('К выдаче (полная сумма перевода)'),
        _cellPara(_fmtNum(t.convertedAmount), align: 'right', mono: true),
        _cellPara(cur, align: 'center'),
      ],
      [
        _cellPara('Уже выдано'),
        _cellPara(_fmtNum(t.issuedAmount), align: 'right', mono: true),
        _cellPara(cur, align: 'center'),
      ],
      [
        _cellPara('Остаток к выдаче',
            bold: true, shade: shadeForRemaining, color: colorForRemaining),
        _cellPara(_fmtNum(remaining),
            bold: true, align: 'right', mono: true,
            shade: shadeForRemaining, color: colorForRemaining),
        _cellPara(cur, bold: true, align: 'center',
            shade: shadeForRemaining, color: colorForRemaining),
      ],
      [
        _cellPara('Процент выдачи'),
        _cellPara('${pct.toStringAsFixed(1)} %', align: 'right', mono: true),
        _cellPara('—', align: 'center'),
      ],
    ],
    border: true,
  );
}

String _issuanceHistoryTable(_InvoiceParams p) {
  final rows = <List<String>>[];
  rows.add([
    _cellPara('№', bold: true, shade: 'E8ECF7', align: 'center'),
    _cellPara('Дата', bold: true, shade: 'E8ECF7'),
    _cellPara('Сумма', bold: true, shade: 'E8ECF7', align: 'right'),
    _cellPara('Валюта', bold: true, shade: 'E8ECF7', align: 'center'),
    _cellPara('Выдал', bold: true, shade: 'E8ECF7'),
    _cellPara('Комментарий', bold: true, shade: 'E8ECF7'),
  ]);
  for (var i = 0; i < p.issuances.length; i++) {
    final it = p.issuances[i];
    rows.add([
      _cellPara('${i + 1}', align: 'center'),
      _cellPara(_fmtDateTime(it.issuedAt)),
      _cellPara(_fmtNum(it.amount), align: 'right', mono: true),
      _cellPara(it.currency, align: 'center'),
      _cellPara(_user(p, it.issuedBy)),
      _cellPara(it.note ?? '—'),
    ]);
  }
  return _tableRaw(
    widthsTwips: [600, 1900, 1500, 1100, 1900, 2000],
    rows: rows,
    border: true,
  );
}

String _amendmentHistoryTable(_InvoiceParams p, Transfer t) {
  final rows = <List<String>>[];
  rows.add([
    _cellPara('Дата', bold: true, shade: 'E8ECF7'),
    _cellPara('Пользователь', bold: true, shade: 'E8ECF7'),
    _cellPara('Изменения', bold: true, shade: 'E8ECF7'),
  ]);
  for (final e in t.amendmentHistory) {
    final changes = StringBuffer();
    e.changes.forEach((field, val) {
      String fromTo = '';
      if (val is Map) {
        final from = val['from'];
        final to = val['to'];
        fromTo = '${_xml(from?.toString() ?? '—')} → ${_xml(to?.toString() ?? '—')}';
      } else {
        fromTo = _xml(val.toString());
      }
      changes.writeln('$field: $fromTo');
    });
    if (e.note != null && e.note!.trim().isNotEmpty) {
      changes.writeln('Прим.: ${_xml(e.note!.trim())}');
    }
    rows.add([
      _cellPara(_fmtDateTime(e.at)),
      _cellPara(_xml(_user(p, e.userId))),
      _cellPara(changes.toString().trim().isEmpty
          ? '—'
          : changes.toString().trim()),
    ]);
  }
  return _tableRaw(
    widthsTwips: [2200, 2400, 4400],
    rows: rows,
    border: true,
  );
}

// ─── Low-level XML builders ───────────────────────────────────────────────

/// Wrap a body string into a complete `word/document.xml`.
String _wrapDocument(String bodyXml) {
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>'
      '$bodyXml'
      '<w:sectPr>'
      '<w:pgSz w:w="11906" w:h="16838"/>'
      '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="720" w:footer="720" w:gutter="0"/>'
      '</w:sectPr>'
      '</w:body>'
      '</w:document>';
}

String _emptyParagraph() => '<w:p/>';

/// One paragraph with formatting options. `size` is half-points (e.g. 24 → 12pt).
String _p(
  String text, {
  bool bold = false,
  bool italic = false,
  int size = 22,
  String color = '000000',
  String? align,
  bool mono = false,
}) {
  final pPr = StringBuffer('<w:pPr>');
  if (align != null) pPr.write('<w:jc w:val="$align"/>');
  pPr.write('<w:spacing w:after="60"/>');
  pPr.write('</w:pPr>');

  final rPr = StringBuffer('<w:rPr>');
  if (bold) rPr.write('<w:b/><w:bCs/>');
  if (italic) rPr.write('<w:i/><w:iCs/>');
  rPr.write('<w:sz w:val="$size"/><w:szCs w:val="$size"/>');
  rPr.write('<w:color w:val="$color"/>');
  if (mono) {
    rPr.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>');
  }
  rPr.write('</w:rPr>');

  return '<w:p>$pPr<w:r>$rPr<w:t xml:space="preserve">${_xml(text)}</w:t></w:r></w:p>';
}

/// Pre-formatted cell paragraph (used as table cell content).
String _cellPara(
  String text, {
  bool bold = false,
  bool italic = false,
  int size = 20,
  String color = '000000',
  String? align,
  bool mono = false,
  String? shade,
}) {
  final pPr = StringBuffer('<w:pPr>');
  if (align != null) pPr.write('<w:jc w:val="$align"/>');
  pPr.write('<w:spacing w:after="0"/>');
  pPr.write('</w:pPr>');

  final rPr = StringBuffer('<w:rPr>');
  if (bold) rPr.write('<w:b/><w:bCs/>');
  if (italic) rPr.write('<w:i/><w:iCs/>');
  rPr.write('<w:sz w:val="$size"/><w:szCs w:val="$size"/>');
  rPr.write('<w:color w:val="$color"/>');
  if (mono) {
    rPr.write('<w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/>');
  }
  rPr.write('</w:rPr>');

  // Multi-line support: split on newline, keep paragraph breaks.
  final lines = text.split('\n');
  final inner = StringBuffer();
  for (var i = 0; i < lines.length; i++) {
    final ln = lines[i];
    if (i > 0) {
      inner.write('</w:p><w:p>$pPr');
    }
    inner.write('<w:r>$rPr<w:t xml:space="preserve">${_xml(ln)}</w:t></w:r>');
  }

  // Shading on the cell properties — emit alongside through `_cell`.
  return '__SHADE__:${shade ?? ''}__START__'
      '<w:p>$pPr$inner</w:p>'
      '__END__';
}

/// Build a table from a 2D matrix where each cell is a single `_cellPara` string.
/// Extracts the shading marker so we can apply it as cell shading.
String _tableRaw({
  required List<int> widthsTwips,
  required List<List<String>> rows,
  bool border = false,
}) {
  final tblPr = StringBuffer('<w:tblPr>');
  tblPr.write('<w:tblW w:w="${widthsTwips.fold<int>(0, (a, b) => a + b)}" w:type="dxa"/>');
  tblPr.write('<w:jc w:val="center"/>');
  if (border) {
    tblPr.write(
      '<w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:space="0" w:color="C8CFE0"/>'
      '<w:left w:val="single" w:sz="4" w:space="0" w:color="C8CFE0"/>'
      '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="C8CFE0"/>'
      '<w:right w:val="single" w:sz="4" w:space="0" w:color="C8CFE0"/>'
      '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="E0E5F0"/>'
      '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="E0E5F0"/>'
      '</w:tblBorders>',
    );
  }
  tblPr.write('<w:tblLayout w:type="fixed"/>');
  tblPr.write('</w:tblPr>');

  final grid = StringBuffer('<w:tblGrid>');
  for (final w in widthsTwips) {
    grid.write('<w:gridCol w:w="$w"/>');
  }
  grid.write('</w:tblGrid>');

  final body = StringBuffer();
  for (final row in rows) {
    body.write('<w:tr>');
    for (var i = 0; i < row.length; i++) {
      final raw = row[i];
      String content = raw;
      String? shade;
      // Decode shading marker emitted by _cellPara.
      const prefix = '__SHADE__:';
      const startTag = '__START__';
      const endTag = '__END__';
      if (raw.startsWith(prefix)) {
        final shadeEnd = raw.indexOf(startTag);
        shade = raw.substring(prefix.length, shadeEnd);
        if (shade.isEmpty) shade = null;
        final inner = raw.substring(shadeEnd + startTag.length, raw.length - endTag.length);
        content = inner;
      }
      final tcPr = StringBuffer('<w:tcPr>');
      tcPr.write('<w:tcW w:w="${widthsTwips[i]}" w:type="dxa"/>');
      if (shade != null) {
        tcPr.write('<w:shd w:val="clear" w:color="auto" w:fill="$shade"/>');
      }
      tcPr.write(
        '<w:tcMar><w:top w:w="80" w:type="dxa"/><w:left w:w="120" w:type="dxa"/>'
        '<w:bottom w:w="80" w:type="dxa"/><w:right w:w="120" w:type="dxa"/></w:tcMar>',
      );
      tcPr.write('</w:tcPr>');
      body.write('<w:tc>$tcPr$content</w:tc>');
    }
    body.write('</w:tr>');
  }

  return '<w:tbl>$tblPr$grid$body</w:tbl>';
}

/// Two-column key/value table: useful for label-value lists.
String _kvTable(List<(String, String)> rows) {
  final matrix = <List<String>>[];
  for (final row in rows) {
    matrix.add([
      _cellPara(row.$1, bold: true, shade: 'F4F6FB'),
      _cellPara(row.$2),
    ]);
  }
  return _tableRaw(
    widthsTwips: [3200, 5800],
    rows: matrix,
    border: true,
  );
}


// ─── Static DOCX parts ────────────────────────────────────────────────────

const String _contentTypesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '<Default Extension="xml" ContentType="application/xml"/>'
    '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
    '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
    '</Types>';

const String _rootRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
    '</Relationships>';

const String _docRelsXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
    '</Relationships>';

const String _stylesXml = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:docDefaults>'
    '<w:rPrDefault>'
    '<w:rPr>'
    '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri" w:eastAsia="Calibri"/>'
    '<w:sz w:val="22"/><w:szCs w:val="22"/>'
    '<w:lang w:val="ru-RU" w:eastAsia="ru-RU" w:bidi="ar-SA"/>'
    '</w:rPr>'
    '</w:rPrDefault>'
    '<w:pPrDefault>'
    '<w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr>'
    '</w:pPrDefault>'
    '</w:docDefaults>'
    '<w:style w:type="paragraph" w:styleId="Normal" w:default="1">'
    '<w:name w:val="Normal"/>'
    '<w:qFormat/>'
    '</w:style>'
    '</w:styles>';
