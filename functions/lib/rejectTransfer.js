"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.rejectTransfer = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 2) => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};
exports.rejectTransfer = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const { transferId, reason } = data;
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
                throw new https_1.HttpsError('failed-precondition', 'Transfer has already been confirmed or rejected.');
            }
            // Permission check: caller must have access to receiver branch or be admin
            const userDoc = await t.get(db.collection('users').doc(auth.uid));
            if (!userDoc.exists) {
                throw new https_1.HttpsError('permission-denied', 'User profile not found.');
            }
            const userData = userDoc.data();
            const isPrivileged = (userData === null || userData === void 0 ? void 0 : userData.role) === 'creator' || (userData === null || userData === void 0 ? void 0 : userData.role) === 'admin';
            const assignedBranches = (userData === null || userData === void 0 ? void 0 : userData.assignedBranchIds) || [];
            if (!isPrivileged && !assignedBranches.includes(transferData.toBranchId)) {
                throw new https_1.HttpsError('permission-denied', 'User is not authorized to reject transfers for this branch.');
            }
            // 0.5 Fetch sender account balance to refund
            const senderBalanceRef = db.collection('accountBalances').doc(transferData.fromAccountId);
            const senderBalanceDoc = await t.get(senderBalanceRef);
            const senderCurrentBalance = senderBalanceDoc.exists ? strictRound(((_a = senderBalanceDoc.data()) === null || _a === void 0 ? void 0 : _a.balance) || 0) : 0;
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
                referenceType: 'transfer',
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
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error rejecting transfer');
    }
});
//# sourceMappingURL=rejectTransfer.js.map