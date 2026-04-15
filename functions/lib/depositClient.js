"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.depositClient = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 2) => Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
exports.depositClient = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    const { clientId, amount, description } = data;
    if (!clientId)
        throw new https_1.HttpsError('invalid-argument', 'clientId is required.');
    if (!amount || amount <= 0)
        throw new https_1.HttpsError('invalid-argument', 'Amount must be positive.');
    const cleanAmount = strictRound(amount);
    const db = admin.firestore();
    await db.runTransaction(async (t) => {
        var _a, _b, _c, _d;
        const clientRef = db.collection('clients').doc(clientId);
        const clientDoc = await t.get(clientRef);
        if (!clientDoc.exists)
            throw new https_1.HttpsError('not-found', 'Client not found.');
        if (!((_a = clientDoc.data()) === null || _a === void 0 ? void 0 : _a.isActive))
            throw new https_1.HttpsError('failed-precondition', 'Client account is inactive.');
        const clientCurrency = (_b = clientDoc.data()) === null || _b === void 0 ? void 0 : _b.currency;
        const balanceRef = db.collection('clientBalances').doc(clientId);
        const balanceDoc = await t.get(balanceRef);
        const currentBalance = balanceDoc.exists ? strictRound(((_c = balanceDoc.data()) === null || _c === void 0 ? void 0 : _c.balance) || 0) : 0;
        // Generate transaction code ETH-TX-YYYY-NNNNNN
        const year = new Date().getFullYear();
        const counterRef = db.collection('counters').doc('transactionCodes');
        const counterDoc = await t.get(counterRef);
        const fieldKey = `count_${year}`;
        const currentCount = counterDoc.exists ? (((_d = counterDoc.data()) === null || _d === void 0 ? void 0 : _d[fieldKey]) || 0) : 0;
        const nextCount = currentCount + 1;
        t.set(counterRef, { [fieldKey]: nextCount }, { merge: true });
        const transactionCode = `ETH-TX-${year}-${String(nextCount).padStart(6, '0')}`;
        t.set(balanceRef, {
            clientId,
            balance: strictRound(currentBalance + cleanAmount),
            currency: clientCurrency,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        t.set(db.collection('clientTransactions').doc(), {
            clientId,
            transactionCode,
            type: 'deposit',
            amount: cleanAmount,
            currency: clientCurrency,
            balanceAfter: strictRound(currentBalance + cleanAmount),
            description: (description === null || description === void 0 ? void 0 : description.trim()) || 'Пополнение счёта',
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        t.set(db.collection('auditLogs').doc(), {
            action: 'deposit_client',
            entityType: 'client',
            entityId: clientId,
            performedBy: auth.uid,
            details: { transactionCode, amount: cleanAmount, currency: clientCurrency, balanceBefore: currentBalance },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    });
    return { success: true };
});
//# sourceMappingURL=depositClient.js.map