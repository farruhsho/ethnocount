"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.createTransfer = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 2) => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};
/**
 * Atomically generates the next transaction code in format ELX-YYYY-NNNNNN.
 * Uses the `counters/transactionCodes` document with year-based counters.
 */
async function generateTransactionCode(t, db) {
    var _a;
    const year = new Date().getFullYear();
    const counterRef = db.collection('counters').doc('transactionCodes');
    const counterDoc = await t.get(counterRef);
    const fieldKey = `count_${year}`;
    const currentCount = counterDoc.exists
        ? (((_a = counterDoc.data()) === null || _a === void 0 ? void 0 : _a[fieldKey]) || 0)
        : 0;
    const nextCount = currentCount + 1;
    t.set(counterRef, { [fieldKey]: nextCount }, { merge: true });
    const padded = String(nextCount).padStart(6, '0');
    return `ETH-TX-${year}-${padded}`;
}
exports.createTransfer = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const { fromBranchId, toBranchId, fromAccountId, toAccountId, amount, currency, exchangeRate, commissionType, // 'fixed' | 'percentage'
    commissionValue, // raw value: dollar amount or percentage rate
    commissionCurrency, commissionMode = 'fromSender', idempotencyKey, senderName, senderPhone, senderInfo, receiverName, receiverPhone, receiverInfo, } = data;
    if (!amount || amount <= 0) {
        throw new https_1.HttpsError('invalid-argument', 'Amount must be positive.');
    }
    const cleanAmount = strictRound(amount);
    const cleanRate = strictRound(exchangeRate || 1.0, 4);
    // Calculate actual commission amount
    const type = commissionType === 'percentage' ? 'percentage' : 'fixed';
    const rawValue = strictRound(commissionValue || 0, 4);
    const cleanCommission = type === 'percentage'
        ? strictRound(cleanAmount * rawValue / 100)
        : strictRound(rawValue);
    const db = admin.firestore();
    try {
        const transferId = await db.runTransaction(async (t) => {
            var _a, _b, _c, _d;
            // 1. Idempotency check
            const existingQuery = db.collection('transfers').where('idempotencyKey', '==', idempotencyKey);
            const existingTransfers = await t.get(existingQuery);
            if (!existingTransfers.empty) {
                return existingTransfers.docs[0].id;
            }
            // 2. Validate entities
            const fromBranchDoc = await t.get(db.collection('branches').doc(fromBranchId));
            const fromAccountDoc = await t.get(db.collection('branchAccounts').doc(fromAccountId));
            const toBranchDoc = await t.get(db.collection('branches').doc(toBranchId));
            if (!fromBranchDoc.exists || !fromAccountDoc.exists || !toBranchDoc.exists) {
                throw new https_1.HttpsError('not-found', 'Branch or Account not found.');
            }
            let toAccountCurrency;
            if (toAccountId) {
                const toAccountDoc = await t.get(db.collection('branchAccounts').doc(toAccountId));
                if (!toAccountDoc.exists) {
                    throw new https_1.HttpsError('not-found', 'Receiver account not found.');
                }
                toAccountCurrency = (_a = toAccountDoc.data()) === null || _a === void 0 ? void 0 : _a.currency;
            }
            const fromAccountCurrency = (_b = fromAccountDoc.data()) === null || _b === void 0 ? void 0 : _b.currency;
            if (fromAccountCurrency && currency !== fromAccountCurrency) {
                throw new https_1.HttpsError('invalid-argument', 'Transfer currency must match sender account currency.');
            }
            // 3. Permission check
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new https_1.HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const userRole = userData === null || userData === void 0 ? void 0 : userData.role;
            const isPrivileged = userRole === 'admin' || userRole === 'creator';
            const assignedBranches = (userData === null || userData === void 0 ? void 0 : userData.assignedBranchIds) || [];
            if (!isPrivileged && !assignedBranches.includes(fromBranchId)) {
                throw new https_1.HttpsError('permission-denied', 'User is not authorized to transfer from this branch.');
            }
            // 4. Balance check
            const balanceRef = db.collection('accountBalances').doc(fromAccountId);
            const balanceDoc = await t.get(balanceRef);
            const currentBalance = balanceDoc.exists ? strictRound(((_c = balanceDoc.data()) === null || _c === void 0 ? void 0 : _c.balance) || 0) : 0;
            // fromTransfer: commission deducted from amount → need amount
            // fromSender: sender pays extra → need amount + commission
            // toReceiver: commission added to receiver → need amount
            const totalRequired = commissionMode === 'fromSender'
                ? strictRound(cleanAmount + cleanCommission)
                : strictRound(cleanAmount);
            if (currentBalance < totalRequired) {
                throw new https_1.HttpsError('failed-precondition', `Insufficient funds. Available: ${currentBalance}, required: ${totalRequired}`);
            }
            // 5. Generate unique transaction code
            const transactionCode = await generateTransactionCode(t, db);
            // 6. Create transfer document
            const newTransferRef = db.collection('transfers').doc();
            t.set(newTransferRef, Object.assign(Object.assign(Object.assign(Object.assign(Object.assign(Object.assign({ transactionCode,
                fromBranchId,
                toBranchId,
                fromAccountId, toAccountId: toAccountId || '', amount: cleanAmount, currency: fromAccountCurrency || currency, toCurrency: toAccountCurrency || null, exchangeRate: cleanRate, convertedAmount: strictRound(cleanAmount * cleanRate), commission: cleanCommission, commissionCurrency: commissionCurrency || fromAccountCurrency || currency, commissionType: type, commissionValue: rawValue, commissionMode: commissionMode, status: 'pending', createdBy: auth.uid, createdAt: admin.firestore.FieldValue.serverTimestamp(), idempotencyKey }, (senderName ? { senderName } : {})), (senderPhone ? { senderPhone } : {})), (senderInfo ? { senderInfo } : {})), (receiverName ? { receiverName } : {})), (receiverPhone ? { receiverPhone } : {})), (receiverInfo ? { receiverInfo } : {})));
            // 7. Ledger: Debit sender account (lock funds)
            const ledgerRef = db.collection('ledgerEntries').doc();
            t.set(ledgerRef, {
                branchId: fromBranchId,
                accountId: fromAccountId,
                type: 'debit',
                amount: totalRequired,
                currency: fromAccountCurrency || currency,
                referenceType: 'transfer',
                referenceId: newTransferRef.id,
                transactionCode,
                description: `Fund lock for transfer ${transactionCode} to ${((_d = toBranchDoc.data()) === null || _d === void 0 ? void 0 : _d.name) || 'Branch'}`,
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 8. Update sender balance
            t.set(balanceRef, {
                accountId: fromAccountId,
                branchId: fromBranchId,
                balance: strictRound(currentBalance - totalRequired),
                currency: fromAccountCurrency || currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            // 9. Notification for receiver branch
            const notificationRef = db.collection('notifications').doc();
            t.set(notificationRef, {
                targetBranchId: toBranchId,
                type: 'incoming_transfer',
                title: 'Новый входящий перевод',
                body: `Перевод ${transactionCode}: ${cleanAmount} ${currency} ожидает подтверждения.`,
                data: { transferId: newTransferRef.id, transactionCode },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 10. Audit log
            const auditRef = db.collection('auditLogs').doc();
            t.set(auditRef, {
                action: 'create_transfer',
                entityType: 'transfer',
                entityId: newTransferRef.id,
                performedBy: auth.uid,
                details: { transactionCode, amount: cleanAmount, currency, toBranchId, commissionType: type, commissionValue: rawValue, commission: cleanCommission },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            return newTransferRef.id;
        });
        return { success: true, transferId };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error creating transfer');
    }
});
//# sourceMappingURL=createTransfer.js.map