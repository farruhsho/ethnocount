import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

const strictRound = (num: number, decimals: number = 2): number =>
    Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);

async function generateTxCode(
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
    return `ETH-TX-${year}-${String(nextCount).padStart(6, '0')}`;
}

interface PaymentInput {
    accountId: string;
    accountName: string;
    amount: number;
    currency: string;
}

export const createPurchase = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    const {
        branchId,
        clientId,
        clientName,
        description,
        category,
        totalAmount,
        currency,
        payments, // PaymentInput[]
    } = data;

    if (!branchId) throw new HttpsError('invalid-argument', 'branchId is required.');
    if (!description?.trim()) throw new HttpsError('invalid-argument', 'description is required.');
    if (!currency) throw new HttpsError('invalid-argument', 'currency is required.');
    if (!Array.isArray(payments) || payments.length === 0) {
        throw new HttpsError('invalid-argument', 'At least one payment is required.');
    }
    if (totalAmount <= 0) throw new HttpsError('invalid-argument', 'totalAmount must be positive.');

    const cleanTotal = strictRound(totalAmount);

    // Validate: sum of payments must equal totalAmount (within rounding tolerance)
    const paymentSum = payments.reduce((s: number, p: PaymentInput) => s + strictRound(p.amount), 0);
    const roundedSum = strictRound(paymentSum);
    if (Math.abs(roundedSum - cleanTotal) > 0.01) {
        throw new HttpsError(
            'invalid-argument',
            `Sum of payments (${roundedSum}) must equal totalAmount (${cleanTotal}).`
        );
    }

    const db = admin.firestore();

    const purchaseId = await db.runTransaction(async (t) => {
        // Permission check
        const userDoc = await t.get(db.collection('users').doc(auth.uid));
        if (!userDoc.exists) throw new HttpsError('permission-denied', 'User profile not found.');

        // Validate branch exists
        const branchDoc = await t.get(db.collection('branches').doc(branchId));
        if (!branchDoc.exists) throw new HttpsError('not-found', 'Branch not found.');

        // For each payment: validate account, check balance, prepare deductions
        const accountDocs: Map<string, admin.firestore.DocumentData> = new Map();
        const balanceDocs: Map<string, { balance: number; currency: string; branchId: string }> = new Map();

        for (const payment of payments) {
            const acctDoc = await t.get(db.collection('branchAccounts').doc(payment.accountId));
            if (!acctDoc.exists) {
                throw new HttpsError('not-found', `Account ${payment.accountId} not found.`);
            }
            accountDocs.set(payment.accountId, acctDoc.data()!);

            const balRef = db.collection('accountBalances').doc(payment.accountId);
            const balDoc = await t.get(balRef);
            const currentBalance = balDoc.exists ? strictRound(balDoc.data()?.balance || 0) : 0;
            const acctBranchId = acctDoc.data()?.branchId || branchId;
            balanceDocs.set(payment.accountId, {
                balance: currentBalance,
                currency: acctDoc.data()?.currency || payment.currency,
                branchId: acctBranchId,
            });

            const cleanAmount = strictRound(payment.amount);
            if (currentBalance < cleanAmount) {
                throw new HttpsError(
                    'failed-precondition',
                    `Insufficient balance in account "${payment.accountName}". Available: ${currentBalance}, required: ${cleanAmount}`
                );
            }
        }

        // Generate transaction code
        const transactionCode = await generateTxCode(t, db);

        // Create purchase document
        const purchaseRef = db.collection('purchases').doc();

        // Calculate percentages
        const paymentsWithPct = payments.map((p: PaymentInput) => ({
            accountId: p.accountId,
            accountName: p.accountName,
            amount: strictRound(p.amount),
            currency: p.currency,
            percentage: strictRound((p.amount / cleanTotal) * 100, 4),
        }));

        t.set(purchaseRef, {
            transactionCode,
            branchId,
            clientId: clientId || null,
            clientName: clientName || null,
            description: description.trim(),
            category: category?.trim() || null,
            totalAmount: cleanTotal,
            currency,
            payments: paymentsWithPct,
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        // For each payment: debit account + create ledger entry + update balance
        for (const payment of payments) {
            const cleanAmount = strictRound(payment.amount);
            const bal = balanceDocs.get(payment.accountId)!;
            const newBalance = strictRound(bal.balance - cleanAmount);

            // Debit account balance
            t.set(db.collection('accountBalances').doc(payment.accountId), {
                accountId: payment.accountId,
                branchId: bal.branchId,
                balance: newBalance,
                currency: bal.currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            }, { merge: true });

            // Ledger entry
            t.set(db.collection('ledgerEntries').doc(), {
                branchId: bal.branchId,
                accountId: payment.accountId,
                type: 'debit',
                amount: cleanAmount,
                currency: bal.currency,
                referenceType: 'purchase',
                referenceId: purchaseRef.id,
                transactionCode,
                description: `Покупка ${transactionCode}: ${description.trim()}`,
                createdBy: auth.uid,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }

        // Audit log
        t.set(db.collection('auditLogs').doc(), {
            action: 'create_purchase',
            entityType: 'purchase',
            entityId: purchaseRef.id,
            performedBy: auth.uid,
            details: {
                transactionCode,
                totalAmount: cleanTotal,
                currency,
                branchId,
                paymentsCount: payments.length,
                clientId: clientId || null,
            },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });

        return purchaseRef.id;
    });

    return { success: true, purchaseId };
});
