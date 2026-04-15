import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import { getStorage } from 'firebase-admin/storage';
import * as ExcelJS from 'exceljs';

type ReportType = 'ledger' | 'transfers' | 'commissions' | 'monthly_summary';

async function verifyPermissions(db: admin.firestore.Firestore, uid: string, branchId?: string) {
    const userDoc = await db.collection('users').doc(uid).get();
    if (!userDoc.exists) throw new HttpsError('permission-denied', 'User profile not found.');
    const userData = userDoc.data();
    const isAdmin = userData?.role === 'admin';
    const assigned = userData?.assignedBranchIds || [];
    if (branchId && !isAdmin && !assigned.includes(branchId)) {
        throw new HttpsError('permission-denied', 'Unauthorized for this branch.');
    }
    return { isAdmin, assigned };
}

function applyHeaderStyle(row: ExcelJS.Row) {
    row.eachCell((cell: ExcelJS.Cell) => {
        cell.font = { bold: true, size: 11 };
        cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF2D3748' } };
        cell.font = { bold: true, size: 11, color: { argb: 'FFFFFFFF' } };
        cell.alignment = { vertical: 'middle', horizontal: 'center' };
        cell.border = {
            bottom: { style: 'thin', color: { argb: 'FF4A5568' } },
        };
    });
    row.height = 24;
}

function formatCurrencyColumn(ws: ExcelJS.Worksheet, colNum: number) {
    ws.getColumn(colNum).numFmt = '#,##0.00';
    ws.getColumn(colNum).alignment = { horizontal: 'right' };
}

export const exportReport = onCall({ timeoutSeconds: 120, memory: '512MiB' }, async (request) => {
    const { data, auth } = request;
    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    const { reportType, branchId, startDate, endDate } = data as {
        reportType: ReportType;
        branchId?: string;
        startDate?: string;
        endDate?: string;
    };

    if (!reportType) throw new HttpsError('invalid-argument', 'reportType is required.');

    const db = admin.firestore();
    await verifyPermissions(db, auth.uid, branchId);

    const workbook = new ExcelJS.Workbook();
    workbook.creator = 'EthnoCount';
    workbook.created = new Date();

    switch (reportType) {
        case 'ledger':
            await buildLedgerReport(workbook, db, branchId!, startDate, endDate);
            break;
        case 'transfers':
            await buildTransfersReport(workbook, db, branchId, startDate, endDate);
            break;
        case 'commissions':
            await buildCommissionsReport(workbook, db, startDate, endDate);
            break;
        case 'monthly_summary':
            await buildMonthlySummaryReport(workbook, db, branchId!, startDate, endDate);
            break;
        default:
            throw new HttpsError('invalid-argument', `Unknown report type: ${reportType}`);
    }

    const buffer = await workbook.xlsx.writeBuffer();
    const bucket = getStorage().bucket();
    const fileName = `exports/${reportType}_${branchId || 'all'}_${Date.now()}.xlsx`;
    const file = bucket.file(fileName);

    await file.save(Buffer.from(buffer as ArrayBuffer), {
        contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    });

    const [url] = await file.getSignedUrl({
        action: 'read',
        expires: Date.now() + 15 * 60 * 1000,
    });

    const auditRef = db.collection('auditLogs').doc();
    await auditRef.set({
        action: 'export_report',
        entityType: 'report',
        entityId: fileName,
        performedBy: auth.uid,
        details: { reportType, branchId, startDate, endDate },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return { success: true, downloadUrl: url, fileName };
});

// ─── Ledger Report ───

async function buildLedgerReport(
    workbook: ExcelJS.Workbook,
    db: admin.firestore.Firestore,
    branchId: string,
    startDate?: string,
    endDate?: string,
) {
    const ws = workbook.addWorksheet('Журнал операций');

    ws.columns = [
        { header: 'ID записи', key: 'id', width: 14 },
        { header: 'Дата и время', key: 'date', width: 20 },
        { header: 'Счёт', key: 'accountId', width: 14 },
        { header: 'Тип операции', key: 'refType', width: 16 },
        { header: 'Ссылка', key: 'refId', width: 14 },
        { header: 'Описание', key: 'description', width: 40 },
        { header: 'Дебет', key: 'debit', width: 14 },
        { header: 'Кредит', key: 'credit', width: 14 },
        { header: 'Валюта', key: 'currency', width: 10 },
        { header: 'Ответственный', key: 'createdBy', width: 14 },
    ];

    applyHeaderStyle(ws.getRow(1));
    formatCurrencyColumn(ws, 7);
    formatCurrencyColumn(ws, 8);

    let query: admin.firestore.Query = db.collection('ledgerEntries').where('branchId', '==', branchId);
    if (startDate) query = query.where('createdAt', '>=', new Date(startDate));
    if (endDate) query = query.where('createdAt', '<=', new Date(endDate));
    query = query.orderBy('createdAt', 'desc');

    const snapshot = await query.get();

    snapshot.forEach((doc) => {
        const e = doc.data();
        const createdAt = e.createdAt?.toDate ? e.createdAt.toDate().toISOString() : '';
        ws.addRow({
            id: doc.id,
            date: createdAt,
            accountId: e.accountId,
            refType: e.referenceType,
            refId: e.referenceId,
            description: e.description,
            debit: e.type === 'debit' ? e.amount : 0,
            credit: e.type === 'credit' ? e.amount : 0,
            currency: e.currency,
            createdBy: e.createdBy,
        });
    });

    ws.autoFilter = { from: 'A1', to: `J${snapshot.size + 1}` };
}

// ─── Transfers Report ───

async function buildTransfersReport(
    workbook: ExcelJS.Workbook,
    db: admin.firestore.Firestore,
    branchId?: string,
    startDate?: string,
    endDate?: string,
) {
    const ws = workbook.addWorksheet('Переводы');

    ws.columns = [
        { header: 'ID перевода', key: 'id', width: 14 },
        { header: 'Дата', key: 'date', width: 20 },
        { header: 'Отправитель (филиал)', key: 'fromBranch', width: 18 },
        { header: 'Получатель (филиал)', key: 'toBranch', width: 18 },
        { header: 'Счёт отправителя', key: 'fromAccount', width: 14 },
        { header: 'Счёт получателя', key: 'toAccount', width: 14 },
        { header: 'Сумма', key: 'amount', width: 14 },
        { header: 'Валюта', key: 'currency', width: 10 },
        { header: 'Валюта получателя', key: 'toCurrency', width: 16 },
        { header: 'Курс', key: 'rate', width: 10 },
        { header: 'Конвертировано', key: 'converted', width: 14 },
        { header: 'Комиссия', key: 'commission', width: 12 },
        { header: 'Вал. комиссии', key: 'commCurrency', width: 12 },
        { header: 'Статус', key: 'status', width: 14 },
        { header: 'Создал', key: 'createdBy', width: 14 },
        { header: 'Подтвердил', key: 'confirmedBy', width: 14 },
        { header: 'Дата подтверждения', key: 'confirmedAt', width: 20 },
        { header: 'Причина отклонения', key: 'rejectionReason', width: 25 },
    ];

    applyHeaderStyle(ws.getRow(1));
    [7, 11, 12].forEach(c => formatCurrencyColumn(ws, c));
    ws.getColumn(10).numFmt = '#,##0.0000';

    let query: admin.firestore.Query = db.collection('transfers').orderBy('createdAt', 'desc');
    if (branchId) query = query.where('fromBranchId', '==', branchId);
    if (startDate) query = query.where('createdAt', '>=', new Date(startDate));
    if (endDate) query = query.where('createdAt', '<=', new Date(endDate));

    // Load branch names for human-readable output
    const branchSnap = await db.collection('branches').get();
    const branchMap: Record<string, string> = {};
    branchSnap.forEach(d => { branchMap[d.id] = d.data().name || d.id; });

    const snapshot = await query.get();

    snapshot.forEach((doc) => {
        const t = doc.data();
        ws.addRow({
            id: doc.id,
            date: t.createdAt?.toDate ? t.createdAt.toDate().toISOString() : '',
            fromBranch: branchMap[t.fromBranchId] || t.fromBranchId,
            toBranch: branchMap[t.toBranchId] || t.toBranchId,
            fromAccount: t.fromAccountId,
            toAccount: t.toAccountId,
            amount: t.amount,
            currency: t.currency,
            toCurrency: t.toCurrency || '',
            rate: t.exchangeRate,
            converted: t.convertedAmount,
            commission: t.commission || 0,
            commCurrency: t.commissionCurrency || t.currency,
            status: t.status,
            createdBy: t.createdBy,
            confirmedBy: t.confirmedBy || '',
            confirmedAt: t.confirmedAt?.toDate ? t.confirmedAt.toDate().toISOString() : '',
            rejectionReason: t.rejectionReason || '',
        });
    });

    ws.autoFilter = { from: 'A1', to: `R${snapshot.size + 1}` };
}

// ─── Commissions Report ───

async function buildCommissionsReport(
    workbook: ExcelJS.Workbook,
    db: admin.firestore.Firestore,
    startDate?: string,
    endDate?: string,
) {
    const ws = workbook.addWorksheet('Комиссии');

    ws.columns = [
        { header: 'ID', key: 'id', width: 14 },
        { header: 'ID перевода', key: 'transferId', width: 14 },
        { header: 'Сумма', key: 'amount', width: 14 },
        { header: 'Валюта', key: 'currency', width: 10 },
        { header: 'Тип', key: 'type', width: 14 },
        { header: 'Дата', key: 'date', width: 20 },
    ];

    applyHeaderStyle(ws.getRow(1));
    formatCurrencyColumn(ws, 3);

    let query: admin.firestore.Query = db.collection('commissions').orderBy('createdAt', 'desc');
    if (startDate) query = query.where('createdAt', '>=', new Date(startDate));
    if (endDate) query = query.where('createdAt', '<=', new Date(endDate));

    const snapshot = await query.get();

    let totalCommission = 0;
    snapshot.forEach((doc) => {
        const c = doc.data();
        totalCommission += c.amount || 0;
        ws.addRow({
            id: doc.id,
            transferId: c.transferId,
            amount: c.amount,
            currency: c.currency,
            type: c.type,
            date: c.createdAt?.toDate ? c.createdAt.toDate().toISOString() : '',
        });
    });

    // Summary row
    const sumRow = ws.addRow({ id: '', transferId: 'ИТОГО', amount: totalCommission, currency: '', type: '', date: '' });
    sumRow.font = { bold: true };

    ws.autoFilter = { from: 'A1', to: `F${snapshot.size + 1}` };
}

// ─── Monthly Summary ───

async function buildMonthlySummaryReport(
    workbook: ExcelJS.Workbook,
    db: admin.firestore.Firestore,
    branchId: string,
    startDate?: string,
    endDate?: string,
) {
    const ws = workbook.addWorksheet('Ежемесячный отчёт');

    ws.columns = [
        { header: 'Счёт', key: 'accountId', width: 14 },
        { header: 'Валюта', key: 'currency', width: 10 },
        { header: 'Всего дебет', key: 'totalDebit', width: 16 },
        { header: 'Всего кредит', key: 'totalCredit', width: 16 },
        { header: 'Нетто', key: 'net', width: 16 },
        { header: 'Кол-во операций', key: 'txCount', width: 16 },
    ];

    applyHeaderStyle(ws.getRow(1));
    [3, 4, 5].forEach(c => formatCurrencyColumn(ws, c));

    let query: admin.firestore.Query = db.collection('ledgerEntries').where('branchId', '==', branchId);
    if (startDate) query = query.where('createdAt', '>=', new Date(startDate));
    if (endDate) query = query.where('createdAt', '<=', new Date(endDate));

    const snapshot = await query.get();

    const accountSummary: Record<string, { currency: string; debit: number; credit: number; count: number }> = {};

    snapshot.forEach((doc) => {
        const e = doc.data();
        const key = e.accountId;
        if (!accountSummary[key]) {
            accountSummary[key] = { currency: e.currency, debit: 0, credit: 0, count: 0 };
        }
        if (e.type === 'debit') accountSummary[key].debit += e.amount;
        if (e.type === 'credit') accountSummary[key].credit += e.amount;
        accountSummary[key].count++;
    });

    let grandDebit = 0, grandCredit = 0;
    for (const [accountId, data] of Object.entries(accountSummary)) {
        const net = data.credit - data.debit;
        grandDebit += data.debit;
        grandCredit += data.credit;
        ws.addRow({
            accountId,
            currency: data.currency,
            totalDebit: data.debit,
            totalCredit: data.credit,
            net,
            txCount: data.count,
        });
    }

    const sumRow = ws.addRow({
        accountId: 'ИТОГО',
        currency: '',
        totalDebit: grandDebit,
        totalCredit: grandCredit,
        net: grandCredit - grandDebit,
        txCount: snapshot.size,
    });
    sumRow.font = { bold: true };

    ws.autoFilter = { from: 'A1', to: `F${Object.keys(accountSummary).length + 1}` };
}
