import { onDocumentCreated } from 'firebase-functions/v2/firestore';
import * as admin from 'firebase-admin';

export const onLedgerEntryCreated = onDocumentCreated('ledgerEntries/{entryId}', async (event) => {
    const snapshot = event.data;
    if (!snapshot) return;

    const entry = snapshot.data();
    const accountId = entry.accountId as string | undefined;
    const branchId = entry.branchId as string;
    const type = entry.type as string;
    const amount = entry.amount as number;
    const currency = entry.currency as string;
    const referenceType = entry.referenceType as string;

    if (!accountId) return;

    // Transfer, commission, and purchase balance updates are handled synchronously
    // inside the HTTPS callable functions to prevent overdrafts.
    // This trigger only processes out-of-band entries (e.g. adjustments, opening balances).
    if (referenceType === 'transfer' || referenceType === 'commission' || referenceType === 'purchase') {
        return;
    }

    const db = admin.firestore();

    try {
        await db.runTransaction(async (t) => {
            const balanceRef = db.collection('accountBalances').doc(accountId);
            const balanceDoc = await t.get(balanceRef);

            const currentBalance = balanceDoc.exists
                ? (balanceDoc.data()?.balance || 0)
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
    } catch (error) {
        console.error('Error updating account balance on ledger entry:', error);
    }
});
