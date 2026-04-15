"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.debitClient = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 2) => Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
exports.debitClient = (0, https_1.onCall)(async (request) => {
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
        var _a, _b, _c;
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
        if (currentBalance < cleanAmount) {
            throw new https_1.HttpsError('failed-precondition', 'Insufficient client balance.');
        }
        const newBalance = strictRound(currentBalance - cleanAmount);
        t.set(balanceRef, {
            clientId,
            balance: newBalance,
            currency: clientCurrency,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        }, { merge: true });
        t.set(db.collection('clientTransactions').doc(), {
            clientId,
            type: 'debit',
            amount: cleanAmount,
            currency: clientCurrency,
            balanceAfter: newBalance,
            description: (description === null || description === void 0 ? void 0 : description.trim()) || 'Списание со счёта',
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        t.set(db.collection('auditLogs').doc(), {
            action: 'debit_client',
            entityType: 'client',
            entityId: clientId,
            performedBy: auth.uid,
            details: { amount: cleanAmount, currency: clientCurrency, balanceBefore: currentBalance },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    });
    return { success: true };
});
//# sourceMappingURL=debitClient.js.map