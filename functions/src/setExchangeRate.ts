import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

const strictRound = (num: number, decimals: number = 4): number => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};

export const setExchangeRate = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) {
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }

    const { fromCurrency, toCurrency, rate } = data;

    if (!fromCurrency || !toCurrency || !rate) {
        throw new HttpsError('invalid-argument', 'fromCurrency, toCurrency, and rate are required.');
    }

    if (fromCurrency === toCurrency) {
        throw new HttpsError('invalid-argument', 'Source and target currencies must differ.');
    }

    if (typeof rate !== 'number' || rate <= 0) {
        throw new HttpsError('invalid-argument', 'Rate must be a positive number.');
    }

    const cleanRate = strictRound(rate);
    const inverseRate = strictRound(1 / cleanRate);

    const db = admin.firestore();

    try {
        const userDoc = await db.collection('users').doc(auth.uid).get();
        if (!userDoc.exists) {
            throw new HttpsError('permission-denied', 'User profile not found.');
        }

        const now = admin.firestore.FieldValue.serverTimestamp();
        const batch = db.batch();

        // Forward rate
        const forwardRef = db.collection('exchangeRates').doc();
        batch.set(forwardRef, {
            fromCurrency,
            toCurrency,
            rate: cleanRate,
            setBy: auth.uid,
            effectiveAt: now,
            createdAt: now,
        });

        // Inverse rate
        const inverseRef = db.collection('exchangeRates').doc();
        batch.set(inverseRef, {
            fromCurrency: toCurrency,
            toCurrency: fromCurrency,
            rate: inverseRate,
            setBy: auth.uid,
            effectiveAt: now,
            createdAt: now,
        });

        // Audit log
        const auditRef = db.collection('auditLogs').doc();
        batch.set(auditRef, {
            action: 'set_exchange_rate',
            entityType: 'exchangeRate',
            entityId: forwardRef.id,
            performedBy: auth.uid,
            details: {
                fromCurrency,
                toCurrency,
                rate: cleanRate,
                inverseRate,
            },
            createdAt: now,
        });

        await batch.commit();

        return {
            success: true,
            rateId: forwardRef.id,
            rate: cleanRate,
            inverseRate,
        };
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error setting exchange rate');
    }
});
