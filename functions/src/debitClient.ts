import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import { readBalancesMap, setClientBalanceWrite, strictRound } from './clientBalanceMulti';

export const debitClient = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    const { clientId, amount, description, currency: opCurrency } = data;

    if (!clientId) throw new HttpsError('invalid-argument', 'clientId is required.');
    if (!amount || amount <= 0) throw new HttpsError('invalid-argument', 'Amount must be positive.');

    const cleanAmount = strictRound(amount);
    const db = admin.firestore();

    await db.runTransaction(async (t) => {
        const clientRef = db.collection('clients').doc(clientId);
        const clientDoc = await t.get(clientRef);

        if (!clientDoc.exists) throw new HttpsError('not-found', 'Client not found.');
        if (!clientDoc.data()?.isActive) throw new HttpsError('failed-precondition', 'Client account is inactive.');

        const clientCurrency = clientDoc.data()?.currency || 'USD';
        const targetCurrency =
            typeof opCurrency === 'string' && opCurrency.trim().length > 0
                ? opCurrency.trim()
                : clientCurrency;

        const balanceRef = db.collection('clientBalances').doc(clientId);
        const balanceDoc = await t.get(balanceRef);
        const balances = readBalancesMap(balanceDoc.data(), clientCurrency);

        const balanceBefore = strictRound(balances[targetCurrency] ?? 0);

        if (balanceBefore < cleanAmount) {
            throw new HttpsError('failed-precondition', 'Insufficient client balance.');
        }

        balances[targetCurrency] = strictRound(balanceBefore - cleanAmount);
        t.set(balanceRef, setClientBalanceWrite(clientId, clientCurrency, balances), { merge: true });

        t.set(db.collection('clientTransactions').doc(), {
            clientId,
            type: 'debit',
            amount: cleanAmount,
            currency: targetCurrency,
            balanceAfter: balances[targetCurrency],
            description: description?.trim() || 'Списание со счёта',
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        t.set(db.collection('auditLogs').doc(), {
            action: 'debit_client',
            entityType: 'client',
            entityId: clientId,
            performedBy: auth.uid,
            details: { amount: cleanAmount, currency: targetCurrency, balanceBefore },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
    });

    return { success: true };
});
