import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import { getStorage } from 'firebase-admin/storage';

export const exportLedger = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) {
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const { branchId, startDate, endDate } = data;

    if (!branchId) {
        throw new HttpsError('invalid-argument', 'Branch ID is required for export.');
    }

    const db = admin.firestore();

    try {
        // Verify User Permissions
        const userDoc = await db.collection('users').doc(auth.uid).get();
        if (!userDoc.exists) {
            throw new HttpsError('permission-denied', 'User profile not found.');
        }

        const userData = userDoc.data();
        const isAdmin = userData?.role === 'admin';
        const assignedBranches = userData?.assignedBranchIds || [];

        if (!isAdmin && !assignedBranches.includes(branchId)) {
            throw new HttpsError('permission-denied', 'Unauthorized to export data for this branch.');
        }

        // Build Query
        let query: admin.firestore.Query = db.collection('ledgerEntries').where('branchId', '==', branchId);

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
            const entry = doc.data();

            // Safe escape for CSV fields containing commas or quotes
            const escapeCSV = (str: string) => `"${(str || '').replace(/"/g, '""')}"`;

            const createdAt = entry.createdAt?.toDate ? entry.createdAt.toDate().toISOString() : '';

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

        const bucket = getStorage().bucket();
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
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error executing export');
    }
});
