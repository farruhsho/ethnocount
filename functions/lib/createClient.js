"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createClient = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
async function generateClientCode(t, db) {
    var _a;
    const year = new Date().getFullYear();
    const counterRef = db.collection('counters').doc('clientCodes');
    const counterDoc = await t.get(counterRef);
    const fieldKey = `count_${year}`;
    const currentCount = counterDoc.exists
        ? (((_a = counterDoc.data()) === null || _a === void 0 ? void 0 : _a[fieldKey]) || 0)
        : 0;
    const nextCount = currentCount + 1;
    t.set(counterRef, { [fieldKey]: nextCount }, { merge: true });
    return `CL-${year}-${String(nextCount).padStart(6, '0')}`;
}
exports.createClient = (0, https_1.onCall)(async (request) => {
    var _a;
    const { data, auth } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    const userDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!userDoc.exists)
        throw new https_1.HttpsError('permission-denied', 'User profile not found.');
    const role = (_a = userDoc.data()) === null || _a === void 0 ? void 0 : _a.role;
    if (!['creator', 'accountant'].includes(role)) {
        throw new https_1.HttpsError('permission-denied', 'Insufficient permissions.');
    }
    const { name, phone, country, currency } = data;
    if (!name || !phone || !currency) {
        throw new https_1.HttpsError('invalid-argument', 'Name, phone and currency are required.');
    }
    const db = admin.firestore();
    const clientId = await db.runTransaction(async (t) => {
        const clientCode = await generateClientCode(t, db);
        const clientRef = db.collection('clients').doc();
        t.set(clientRef, {
            clientCode,
            name: name.trim(),
            phone: phone.trim(),
            country: (country === null || country === void 0 ? void 0 : country.trim()) || '',
            currency: currency.trim(),
            isActive: true,
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Initialize zero balance
        const balanceRef = db.collection('clientBalances').doc(clientRef.id);
        t.set(balanceRef, {
            clientId: clientRef.id,
            balance: 0,
            currency: currency.trim(),
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
//# sourceMappingURL=createClient.js.map