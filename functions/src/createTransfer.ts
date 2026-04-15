import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

const strictRound = (num: number, decimals: number = 2): number => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};

/**
 * Atomically generates the next transaction code in format ELX-YYYY-NNNNNN.
 * Uses the `counters/transactionCodes` document with year-based counters.
 */
async function generateTransactionCode(
    t: admin.firestore.Transaction,
    db: admin.firestore.Firestore,
): Promise<string> {
    const year = new Date().getFullYear();
    const counterRef = db.collection('counters').doc('transactionCodes');
    const counterDoc = await t.get(counterRef);
    const fieldKey = `count_${year}`;
    const currentCount: number = counterDoc.exists
        ? (counterDoc.data()?.[fieldKey] || 0)
        : 0;
    const nextCount = currentCount + 1;
    t.set(counterRef, { [fieldKey]: nextCount }, { merge: true });
    const padded = String(nextCount).padStart(6, '0');
    return `ETH-TX-${year}-${padded}`;
}

export const createTransfer = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) {
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const {
        fromBranchId,
        toBranchId,
        fromAccountId,
        toAccountId,
        amount,
        currency,
        exchangeRate,
        commissionType,      // 'fixed' | 'percentage'
        commissionValue,     // raw value: dollar amount or percentage rate
        commissionCurrency,
        commissionMode = 'fromSender',
        idempotencyKey,
        senderName,
        senderPhone,
        senderInfo,
        receiverName,
        receiverPhone,
        receiverInfo,
    } = data;

    if (!amount || amount <= 0) {
        throw new HttpsError('invalid-argument', 'Amount must be positive.');
    }

    const cleanAmount = strictRound(amount);
    const cleanRate = strictRound(exchangeRate || 1.0, 4);

    // Calculate actual commission amount (in commission currency)
    const type: 'fixed' | 'percentage' = commissionType === 'percentage' ? 'percentage' : 'fixed';
    const rawValue = strictRound(commissionValue || 0, 4);
    let cleanCommission = type === 'percentage'
        ? strictRound(cleanAmount * rawValue / 100)
        : strictRound(rawValue);

    const db = admin.firestore();

    // For fixed commission: when currency differs from transfer, convert using exchange rate
    // For percentage: commission is already in transfer currency (percentage of amount)
    let commissionInTransferCurrency = cleanCommission;
    const commCurr = commissionCurrency || currency;
    const isFixedCommission = type === 'fixed';
    if (isFixedCommission && cleanCommission > 0 && commCurr && commCurr !== currency) {
        const rateSnap = await db.collection('exchangeRates')
            .where('fromCurrency', '==', commCurr)
            .where('toCurrency', '==', currency)
            .orderBy('effectiveAt', 'desc')
            .limit(1)
            .get();
        if (rateSnap.empty) {
            throw new HttpsError(
                'failed-precondition',
                `Exchange rate ${commCurr} → ${currency} not found. Please set it in exchange rates.`,
            );
        }
        const rateVal = rateSnap.docs[0].data()?.rate ?? 0;
        commissionInTransferCurrency = strictRound(cleanCommission * rateVal);
    }

    try {
        const transferId = await db.runTransaction(async (t) => {
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
                throw new HttpsError('not-found', 'Branch or Account not found.');
            }

            let toAccountCurrency: string | undefined;
            if (toAccountId) {
                const toAccountDoc = await t.get(db.collection('branchAccounts').doc(toAccountId));
                if (!toAccountDoc.exists) {
                    throw new HttpsError('not-found', 'Receiver account not found.');
                }
                toAccountCurrency = toAccountDoc.data()?.currency;
            }

            const fromAccountCurrency = fromAccountDoc.data()?.currency;

            if (fromAccountCurrency && currency !== fromAccountCurrency) {
                throw new HttpsError('invalid-argument', 'Transfer currency must match sender account currency.');
            }

            // 3. Permission check
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const userRole = userData?.role;
            const isPrivileged = userRole === 'admin' || userRole === 'creator';
            const assignedBranches = userData?.assignedBranchIds || [];

            if (!isPrivileged && !assignedBranches.includes(fromBranchId)) {
                throw new HttpsError('permission-denied', 'User is not authorized to transfer from this branch.');
            }

            // 4. Balance check
            const balanceRef = db.collection('accountBalances').doc(fromAccountId);
            const balanceDoc = await t.get(balanceRef);
            const currentBalance = balanceDoc.exists ? strictRound(balanceDoc.data()?.balance || 0) : 0;

            // fromTransfer: commission deducted from amount → need amount
            // fromSender: sender pays extra → need amount + commission (in transfer currency)
            // toReceiver: commission added to receiver → need amount
            const totalRequired = commissionMode === 'fromSender'
                ? strictRound(cleanAmount + commissionInTransferCurrency)
                : strictRound(cleanAmount);
            if (currentBalance < totalRequired) {
                throw new HttpsError('failed-precondition', `Insufficient funds. Available: ${currentBalance}, required: ${totalRequired}`);
            }

            // 5. Generate unique transaction code
            const transactionCode = await generateTransactionCode(t, db);

            // 6. Create transfer document
            const newTransferRef = db.collection('transfers').doc();
            t.set(newTransferRef, {
                transactionCode,
                fromBranchId,
                toBranchId,
                fromAccountId,
                toAccountId: toAccountId || '',
                amount: cleanAmount,
                currency: fromAccountCurrency || currency,
                toCurrency: toAccountCurrency || null,
                exchangeRate: cleanRate,
                convertedAmount: strictRound(cleanAmount * cleanRate),
                commission: cleanCommission,
                commissionCurrency: commissionCurrency || fromAccountCurrency || currency,
                commissionType: type,
                commissionValue: rawValue,
                commissionMode: commissionMode,
                status: 'pending',
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                idempotencyKey,
                ...(senderName ? { senderName } : {}),
                ...(senderPhone ? { senderPhone } : {}),
                ...(senderInfo ? { senderInfo } : {}),
                ...(receiverName ? { receiverName } : {}),
                ...(receiverPhone ? { receiverPhone } : {}),
                ...(receiverInfo ? { receiverInfo } : {}),
            });

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
                description: `Fund lock for transfer ${transactionCode} to ${toBranchDoc.data()?.name || 'Branch'}`,
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
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error creating transfer');
    }
});
