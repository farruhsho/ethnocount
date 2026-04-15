"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.aggregateAnalytics = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
exports.aggregateAnalytics = (0, https_1.onCall)({ timeoutSeconds: 120, memory: '512MiB' }, async (request) => {
    const { auth, data } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'Auth required.');
    const db = admin.firestore();
    const userDoc = await db.collection('users').doc(auth.uid).get();
    if (!userDoc.exists)
        throw new https_1.HttpsError('permission-denied', 'User not found.');
    const scope = (data === null || data === void 0 ? void 0 : data.scope) || 'full';
    try {
        const results = {};
        if (scope === 'full' || scope === 'branches') {
            results.branches = await aggregateBranches(db);
        }
        if (scope === 'full' || scope === 'transfers') {
            results.transfers = await aggregateTransfers(db);
        }
        if (scope === 'full' || scope === 'currency') {
            results.currency = await aggregateCurrency(db);
        }
        if (scope === 'full' || scope === 'treasury') {
            results.treasury = await aggregateTreasury(db);
        }
        return { success: true, data: results, generatedAt: new Date().toISOString() };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Analytics aggregation failed');
    }
});
async function aggregateBranches(db) {
    const branchesSnap = await db.collection('branches').get();
    const results = [];
    for (const bDoc of branchesSnap.docs) {
        const bData = bDoc.data();
        const branchId = bDoc.id;
        const balancesSnap = await db.collection('accountBalances')
            .where('branchId', '==', branchId)
            .get();
        const accounts = {};
        let totalBalance = 0;
        balancesSnap.forEach(d => {
            const bd = d.data();
            accounts[d.id] = { balance: bd.balance, currency: bd.currency };
            totalBalance += bd.balance;
        });
        const pendingSnap = await db.collection('transfers')
            .where('fromBranchId', '==', branchId)
            .where('status', '==', 'pending')
            .count().get();
        const confirmedSnap = await db.collection('transfers')
            .where('fromBranchId', '==', branchId)
            .where('status', '==', 'confirmed')
            .count().get();
        const commSnap = await db.collection('commissions')
            .where('branchId', '==', branchId)
            .get();
        let totalComm = 0;
        commSnap.forEach(d => { totalComm += d.data().amount || 0; });
        // Monthly aggregation from ledger (last 6 months)
        const sixMonthsAgo = new Date();
        sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
        const ledgerSnap = await db.collection('ledgerEntries')
            .where('branchId', '==', branchId)
            .where('createdAt', '>=', sixMonthsAgo)
            .orderBy('createdAt', 'desc')
            .get();
        const monthlySummary = {};
        ledgerSnap.forEach(d => {
            var _a;
            const ld = d.data();
            const date = ((_a = ld.createdAt) === null || _a === void 0 ? void 0 : _a.toDate) ? ld.createdAt.toDate() : new Date();
            const key = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
            if (!monthlySummary[key])
                monthlySummary[key] = { debit: 0, credit: 0, count: 0 };
            if (ld.type === 'debit')
                monthlySummary[key].debit += ld.amount;
            if (ld.type === 'credit')
                monthlySummary[key].credit += ld.amount;
            monthlySummary[key].count++;
        });
        results.push({
            branchId,
            branchName: bData.name || branchId,
            totalBalance,
            accounts,
            pendingTransfersCount: pendingSnap.data().count,
            confirmedTransfersCount: confirmedSnap.data().count,
            totalCommissions: totalComm,
            monthlySummary,
        });
    }
    return results;
}
async function aggregateTransfers(db) {
    const [pending, confirmed, issued, rejected, cancelled] = await Promise.all([
        db.collection('transfers').where('status', '==', 'pending').count().get(),
        db.collection('transfers').where('status', '==', 'confirmed').count().get(),
        db.collection('transfers').where('status', '==', 'issued').count().get(),
        db.collection('transfers').where('status', '==', 'rejected').count().get(),
        db.collection('transfers').where('status', '==', 'cancelled').count().get(),
    ]);
    const [confirmedSnap, issuedSnap] = await Promise.all([
        db.collection('transfers').where('status', '==', 'confirmed').limit(500).get(),
        db.collection('transfers').where('status', '==', 'issued').limit(500).get(),
    ]);
    const allProcessed = [...confirmedSnap.docs, ...issuedSnap.docs];
    let totalVolume = 0;
    let totalProcessingMs = 0;
    let processedCount = 0;
    allProcessed.forEach(d => {
        var _a, _b, _c, _d, _e, _f;
        const t = d.data();
        totalVolume += t.amount || 0;
        const confirmedAt = (_c = (_b = (_a = t.confirmedAt) === null || _a === void 0 ? void 0 : _a.toDate) === null || _b === void 0 ? void 0 : _b.call(_a)) !== null && _c !== void 0 ? _c : (_e = (_d = t.issuedAt) === null || _d === void 0 ? void 0 : _d.toDate) === null || _e === void 0 ? void 0 : _e.call(_d);
        if (confirmedAt && ((_f = t.createdAt) === null || _f === void 0 ? void 0 : _f.toDate)) {
            totalProcessingMs += confirmedAt.getTime() - t.createdAt.toDate().getTime();
            processedCount++;
        }
    });
    const commSnap = await db.collection('commissions').get();
    let totalComm = 0;
    commSnap.forEach(d => { totalComm += d.data().amount || 0; });
    return {
        totalVolume,
        totalCount: pending.data().count + confirmed.data().count + issued.data().count + rejected.data().count + cancelled.data().count,
        pendingCount: pending.data().count,
        confirmedCount: confirmed.data().count,
        issuedCount: issued.data().count,
        rejectedCount: rejected.data().count,
        cancelledCount: cancelled.data().count,
        totalCommissions: totalComm,
        avgProcessingMs: processedCount > 0 ? Math.round(totalProcessingMs / processedCount) : 0,
    };
}
async function aggregateCurrency(db) {
    const ratesSnap = await db.collection('exchangeRates')
        .orderBy('effectiveAt', 'desc')
        .limit(200)
        .get();
    const pairMap = {};
    ratesSnap.forEach(d => {
        var _a;
        const r = d.data();
        const pair = `${r.fromCurrency}/${r.toCurrency}`;
        if (!pairMap[pair]) {
            pairMap[pair] = { pair, latestRate: r.rate, rateHistory: [], conversionVolume: 0 };
        }
        const dateStr = ((_a = r.effectiveAt) === null || _a === void 0 ? void 0 : _a.toDate) ? r.effectiveAt.toDate().toISOString() : '';
        pairMap[pair].rateHistory.push({ rate: r.rate, date: dateStr });
    });
    // Conversion volume from transfers
    const transfersSnap = await db.collection('transfers')
        .where('status', '==', 'confirmed')
        .get();
    transfersSnap.forEach(d => {
        const t = d.data();
        if (t.currency && t.convertedAmount) {
            const pair = `${t.currency}/${t.toCurrency || 'UNK'}`;
            if (pairMap[pair]) {
                pairMap[pair].conversionVolume += t.amount || 0;
            }
        }
    });
    return Object.values(pairMap);
}
async function aggregateTreasury(db) {
    const balancesSnap = await db.collection('accountBalances').get();
    const totalLiquidity = {};
    const capitalByBranch = {};
    balancesSnap.forEach(d => {
        const b = d.data();
        const cur = b.currency || 'UNK';
        totalLiquidity[cur] = (totalLiquidity[cur] || 0) + b.balance;
        capitalByBranch[b.branchId] = (capitalByBranch[b.branchId] || 0) + b.balance;
    });
    const pendingSnap = await db.collection('transfers')
        .where('status', '==', 'pending')
        .get();
    let pendingLocked = 0;
    pendingSnap.forEach(d => {
        const t = d.data();
        pendingLocked += (t.amount || 0) + (t.commission || 0);
    });
    // Large transfers (>10000) in last 30 days
    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    const largeSnap = await db.collection('transfers')
        .where('createdAt', '>=', thirtyDaysAgo)
        .orderBy('createdAt', 'desc')
        .get();
    const branchSnap = await db.collection('branches').get();
    const branchNames = {};
    branchSnap.forEach(d => { branchNames[d.id] = d.data().name || d.id; });
    const largeTransfers = [];
    largeSnap.forEach(d => {
        var _a;
        const t = d.data();
        if ((t.amount || 0) >= 10000) {
            largeTransfers.push({
                id: d.id,
                amount: t.amount,
                from: branchNames[t.fromBranchId] || t.fromBranchId,
                to: branchNames[t.toBranchId] || t.toBranchId,
                date: ((_a = t.createdAt) === null || _a === void 0 ? void 0 : _a.toDate) ? t.createdAt.toDate().toISOString() : '',
            });
        }
    });
    return {
        totalLiquidity,
        capitalByBranch,
        pendingLocked,
        largeTransfers: largeTransfers.slice(0, 50),
    };
}
//# sourceMappingURL=aggregateAnalytics.js.map