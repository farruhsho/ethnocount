import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

// Utility to prevent floating-point drift in monetary values
const strictRound = (num: number, decimals: number = 2): number => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};

export const confirmTransfer = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) {
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const { transferId, exchangeRateLocked, toAccountId: paramToAccountId } = data;

    const db = admin.firestore();

    try {
        await db.runTransaction(async (t) => {
            const transferRef = db.collection('transfers').doc(transferId);
            const transferDoc = await t.get(transferRef);

            if (!transferDoc.exists) {
                throw new HttpsError('not-found', 'Transfer not found.');
            }

            const transferData = transferDoc.data();

            if (transferData?.status !== 'pending') {
                throw new HttpsError('failed-precondition', 'Transfer has already been confirmed or rejected.');
            }

            // Permission check: caller must have access to receiver branch
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const isPrivileged = userData?.role === 'creator' || userData?.role === 'admin';
            const assignedBranches = userData?.assignedBranchIds || [];

            if (!isPrivileged && !assignedBranches.includes(transferData.toBranchId)) {
                throw new HttpsError('permission-denied', 'User is not authorized to confirm transfers for this branch.');
            }

            const docToAccountId = transferData.toAccountId || '';
            const toAccountId = docToAccountId
                ? docToAccountId
                : (paramToAccountId || '');
            const toBranchId = transferData.toBranchId;

            if (!toAccountId) {
                throw new HttpsError('invalid-argument', 'Счёт получателя не указан. Выберите счёт при подтверждении.');
            }

            // Fetch receiver account to get its actual currency
            const toAccountDoc = await t.get(db.collection('branchAccounts').doc(toAccountId));
            if (!toAccountDoc.exists) {
                throw new HttpsError('not-found', 'Receiver account not found.');
            }
            const receiverCurrency = toAccountDoc.data()?.currency || transferData.currency;

            // Validate that account belongs to receiver branch
            const accountBranchId = toAccountDoc.data()?.branchId;
            if (accountBranchId && accountBranchId !== toBranchId) {
                throw new HttpsError('invalid-argument', 'Selected account does not belong to receiver branch.');
            }

            const storedToCurrency = transferData.toCurrency as string | undefined;
            if (storedToCurrency && receiverCurrency !== storedToCurrency) {
                throw new HttpsError(
                    'invalid-argument',
                    `Счёт получателя в валюте ${receiverCurrency}, а перевод оформлен в ${storedToCurrency}. ` +
                        `Выберите счёт в валюте ${storedToCurrency} или отклоните перевод.`,
                );
            }

            const finalRate = strictRound(exchangeRateLocked || transferData.exchangeRate || 1.0, 4);
            const commissionMode = transferData.commissionMode || 'fromSender';
            const rawAmount = transferData.amount || 0;
            const rawCommission = transferData.commission || 0;
            let receiverAmount: number;
            switch (commissionMode) {
                case 'toReceiver':
                    receiverAmount = rawAmount + rawCommission;
                    break;
                case 'fromTransfer':
                    receiverAmount = rawAmount - rawCommission;
                    break;
                default:
                    receiverAmount = rawAmount;
            }
            const finalConvertedAmount = strictRound(receiverAmount * finalRate);

            // 0.5 Fetch receiver account balance
            const receiverBalanceRef = db.collection('accountBalances').doc(toAccountId);
            const receiverBalanceDoc = await t.get(receiverBalanceRef);
            const receiverCurrentBalance = receiverBalanceDoc.exists ? strictRound(receiverBalanceDoc.data()?.balance || 0) : 0;

            // 0.6 Fetch System Revenue account balance if commission exists
            let systemBalanceRef: admin.firestore.DocumentReference | null = null;
            let systemCurrentBalance = 0;
            if (transferData.commission > 0) {
                systemBalanceRef = db.collection('accountBalances').doc('system_revenue_account');
                const systemBalanceDoc = await t.get(systemBalanceRef);
                systemCurrentBalance = systemBalanceDoc.exists ? strictRound(systemBalanceDoc.data()?.balance || 0) : 0;
            }

            // 1. Update Transfer status
            const updateData: admin.firestore.UpdateData<admin.firestore.DocumentData> = {
                status: 'confirmed',
                exchangeRate: finalRate,
                convertedAmount: finalConvertedAmount,
                toCurrency: receiverCurrency,
                confirmedBy: auth.uid,
                confirmedAt: admin.firestore.FieldValue.serverTimestamp(),
            };
            if (!docToAccountId && toAccountId) {
                updateData.toAccountId = toAccountId;
            }
            t.update(transferRef, updateData);

            // 2. Create Ledger Entry: Credit receiver account
            const creditLedgerRef = db.collection('ledgerEntries').doc();
            t.set(creditLedgerRef, {
                branchId: transferData.toBranchId,
                accountId: toAccountId,
                type: 'credit',
                amount: finalConvertedAmount,
                currency: receiverCurrency,
                referenceType: 'transfer',
                referenceId: transferId,
                description: `Incoming transfer from branch ${transferData.fromBranchId}`,
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // 2.5 Update receiver account balance
            t.set(receiverBalanceRef, {
                accountId: toAccountId,
                branchId: toBranchId,
                balance: strictRound(receiverCurrentBalance + finalConvertedAmount),
                currency: receiverCurrency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });

            // 3. Create Commission revenue entry if applicable (only for fromSender mode)
            // toReceiver: commission added to receiver, not earned by system
            if (transferData.commission > 0 && commissionMode === 'fromSender') {
                const commissionRef = db.collection('commissions').doc();
                t.set(commissionRef, {
                    transferId,
                    branchId: transferData.fromBranchId,
                    toBranchId: transferData.toBranchId,
                    amount: transferData.commission,
                    currency: transferData.commissionCurrency,
                    type: 'transfer_fee',
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                // 3.5 System revenue ledger entry (Double-entry fix)
                const revenueLedgerRef = db.collection('ledgerEntries').doc();
                t.set(revenueLedgerRef, {
                    branchId: 'system',
                    accountId: 'system_revenue_account',
                    type: 'credit',
                    amount: transferData.commission,
                    currency: transferData.commissionCurrency,
                    referenceType: 'commission',
                    referenceId: commissionRef.id,
                    description: `Commission from transfer ${transferId}`,
                    createdBy: auth.uid,
                    createdAt: admin.firestore.FieldValue.serverTimestamp(),
                });

                // 3.6 Update system revenue account balance
                if (systemBalanceRef) {
                    t.set(systemBalanceRef, {
                        accountId: 'system_revenue_account',
                        branchId: 'system',
                        balance: strictRound(systemCurrentBalance + transferData.commission),
                        currency: transferData.commissionCurrency,
                        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                    }, { merge: true });
                }
            }

            // 4. Create Notification for sender branch
            const notificationRef = db.collection('notifications').doc();
            t.set(notificationRef, {
                targetBranchId: transferData.fromBranchId,
                type: 'transfer_confirmed',
                title: 'Перевод подтверждён',
                body: `Ваш перевод ${transferData.amount} ${transferData.currency} подтверждён.`,
                data: { transferId },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // 5. Create Audit Log
            const auditRef = db.collection('auditLogs').doc();
            t.set(auditRef, {
                action: 'confirm_transfer',
                entityType: 'transfer',
                entityId: transferId,
                performedBy: auth.uid,
                details: { finalConvertedAmount, finalRate },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        });

        return { success: true };
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error confirming transfer');
    }
});
