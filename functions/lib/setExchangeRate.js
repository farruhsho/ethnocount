"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.setExchangeRate = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const strictRound = (num, decimals = 4) => {
    return Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);
};
exports.setExchangeRate = (0, https_1.onCall)(async (request) => {
    const { data, auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const { fromCurrency, toCurrency, rate } = data;
    if (!fromCurrency || !toCurrency || !rate) {
        throw new https_1.HttpsError('invalid-argument', 'fromCurrency, toCurrency, and rate are required.');
    }
    if (fromCurrency === toCurrency) {
        throw new https_1.HttpsError('invalid-argument', 'Source and target currencies must differ.');
    }
    if (typeof rate !== 'number' || rate <= 0) {
        throw new https_1.HttpsError('invalid-argument', 'Rate must be a positive number.');
    }
    const cleanRate = strictRound(rate);
    const inverseRate = strictRound(1 / cleanRate);
    const db = admin.firestore();
    try {
        const userDoc = await db.collection('users').doc(auth.uid).get();
        if (!userDoc.exists) {
            throw new https_1.HttpsError('permission-denied', 'User profile not found.');
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
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error setting exchange rate');
    }
});
//# sourceMappingURL=setExchangeRate.js.map