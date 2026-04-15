"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.exportLedger = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const storage_1 = require("firebase-admin/storage");
exports.exportLedger = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const { branchId, startDate, endDate } = data;
    if (!branchId) {
        throw new https_1.HttpsError('invalid-argument', 'Branch ID is required for export.');
    }
    const db = admin.firestore();
    try {
        // Verify User Permissions
        const userDoc = await db.collection('users').doc(auth.uid).get();
        if (!userDoc.exists) {
            throw new https_1.HttpsError('permission-denied', 'User profile not found.');
        }
        const userData = userDoc.data();
        const isAdmin = (userData === null || userData === void 0 ? void 0 : userData.role) === 'admin';
        const assignedBranches = (userData === null || userData === void 0 ? void 0 : userData.assignedBranchIds) || [];
        if (!isAdmin && !assignedBranches.includes(branchId)) {
            throw new https_1.HttpsError('permission-denied', 'Unauthorized to export data for this branch.');
        }
        // Build Query
        let query = db.collection('ledgerEntries').where('branchId', '==', branchId);
        if (startDate) {
            query = query.where('createdAt', '>=', new Date(startDate));
        }
        if (endDate) {
            query = query.where('createdAt', '<=', new Date(endDate));
        }
        // Note: Ordering requires a composite index in Firestore on [branchId, createdAt]
        query = query.orderBy('createdAt', 'desc');
        const snapshot = await query.get();
        if (snapshot.empty) {
            return { success: true, downloadUrl: null, message: 'No records found for the given criteria.' };
        }
        // CSV Header
        const headers = [
            'Record ID',
            'Date & Time',
            'Account ID',
            'Type',
            'Reference Type',
            'Reference ID',
            'Description',
            'Debit',
            'Credit',
            'Currency',
            'Created By UID',
        ];
        let csvString = headers.join(',') + '\n';
        snapshot.forEach((doc) => {
            var _a;
            const entry = doc.data();
            // Safe escape for CSV fields containing commas or quotes
            const escapeCSV = (str) => `"${(str || '').replace(/"/g, '""')}"`;
            const createdAt = ((_a = entry.createdAt) === null || _a === void 0 ? void 0 : _a.toDate) ? entry.createdAt.toDate().toISOString() : '';
            const debit = entry.type === 'debit' ? entry.amount : 0;
            const credit = entry.type === 'credit' ? entry.amount : 0;
            const row = [
                escapeCSV(doc.id),
                escapeCSV(createdAt),
                escapeCSV(entry.accountId),
                escapeCSV(entry.type),
                escapeCSV(entry.referenceType),
                escapeCSV(entry.referenceId),
                escapeCSV(entry.description),
                debit,
                credit,
                escapeCSV(entry.currency),
                escapeCSV(entry.createdBy),
            ];
            csvString += row.join(',') + '\n';
        });
        const bucket = (0, storage_1.getStorage)().bucket();
        const fileName = `exports/ledger_${branchId}_${Date.now()}.csv`;
        const file = bucket.file(fileName);
        await file.save(csvString, {
            contentType: 'text/csv',
        });
        const [url] = await file.getSignedUrl({
            action: 'read',
            expires: Date.now() + 15 * 60 * 1000, // 15 minutes
        });
        return { success: true, downloadUrl: url };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error executing export');
    }
});
//# sourceMappingURL=exportLedger.js.map