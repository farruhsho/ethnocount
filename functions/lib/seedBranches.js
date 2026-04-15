"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.seedBranches = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const BRANCHES = [
    {
        name: 'Москва', code: 'MSK', baseCurrency: 'RUB',
        accounts: [
            { name: 'Касса RUB', type: 'cash', currency: 'RUB' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта RUB', type: 'card', currency: 'RUB' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Ташкент', code: 'TAS', baseCurrency: 'UZS',
        accounts: [
            { name: 'Касса UZS', type: 'cash', currency: 'UZS' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта UZS', type: 'card', currency: 'UZS' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Бишкек', code: 'BSK', baseCurrency: 'KGS',
        accounts: [
            { name: 'Касса KGS', type: 'cash', currency: 'KGS' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта KGS', type: 'card', currency: 'KGS' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Стамбул', code: 'IST', baseCurrency: 'USD',
        accounts: [
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Касса TRY', type: 'cash', currency: 'TRY' },
            { name: 'Карта USD', type: 'card', currency: 'USD' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Алматы', code: 'ALA', baseCurrency: 'KZT',
        accounts: [
            { name: 'Касса KZT', type: 'cash', currency: 'KZT' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта KZT', type: 'card', currency: 'KZT' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Душанбе', code: 'DUS', baseCurrency: 'TJS',
        accounts: [
            { name: 'Касса TJS', type: 'cash', currency: 'TJS' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта TJS', type: 'card', currency: 'TJS' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Гуанчжоу', code: 'GZH', baseCurrency: 'CNY',
        accounts: [
            { name: 'Касса CNY', type: 'cash', currency: 'CNY' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта CNY', type: 'card', currency: 'CNY' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
    {
        name: 'Дубай', code: 'DXB', baseCurrency: 'AED',
        accounts: [
            { name: 'Касса AED', type: 'cash', currency: 'AED' },
            { name: 'Касса USD', type: 'cash', currency: 'USD' },
            { name: 'Карта AED', type: 'card', currency: 'AED' },
            { name: 'Резерв', type: 'reserve', currency: 'USD' },
            { name: 'Транзит', type: 'transit', currency: 'USD' },
        ],
    },
];
exports.seedBranches = (0, https_1.onCall)(async (request) => {
    var _a;
    const { auth } = request;
    if (!auth) {
        throw new https_1.HttpsError('unauthenticated', 'Auth required.');
    }
    const db = admin.firestore();
    const userDoc = await db.collection('users').doc(auth.uid).get();
    const role = (_a = userDoc.data()) === null || _a === void 0 ? void 0 : _a.role;
    if (!userDoc.exists || (role !== 'creator' && role !== 'admin')) {
        throw new https_1.HttpsError('permission-denied', 'Only creator can seed branches.');
    }
    const existingBranches = await db.collection('branches').get();
    if (!existingBranches.empty) {
        throw new https_1.HttpsError('already-exists', `Branches already exist (${existingBranches.size} found). Seed aborted to prevent duplicates.`);
    }
    const batch = db.batch();
    const created = [];
    for (const branch of BRANCHES) {
        const branchRef = db.collection('branches').doc();
        batch.set(branchRef, {
            name: branch.name,
            code: branch.code,
            baseCurrency: branch.baseCurrency,
            isActive: true,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        for (const acc of branch.accounts) {
            const accRef = db.collection('branchAccounts').doc();
            batch.set(accRef, {
                branchId: branchRef.id,
                name: acc.name,
                type: acc.type,
                currency: acc.currency,
                isActive: true,
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            const balRef = db.collection('accountBalances').doc(accRef.id);
            batch.set(balRef, {
                accountId: accRef.id,
                branchId: branchRef.id,
                balance: 0,
                currency: acc.currency,
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
        }
        created.push({
            branchId: branchRef.id,
            name: branch.name,
            accountCount: branch.accounts.length,
        });
    }
    const auditRef = db.collection('auditLogs').doc();
    batch.set(auditRef, {
        action: 'seed_branches',
        entityType: 'system',
        entityId: 'init',
        performedBy: auth.uid,
        details: { branchCount: BRANCHES.length, totalAccounts: BRANCHES.reduce((s, b) => s + b.accounts.length, 0) },
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    await batch.commit();
    return { success: true, branches: created };
});
//# sourceMappingURL=seedBranches.js.map