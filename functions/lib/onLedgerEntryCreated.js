"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.onLedgerEntryCreated = void 0;
const firestore_1 = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");
exports.onLedgerEntryCreated = (0, firestore_1.onDocumentCreated)('ledgerEntries/{entryId}', async (event) => {
    const snapshot = event.data;
    if (!snapshot)
        return;
    const entry = snapshot.data();
    const accountId = entry.accountId;
    const branchId = entry.branchId;
    const type = entry.type;
    const amount = entry.amount;
    const currency = entry.currency;
    const referenceType = entry.referenceType;
    if (!accountId)
        return;
    // Transfer, commission, and purchase balance updates are handled synchronously
    // inside the HTTPS callable functions to prevent overdrafts.
    // This trigger only processes out-of-band entries (e.g. adjustments, opening balances).
    if (referenceType === 'transfer' || referenceType === 'commission' || referenceType === 'purchase') {
        return;
    }
    const db = admin.firestore();
    try {
        await db.runTransaction(async (t) => {
            var _a;
            const balanceRef = db.collection('accountBalances').doc(accountId);
            const balanceDoc = await t.get(balanceRef);
            const currentBalance = balanceDoc.exists
                ? (((_a = balanceDoc.data()) === null || _a === void 0 ? void 0 : _a.balance) || 0)
                : 0;
            const newBalance = type === 'credit'
                ? currentBalance + amount
                : currentBalance - amount;
            t.set(balanceRef, {
                accountId,
                branchId,
                balance: newBalance,
                currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });
        });
    }
    catch (error) {
        console.error('Error updating account balance on ledger entry:', error);
    }
});
//# sourceMappingURL=onLedgerEntryCreated.js.map