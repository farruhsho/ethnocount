import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

const strictRound = (num: number, decimals: number = 2): number => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};

export const rejectTransfer = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) {
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const { transferId, reason } = data;

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

            // Permission check: caller must have access to receiver branch or be admin
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const isPrivileged = userData?.role === 'creator' || userData?.role === 'admin';
            const assignedBranches = userData?.assignedBranchIds || [];

            if (!isPrivileged && !assignedBranches.includes(transferData.toBranchId)) {
                throw new HttpsError('permission-denied', 'User is not authorized to reject transfers for this branch.');
            }

            // 0.5 Fetch sender account balance to refund
            const senderBalanceRef = db.collection('accountBalances').doc(transferData.fromAccountId);
            const senderBalanceDoc = await t.get(senderBalanceRef);
            const senderCurrentBalance = senderBalanceDoc.exists ? strictRound(senderBalanceDoc.data()?.balance || 0) : 0;

            // 1. Update Transfer status to rejected
            t.update(transferRef, {
                status: 'rejected',
                rejectedBy: auth.uid,
                rejectionReason: reason || 'No reason provided',
                rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // 2. Reverse the lock: Credit sender account back the locked amount
            const totalLocked = strictRound(transferData.amount + (transferData.commission || 0));

            const refundLedgerRef = db.collection('ledgerEntries').doc();
            t.set(refundLedgerRef, {
                branchId: transferData.fromBranchId,
                accountId: transferData.fromAccountId,
                type: 'credit',
                amount: totalLocked,
                currency: transferData.currency,
                referenceType: 'transfer', // or adjustment
                referenceId: transferId,
                description: `Fund unlock for rejected transfer.`,
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // 2.5 Update sender account balance (Refund)
            t.set(senderBalanceRef, {
                accountId: transferData.fromAccountId,
                branchId: transferData.fromBranchId,
                balance: strictRound(senderCurrentBalance + totalLocked),
                currency: transferData.currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });

            // 3. Create Notification for sender
            const notificationRef = db.collection('notifications').doc();
            t.set(notificationRef, {
                targetBranchId: transferData.fromBranchId,
                type: 'transfer_rejected',
                title: 'Transfer Rejected',
                body: `Your transfer of ${transferData.amount} ${transferData.currency} was rejected.`,
                data: { transferId, reason },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });

            // 4. Create Audit Log
            const auditRef = db.collection('auditLogs').doc();
            t.set(auditRef, {
                action: 'reject_transfer',
                entityType: 'transfer',
                entityId: transferId,
                performedBy: auth.uid,
                details: { reason },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        });

        return { success: true };
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error rejecting transfer');
    }
});
