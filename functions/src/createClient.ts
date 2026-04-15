import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

async function generateClientCode(
    t: admin.firestore.Transaction,
    db: admin.firestore.Firestore,
): Promise<string> {
    const year = new Date().getFullYear();
    const counterRef = db.collection('counters').doc('clientCodes');
    const counterDoc = await t.get(counterRef);
    const fieldKey = `count_${year}`;
    const currentCount: number = counterDoc.exists
        ? (counterDoc.data()?.[fieldKey] || 0)
        : 0;
    const nextCount = currentCount + 1;
    t.set(counterRef, { [fieldKey]: nextCount }, { merge: true });
    return `CL-${year}-${String(nextCount).padStart(6, '0')}`;
}

export const createClient = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    const userDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!userDoc.exists) throw new HttpsError('permission-denied', 'User profile not found.');

    const role = userDoc.data()?.role;
    if (!['creator', 'accountant'].includes(role)) {
        throw new HttpsError('permission-denied', 'Insufficient permissions.');
    }

    const { name, phone, country, currency, branchId } = data;

    if (!name || !phone || !currency) {
        throw new HttpsError('invalid-argument', 'Name, phone and currency are required.');
    }
    const branchIdTrim =
        typeof branchId === 'string' && branchId.trim().length > 0 ? branchId.trim() : '';

    const db = admin.firestore();

    const clientId = await db.runTransaction(async (t) => {
        const clientCode = await generateClientCode(t, db);
        const clientRef = db.collection('clients').doc();

        const cur = currency.trim();
        const clientFields: Record<string, unknown> = {
            clientCode,
            name: name.trim(),
            phone: phone.trim(),
            country: country?.trim() || '',
            currency: cur,
            walletCurrencies: [cur],
            isActive: true,
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        };
        if (branchIdTrim) {
            clientFields.branchId = branchIdTrim;
        }
        t.set(clientRef, clientFields);

        // Initialize zero balance (per-currency map + primary mirror)
        const balanceRef = db.collection('clientBalances').doc(clientRef.id);
        t.set(balanceRef, {
            clientId: clientRef.id,
            balances: { [cur]: 0 },
            balance: 0,
            currency: cur,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        // Audit log
        t.set(db.collection('auditLogs').doc(), {
            action: 'create_client',
            entityType: 'client',
            entityId: clientRef.id,
            performedBy: auth.uid,
            details: { clientCode, name },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        return clientRef.id;
    });

    return { success: true, clientId };
});
