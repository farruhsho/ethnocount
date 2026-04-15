"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.cancelTransfer = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 2) => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};
exports.cancelTransfer = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const { transferId, reason } = data;
    if (!transferId) {
        throw new https_1.HttpsError('invalid-argument', 'Transfer ID is required.');
    }
    const db = admin.firestore();
    try {
        await db.runTransaction(async (t) => {
            var _a;
            const transferRef = db.collection('transfers').doc(transferId);
            const transferDoc = await t.get(transferRef);
            if (!transferDoc.exists) {
                throw new https_1.HttpsError('not-found', 'Transfer not found.');
            }
            const transferData = transferDoc.data();
            if ((transferData === null || transferData === void 0 ? void 0 : transferData.status) !== 'pending') {
                throw new https_1.HttpsError('failed-precondition', 'Only pending transfers can be cancelled.');
            }
            // Permission: only the creator or an admin can cancel
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new https_1.HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const isPrivileged = (userData === null || userData === void 0 ? void 0 : userData.role) === 'creator';
            const isTransferOwner = transferData.createdBy === auth.uid;
            if (!isPrivileged && !isTransferOwner) {
                throw new https_1.HttpsError('permission-denied', 'Only the transfer creator or system creator can cancel this transfer.');
            }
            // Fetch sender account balance to refund
            const senderBalanceRef = db.collection('accountBalances').doc(transferData.fromAccountId);
            const senderBalanceDoc = await t.get(senderBalanceRef);
            const senderCurrentBalance = senderBalanceDoc.exists ? strictRound(((_a = senderBalanceDoc.data()) === null || _a === void 0 ? void 0 : _a.balance) || 0) : 0;
            const totalLocked = strictRound(transferData.amount + (transferData.commission || 0));
            // 1. Update transfer status
            t.update(transferRef, {
                status: 'cancelled',
                rejectedBy: auth.uid,
                rejectionReason: reason || 'Cancelled by user',
                rejectedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 2. Refund: credit sender account
            const refundLedgerRef = db.collection('ledgerEntries').doc();
            t.set(refundLedgerRef, {
                branchId: transferData.fromBranchId,
                accountId: transferData.fromAccountId,
                type: 'credit',
                amount: totalLocked,
                currency: transferData.currency,
                referenceType: 'transfer',
                referenceId: transferId,
                description: 'Fund unlock for cancelled transfer.',
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 3. Update sender account balance
            t.set(senderBalanceRef, {
                accountId: transferData.fromAccountId,
                branchId: transferData.fromBranchId,
                balance: strictRound(senderCurrentBalance + totalLocked),
                currency: transferData.currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
            // 4. Notification for sender branch
            const notificationRef = db.collection('notifications').doc();
            t.set(notificationRef, {
                targetBranchId: transferData.fromBranchId,
                type: 'transfer_cancelled',
                title: 'Transfer Cancelled',
                body: `Transfer of ${transferData.amount} ${transferData.currency} has been cancelled.`,
                data: { transferId, reason: reason || 'Cancelled by user' },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 5. Notification for receiver branch
            const receiverNotifRef = db.collection('notifications').doc();
            t.set(receiverNotifRef, {
                targetBranchId: transferData.toBranchId,
                type: 'transfer_cancelled',
                title: 'Incoming Transfer Cancelled',
                body: `A pending transfer of ${transferData.amount} ${transferData.currency} was cancelled.`,
                data: { transferId },
                isRead: false,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            // 6. Audit log
            const auditRef = db.collection('auditLogs').doc();
            t.set(auditRef, {
                action: 'cancel_transfer',
                entityType: 'transfer',
                entityId: transferId,
                performedBy: auth.uid,
                details: {
                    reason: reason || 'Cancelled by user',
                    refundAmount: totalLocked,
                    currency: transferData.currency,
                },
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        });
        return { success: true };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error cancelling transfer');
    }
});
//# sourceMappingURL=cancelTransfer.js.map