import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';
import type { DocumentData } from 'firebase-admin/firestore';

const strictRound = (n: number, d: number = 2): number =>
    Number(Math.round(Number(n + 'e' + d)) + 'e-' + d);

async function loadTransitAccountIds(db: admin.firestore.Firestore): Promise<Set<string>> {
    const snap = await db.collection('branchAccounts').where('type', '==', 'transit').get();
    return new Set(snap.docs.map((doc) => doc.id));
}

function addTransferAmountToBuckets(
    t: DocumentData,
    buckets: Record<string, number>,
): void {
    const parts = t.transferParts;
    if (Array.isArray(parts) && parts.length > 0) {
        for (const p of parts) {
            const cur = (p as { currency?: string }).currency || 'USD';
            const amt = strictRound(Number((p as { amount?: number }).amount) || 0);
            buckets[cur] = strictRound((buckets[cur] || 0) + amt);
        }
        return;
    }
    const cur = t.currency || 'USD';
    const amt = strictRound(Number(t.amount) || 0);
    buckets[cur] = strictRound((buckets[cur] || 0) + amt);
}

interface BranchAnalytics {
    branchId: string;
    branchName: string;
    /** Only meaningful when a single currency exists; otherwise 0 (see balancesByCurrency). */
    totalBalance: number;
    balancesByCurrency: Record<string, number>;
    accounts: Record<string, { balance: number; currency: string }>;
    pendingTransfersCount: number;
    confirmedTransfersCount: number;
    totalCommissions: number;
    monthlySummary: Record<string, { debit: number; credit: number; count: number }>;
}

interface TransferAnalytics {
    /** @deprecated Mixed-currency sum — do not compare across currencies; use volumeByCurrency. */
    totalVolume: number;
    volumeByCurrency: Record<string, number>;
    totalCount: number;
    pendingCount: number;
    confirmedCount: number;
    issuedCount: number;
    rejectedCount: number;
    cancelledCount: number;
    totalCommissions: number;
    avgProcessingMs: number;
}

interface CurrencyAnalytics {
    pair: string;
    latestRate: number;
    rateHistory: { rate: number; date: string }[];
    conversionVolume: number;
}

interface TreasuryOverview {
    totalLiquidity: Record<string, number>;
    capitalByBranchByCurrency: Record<string, Record<string, number>>;
    pendingLockedByCurrency: Record<string, number>;
    largeTransfers: {
        id: string;
        amount: number;
        currency: string;
        from: string;
        to: string;
        date: string;
    }[];
}

export const aggregateAnalytics = onCall({ timeoutSeconds: 120, memory: '512MiB' }, async (request) => {
    const { auth, data } = request;
    if (!auth) throw new HttpsError('unauthenticated', 'Auth required.');

    const db = admin.firestore();

    const userDoc = await db.collection('users').doc(auth.uid).get();
    if (!userDoc.exists) throw new HttpsError('permission-denied', 'User not found.');

    const scope = data?.scope || 'full';
    const excludeCounterparty = data?.excludeCounterpartyAccounts === true;
    const transitIds = excludeCounterparty ? await loadTransitAccountIds(db) : new Set<string>();

    try {
        const results: Record<string, unknown> = {};

        if (scope === 'full' || scope === 'branches') {
            results.branches = await aggregateBranches(db, transitIds);
        }
        if (scope === 'full' || scope === 'transfers') {
            results.transfers = await aggregateTransfers(db);
        }
        if (scope === 'full' || scope === 'currency') {
            results.currency = await aggregateCurrency(db);
        }
        if (scope === 'full' || scope === 'treasury') {
            results.treasury = await aggregateTreasury(db, transitIds);
        }

        return { success: true, data: results, generatedAt: new Date().toISOString() };
    } catch (error: unknown) {
        if (error instanceof HttpsError) throw error;
        const msg = error instanceof Error ? error.message : 'Analytics aggregation failed';
        throw new HttpsError('internal', msg);
    }
});

async function aggregateBranches(
    db: admin.firestore.Firestore,
    excludeAccountIds: Set<string>,
): Promise<BranchAnalytics[]> {
    const branchesSnap = await db.collection('branches').get();
    const results: BranchAnalytics[] = [];

    for (const bDoc of branchesSnap.docs) {
        const bData = bDoc.data();
        const branchId = bDoc.id;

        const balancesSnap = await db.collection('accountBalances')
            .where('branchId', '==', branchId)
            .get();

        const accounts: Record<string, { balance: number; currency: string }> = {};
        const balancesByCurrency: Record<string, number> = {};

        balancesSnap.forEach((d) => {
            if (excludeAccountIds.has(d.id)) return;
            const bd = d.data();
            const cur = bd.currency || 'UNK';
            const bal = strictRound(Number(bd.balance) || 0);
            accounts[d.id] = { balance: bal, currency: cur };
            balancesByCurrency[cur] = strictRound((balancesByCurrency[cur] || 0) + bal);
        });

        const curKeys = Object.keys(balancesByCurrency);
        const totalBalance = curKeys.length === 1 ? balancesByCurrency[curKeys[0]] : 0;

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
        commSnap.forEach((d) => { totalComm += Number(d.data().amount) || 0; });

        const sixMonthsAgo = new Date();
        sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
        const ledgerSnap = await db.collection('ledgerEntries')
            .where('branchId', '==', branchId)
            .where('createdAt', '>=', sixMonthsAgo)
            .orderBy('createdAt', 'desc')
            .get();

        const monthlySummary: Record<string, { debit: number; credit: number; count: number }> = {};
        ledgerSnap.forEach((d) => {
            const ld = d.data();
            const date = ld.createdAt?.toDate ? ld.createdAt.toDate() : new Date();
            const month = `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
            const cur = ld.currency || 'UNK';
            const key = `${month}|${cur}`;
            if (!monthlySummary[key]) monthlySummary[key] = { debit: 0, credit: 0, count: 0 };
            const amt = strictRound(Number(ld.amount) || 0);
            if (ld.type === 'debit') monthlySummary[key].debit = strictRound(monthlySummary[key].debit + amt);
            if (ld.type === 'credit') monthlySummary[key].credit = strictRound(monthlySummary[key].credit + amt);
            monthlySummary[key].count++;
        });

        results.push({
            branchId,
            branchName: bData.name || branchId,
            totalBalance,
            balancesByCurrency,
            accounts,
            pendingTransfersCount: pendingSnap.data().count,
            confirmedTransfersCount: confirmedSnap.data().count,
            totalCommissions: totalComm,
            monthlySummary,
        });
    }

    return results;
}

async function aggregateTransfers(db: admin.firestore.Firestore): Promise<TransferAnalytics> {
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

    const volumeByCurrency: Record<string, number> = {};
    let totalVolume = 0;
    let totalProcessingMs = 0;
    let processedCount = 0;

    allProcessed.forEach((d) => {
        const t = d.data();
        addTransferAmountToBuckets(t, volumeByCurrency);
        totalVolume += Number(t.amount) || 0;

        const confirmedAt = t.confirmedAt?.toDate?.() ?? t.issuedAt?.toDate?.();
        if (confirmedAt && t.createdAt?.toDate) {
            totalProcessingMs += confirmedAt.getTime() - t.createdAt.toDate().getTime();
            processedCount++;
        }
    });

    const commSnap = await db.collection('commissions').get();
    let totalComm = 0;
    commSnap.forEach((d) => { totalComm += Number(d.data().amount) || 0; });

    return {
        totalVolume: strictRound(totalVolume),
        volumeByCurrency,
        totalCount: pending.data().count + confirmed.data().count + issued.data().count +
            rejected.data().count + cancelled.data().count,
        pendingCount: pending.data().count,
        confirmedCount: confirmed.data().count,
        issuedCount: issued.data().count,
        rejectedCount: rejected.data().count,
        cancelledCount: cancelled.data().count,
        totalCommissions: totalComm,
        avgProcessingMs: processedCount > 0 ? Math.round(totalProcessingMs / processedCount) : 0,
    };
}

async function aggregateCurrency(db: admin.firestore.Firestore): Promise<CurrencyAnalytics[]> {
    const ratesSnap = await db.collection('exchangeRates')
        .orderBy('effectiveAt', 'desc')
        .limit(200)
        .get();

    const pairMap: Record<string, CurrencyAnalytics> = {};

    ratesSnap.forEach((d) => {
        const r = d.data();
        const pair = `${r.fromCurrency}/${r.toCurrency}`;
        if (!pairMap[pair]) {
            pairMap[pair] = { pair, latestRate: r.rate, rateHistory: [], conversionVolume: 0 };
        }
        const dateStr = r.effectiveAt?.toDate ? r.effectiveAt.toDate().toISOString() : '';
        pairMap[pair].rateHistory.push({ rate: r.rate, date: dateStr });
    });

    const transfersSnap = await db.collection('transfers')
        .where('status', '==', 'confirmed')
        .get();

    transfersSnap.forEach((d) => {
        const t = d.data();
        const parts = t.transferParts;
        if (Array.isArray(parts) && parts.length > 0) {
            const toC = t.toCurrency || (parts[0] as { currency?: string })?.currency || 'USD';
            for (const p of parts) {
                const fromC = (p as { currency?: string }).currency || 'USD';
                const pair = `${fromC}/${toC}`;
                if (!pairMap[pair]) {
                    pairMap[pair] = { pair, latestRate: 0, rateHistory: [], conversionVolume: 0 };
                }
                pairMap[pair].conversionVolume = strictRound(
                    pairMap[pair].conversionVolume + (Number((p as { amount?: number }).amount) || 0),
                );
            }
            return;
        }
        const fromC = t.currency || 'USD';
        const toC = t.toCurrency || fromC;
        const pair = `${fromC}/${toC}`;
        if (!pairMap[pair]) {
            pairMap[pair] = { pair, latestRate: 0, rateHistory: [], conversionVolume: 0 };
        }
        pairMap[pair].conversionVolume = strictRound(
            pairMap[pair].conversionVolume + (Number(t.amount) || 0),
        );
    });

    return Object.values(pairMap);
}

async function aggregateTreasury(
    db: admin.firestore.Firestore,
    excludeAccountIds: Set<string>,
): Promise<TreasuryOverview> {
    const balancesSnap = await db.collection('accountBalances').get();
    const totalLiquidity: Record<string, number> = {};
    const capitalByBranchByCurrency: Record<string, Record<string, number>> = {};

    balancesSnap.forEach((d) => {
        if (excludeAccountIds.has(d.id)) return;
        const b = d.data();
        const cur = b.currency || 'UNK';
        const bal = strictRound(Number(b.balance) || 0);
        const bid = b.branchId as string;

        totalLiquidity[cur] = strictRound((totalLiquidity[cur] || 0) + bal);

        if (!capitalByBranchByCurrency[bid]) capitalByBranchByCurrency[bid] = {};
        capitalByBranchByCurrency[bid][cur] = strictRound((capitalByBranchByCurrency[bid][cur] || 0) + bal);
    });

    const pendingSnap = await db.collection('transfers')
        .where('status', '==', 'pending')
        .get();
    const pendingLockedByCurrency: Record<string, number> = {};

    pendingSnap.forEach((d) => {
        const t = d.data();
        const amount = strictRound(Number(t.amount) || 0);
        const commission = strictRound(Number(t.commission) || 0);
        const mode = t.commissionMode || 'fromSender';
        const amtCur = t.currency || 'USD';
        const commCur = t.commissionCurrency || amtCur;

        pendingLockedByCurrency[amtCur] = strictRound((pendingLockedByCurrency[amtCur] || 0) + amount);
        if (mode === 'fromSender' && commission !== 0) {
            pendingLockedByCurrency[commCur] = strictRound(
                (pendingLockedByCurrency[commCur] || 0) + commission,
            );
        }
    });

    const thirtyDaysAgo = new Date();
    thirtyDaysAgo.setDate(thirtyDaysAgo.getDate() - 30);
    const largeSnap = await db.collection('transfers')
        .where('createdAt', '>=', thirtyDaysAgo)
        .orderBy('createdAt', 'desc')
        .get();

    const branchSnap = await db.collection('branches').get();
    const branchNames: Record<string, string> = {};
    branchSnap.forEach((doc) => { branchNames[doc.id] = doc.data().name || doc.id; });

    const largeTransfers: TreasuryOverview['largeTransfers'] = [];
    largeSnap.forEach((d) => {
        const t = d.data();
        if ((Number(t.amount) || 0) >= 10000) {
            largeTransfers.push({
                id: d.id,
                amount: t.amount,
                currency: t.currency || 'USD',
                from: branchNames[t.fromBranchId] || t.fromBranchId,
                to: branchNames[t.toBranchId] || t.toBranchId,
                date: t.createdAt?.toDate ? t.createdAt.toDate().toISOString() : '',
            });
        }
    });

    return {
        totalLiquidity,
        capitalByBranchByCurrency,
        pendingLockedByCurrency,
        largeTransfers: largeTransfers.slice(0, 50),
    };
}
