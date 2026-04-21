/**
 * EthnoCount: Firebase Firestore → Supabase Migration Script
 *
 * Prerequisites:
 *   1. Place your Firebase service account key as  ./serviceAccountKey.json
 *      (Firebase Console → Project Settings → Service Accounts → Generate new private key)
 *   2. Copy .env.example to .env and fill in your Supabase URL + service_role key
 *   3. Make sure the Supabase schema is already applied (001_initial_schema.sql)
 *   4. Run: npm install && npm run migrate
 */

import { readFileSync } from 'fs';
import { randomUUID } from 'crypto';
import admin from 'firebase-admin';
import { createClient } from '@supabase/supabase-js';
import 'dotenv/config';

// ─── Config ───
const serviceAccount = JSON.parse(readFileSync('./serviceAccountKey.json', 'utf8'));
const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_KEY = process.env.SUPABASE_SERVICE_KEY;

if (!SUPABASE_URL || !SUPABASE_SERVICE_KEY) {
  console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_KEY in .env');
  process.exit(1);
}

// ─── Initialize Firebase Admin ───
admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
const db = admin.firestore();
const auth = admin.auth();

// ─── Initialize Supabase (service_role bypasses RLS) ───
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// ─── ID Mappings: old Firebase ID → new Supabase UUID ───
const userIdMap = new Map();
const branchIdMap = new Map();
const accountIdMap = new Map();
const transferIdMap = new Map();
const clientIdMap = new Map();
const purchaseIdMap = new Map();

// ─── Helpers ───
function toISO(ts) {
  if (!ts) return null;
  if (ts.toDate) return ts.toDate().toISOString();
  if (ts instanceof Date) return ts.toISOString();
  if (typeof ts === 'string') return ts;
  if (typeof ts === 'number') return new Date(ts).toISOString();
  return null;
}

function mapUserId(oldId) {
  if (!oldId) return null;
  return userIdMap.get(oldId) ?? oldId;
}

function mapBranchId(oldId) {
  if (!oldId) return null;
  return branchIdMap.get(oldId) ?? oldId;
}

function mapAccountId(oldId) {
  if (!oldId) return null;
  return accountIdMap.get(oldId) ?? oldId;
}

function mapTransferId(oldId) {
  if (!oldId) return null;
  return transferIdMap.get(oldId) ?? oldId;
}

function mapClientId(oldId) {
  if (!oldId) return null;
  return clientIdMap.get(oldId) ?? oldId;
}

function mapPurchaseId(oldId) {
  if (!oldId) return null;
  return purchaseIdMap.get(oldId) ?? oldId;
}

async function fetchCollection(name) {
  const snapshot = await db.collection(name).get();
  console.log(`  Firestore "${name}": ${snapshot.size} docs`);
  return snapshot.docs;
}

async function insertBatch(table, rows, { upsertOnConflict } = {}) {
  if (rows.length === 0) return;
  const CHUNK = 500;
  for (let i = 0; i < rows.length; i += CHUNK) {
    const chunk = rows.slice(i, i + CHUNK);
    const query = upsertOnConflict
      ? supabase.from(table).upsert(chunk, { onConflict: upsertOnConflict })
      : supabase.from(table).insert(chunk);
    const { error } = await query;
    if (error) {
      console.error(`  ERROR writing into "${table}" (chunk ${i / CHUNK + 1}):`, error.message);
      for (const row of chunk) {
        const rowQuery = upsertOnConflict
          ? supabase.from(table).upsert(row, { onConflict: upsertOnConflict })
          : supabase.from(table).insert(row);
        const { error: rowErr } = await rowQuery;
        if (rowErr) {
          console.error(`    Row failed:`, JSON.stringify(row).slice(0, 200), rowErr.message);
        }
      }
    }
  }
}

// Direct REST call to /auth/v1/admin/users — bypasses @supabase/auth-js,
// which sometimes times out on Windows/node24 due to undici IPv6 lookup behavior.
async function loadAllAuthUsers() {
  const byEmail = new Map();
  let page = 1;
  const perPage = 1000;
  for (;;) {
    const url = `${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=${perPage}`;
    const res = await fetch(url, {
      headers: {
        apikey: SUPABASE_SERVICE_KEY,
        Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
      },
    });
    if (!res.ok) throw new Error(`listUsers ${res.status}: ${await res.text()}`);
    const json = await res.json();
    const users = json.users ?? [];
    for (const u of users) {
      if (u.email) byEmail.set(u.email.toLowerCase(), u.id);
    }
    if (users.length < perPage) break;
    page += 1;
  }
  return byEmail;
}

// Direct REST call to create an auth user — same reason as above.
async function createAuthUser({ email, password, displayName }) {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: {
      apikey: SUPABASE_SERVICE_KEY,
      Authorization: `Bearer ${SUPABASE_SERVICE_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      email,
      password,
      email_confirm: true,
      user_metadata: { display_name: displayName },
    }),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    return { error: { message: json.msg || json.error_description || `HTTP ${res.status}` } };
  }
  return { data: { user: json } };
}

// ─────────────────────────────────────────────
// Step 1: Migrate Firebase Auth → Supabase Auth
// ─────────────────────────────────────────────
async function migrateUsers() {
  console.log('\n═══ Step 1: Migrating Firebase Auth users → Supabase Auth ═══');

  // List all Firebase Auth users
  const firebaseUsers = [];
  let pageToken;
  do {
    const result = await auth.listUsers(1000, pageToken);
    firebaseUsers.push(...result.users);
    pageToken = result.pageToken;
  } while (pageToken);

  console.log(`  Firebase Auth: ${firebaseUsers.length} users`);

  // Get Firestore user profiles for extra data
  const userDocs = await fetchCollection('users');
  const profileMap = new Map();
  for (const doc of userDocs) {
    profileMap.set(doc.id, doc.data());
  }

  // Pre-load all existing Supabase Auth users once (avoids N x listUsers calls)
  console.log('  Loading existing Supabase Auth users...');
  const existingByEmail = await loadAllAuthUsers();
  console.log(`  Existing Supabase Auth: ${existingByEmail.size} users`);

  for (const fbUser of firebaseUsers) {
    const oldUid = fbUser.uid;
    const email = (fbUser.email || '').toLowerCase();
    if (!email) {
      console.log(`  Skipping user ${oldUid} — no email`);
      continue;
    }

    const existingId = existingByEmail.get(email);
    if (existingId) {
      userIdMap.set(oldUid, existingId);
      console.log(`  User ${email}: already exists → ${existingId}`);
      continue;
    }

    const tempPassword = 'Temp_' + randomUUID().slice(0, 12) + '!';
    const { data, error } = await createAuthUser({
      email,
      password: tempPassword,
      displayName: fbUser.displayName || profileMap.get(oldUid)?.displayName || '',
    });

    if (error) {
      console.error(`  ERROR creating user ${email}:`, error.message);
      continue;
    }

    const newUuid = data.user.id;
    userIdMap.set(oldUid, newUuid);
    existingByEmail.set(email, newUuid);
    console.log(`  User ${email}: ${oldUid} → ${newUuid}`);
  }

  // Now insert user profiles into public.users
  console.log('  Inserting user profiles into public.users...');
  const rows = [];
  for (const doc of userDocs) {
    const d = doc.data();
    const newId = userIdMap.get(doc.id);
    if (!newId) {
      console.log(`  Skipping profile for ${doc.id} — no Supabase Auth user`);
      continue;
    }

    // Normalize role: 'admin' → 'creator' (old Firestore compat)
    let role = d.role || 'accountant';
    if (role === 'admin') role = 'creator';

    rows.push({
      id: newId,
      display_name: d.displayName || '',
      email: d.email || '',
      photo_url: d.photoUrl || null,
      phone: d.phone || null,
      role: role,
      assigned_branch_ids: (d.assignedBranchIds || []).map(id => branchIdMap.get(id) || id),
      permissions: d.permissions || {
        canTransfers: true,
        canPurchases: true,
        canManageTransfers: false,
        canManagePurchases: false,
        canBranchTopUp: false,
        canClients: true,
        canLedger: true,
        canAnalytics: true,
        canReports: true,
        canExchangeRates: true,
        canBranchesView: true,
      },
      is_active: d.isActive !== false,
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }
  // Upsert: on_auth_user_created trigger (migration 008) has already inserted
  // a baseline row for each admin.createUser call. We upsert by id to overwrite
  // the baseline with the authoritative profile (role, branches, permissions).
  await insertBatch('users', rows, { upsertOnConflict: 'id' });
  console.log(`  ✓ ${rows.length} user profiles upserted`);
}

// ─────────────────────────────────────────────
// Step 2: Migrate Branches
// ─────────────────────────────────────────────
async function migrateBranches() {
  console.log('\n═══ Step 2: Migrating branches ═══');
  const docs = await fetchCollection('branches');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const newId = randomUUID();
    branchIdMap.set(doc.id, newId);

    rows.push({
      id: newId,
      name: d.name || '',
      code: d.code || '',
      base_currency: d.baseCurrency || 'USD',
      is_active: d.isActive !== false,
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('branches', rows);
  console.log(`  ✓ ${rows.length} branches migrated`);
}

// ─────────────────────────────────────────────
// Step 3: Migrate Branch Accounts
// ─────────────────────────────────────────────
async function migrateBranchAccounts() {
  console.log('\n═══ Step 3: Migrating branch accounts ═══');
  const docs = await fetchCollection('branchAccounts');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const newId = randomUUID();
    accountIdMap.set(doc.id, newId);

    rows.push({
      id: newId,
      branch_id: mapBranchId(d.branchId),
      name: d.name || '',
      type: d.type || 'cash',
      currency: d.currency || 'USD',
      is_active: d.isActive !== false,
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('branch_accounts', rows);
  console.log(`  ✓ ${rows.length} branch accounts migrated`);
}

// ─────────────────────────────────────────────
// Step 4: Migrate Account Balances
// ─────────────────────────────────────────────
async function migrateAccountBalances() {
  console.log('\n═══ Step 4: Migrating account balances ═══');
  const docs = await fetchCollection('accountBalances');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const mappedAccountId = mapAccountId(doc.id);

    rows.push({
      account_id: mappedAccountId,
      branch_id: mapBranchId(d.branchId),
      balance: d.balance ?? 0,
      currency: d.currency || 'USD',
      updated_at: toISO(d.updatedAt) || new Date().toISOString(),
    });
  }

  await insertBatch('account_balances', rows);
  console.log(`  ✓ ${rows.length} account balances migrated`);
}

// ─────────────────────────────────────────────
// Step 5: Migrate Transfers
// ─────────────────────────────────────────────
async function migrateTransfers() {
  console.log('\n═══ Step 5: Migrating transfers ═══');
  const docs = await fetchCollection('transfers');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const newId = randomUUID();
    transferIdMap.set(doc.id, newId);

    rows.push({
      id: newId,
      transaction_code: d.transactionCode || null,
      from_branch_id: mapBranchId(d.fromBranchId),
      to_branch_id: mapBranchId(d.toBranchId),
      from_account_id: mapAccountId(d.fromAccountId),
      to_account_id: d.toAccountId ? (accountIdMap.get(d.toAccountId) || d.toAccountId) : '',
      amount: d.amount ?? 0,
      currency: d.currency || 'USD',
      transfer_parts: d.transferParts || null,
      to_currency: d.toCurrency || null,
      exchange_rate: d.exchangeRate ?? 1,
      converted_amount: d.convertedAmount ?? 0,
      commission: d.commission ?? 0,
      commission_currency: d.commissionCurrency || 'USD',
      commission_type: d.commissionType || 'fixed',
      commission_value: d.commissionValue ?? 0,
      commission_mode: d.commissionMode || 'fromSender',
      description: d.description || null,
      client_id: d.clientId || null,
      sender_name: d.senderName || null,
      sender_phone: d.senderPhone || null,
      sender_info: d.senderInfo || null,
      receiver_name: d.receiverName || null,
      receiver_phone: d.receiverPhone || null,
      receiver_info: d.receiverInfo || null,
      status: d.status || 'pending',
      created_by: mapUserId(d.createdBy),
      confirmed_by: mapUserId(d.confirmedBy) || null,
      issued_by: mapUserId(d.issuedBy) || null,
      rejected_by: mapUserId(d.rejectedBy) || null,
      rejection_reason: d.rejectionReason || null,
      idempotency_key: d.idempotencyKey || randomUUID(),
      amendment_history: d.amendmentHistory || '[]',
      created_at: toISO(d.createdAt) || new Date().toISOString(),
      confirmed_at: toISO(d.confirmedAt) || null,
      issued_at: toISO(d.issuedAt) || null,
      rejected_at: toISO(d.rejectedAt) || null,
    });
  }

  await insertBatch('transfers', rows);
  console.log(`  ✓ ${rows.length} transfers migrated`);
}

// ─────────────────────────────────────────────
// Step 6: Migrate Ledger Entries
// ─────────────────────────────────────────────
async function migrateLedgerEntries() {
  console.log('\n═══ Step 6: Migrating ledger entries ═══');
  const docs = await fetchCollection('ledgerEntries');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    // Map referenceId based on referenceType
    let refId = d.referenceId || '';
    if (d.referenceType === 'transfer') {
      refId = mapTransferId(refId) || refId;
    } else if (d.referenceType === 'purchase') {
      refId = mapPurchaseId(refId) || refId;
    }

    rows.push({
      id: randomUUID(),
      branch_id: mapBranchId(d.branchId),
      account_id: mapAccountId(d.accountId),
      type: d.type || 'debit',
      amount: d.amount ?? 0,
      currency: d.currency || 'USD',
      reference_type: d.referenceType || 'adjustment',
      reference_id: refId,
      transaction_code: d.transactionCode || null,
      description: d.description || '',
      created_by: mapUserId(d.createdBy),
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('ledger_entries', rows);
  console.log(`  ✓ ${rows.length} ledger entries migrated`);
}

// ─────────────────────────────────────────────
// Step 7: Migrate Purchases
// ─────────────────────────────────────────────
async function migratePurchases() {
  console.log('\n═══ Step 7: Migrating purchases ═══');
  const docs = await fetchCollection('purchases');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const newId = randomUUID();
    purchaseIdMap.set(doc.id, newId);

    // Map account IDs inside payments array
    const payments = (d.payments || []).map(p => ({
      ...p,
      accountId: mapAccountId(p.accountId) || p.accountId,
    }));

    rows.push({
      id: newId,
      transaction_code: d.transactionCode || '',
      branch_id: mapBranchId(d.branchId),
      client_id: d.clientId || null,
      client_name: d.clientName || null,
      description: d.description || '',
      category: d.category || null,
      total_amount: d.totalAmount ?? 0,
      currency: d.currency || 'USD',
      payments: payments,
      created_by: mapUserId(d.createdBy),
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('purchases', rows);
  console.log(`  ✓ ${rows.length} purchases migrated`);
}

// ─────────────────────────────────────────────
// Step 8: Migrate Deleted Purchases
// ─────────────────────────────────────────────
async function migrateDeletedPurchases() {
  console.log('\n═══ Step 8: Migrating deleted purchases ═══');
  const docs = await fetchCollection('deleted_purchases');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      original_purchase_id: d.originalPurchaseId || doc.id,
      transaction_code: d.transactionCode || null,
      branch_id: mapBranchId(d.branchId) || null,
      client_id: d.clientId || null,
      client_name: d.clientName || null,
      description: d.description || null,
      category: d.category || null,
      total_amount: d.totalAmount ?? null,
      currency: d.currency || null,
      payments: d.payments || null,
      created_by_user_id: mapUserId(d.createdByUserId || d.createdBy) || null,
      original_created_at: toISO(d.originalCreatedAt) || null,
      deleted_by_user_id: mapUserId(d.deletedByUserId || d.deletedBy),
      deleted_by_user_name: d.deletedByUserName || null,
      reason: d.reason || null,
      original_data: d.originalData || d,
      deleted_at: toISO(d.deletedAt) || new Date().toISOString(),
    });
  }

  await insertBatch('deleted_purchases', rows);
  console.log(`  ✓ ${rows.length} deleted purchases migrated`);
}

// ─────────────────────────────────────────────
// Step 9: Migrate Clients
// ─────────────────────────────────────────────
async function migrateClients() {
  console.log('\n═══ Step 9: Migrating clients ═══');
  const docs = await fetchCollection('clients');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const newId = randomUUID();
    clientIdMap.set(doc.id, newId);

    rows.push({
      id: newId,
      client_code: d.clientCode || '',
      name: d.name || '',
      phone: d.phone || '',
      country: d.country || '',
      currency: d.currency || 'USD',
      branch_id: d.branchId || null,
      wallet_currencies: d.walletCurrencies || [],
      is_active: d.isActive !== false,
      created_by: mapUserId(d.createdBy),
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('clients', rows);
  console.log(`  ✓ ${rows.length} clients migrated`);
}

// ─────────────────────────────────────────────
// Step 10: Migrate Client Balances
// ─────────────────────────────────────────────
async function migrateClientBalances() {
  console.log('\n═══ Step 10: Migrating client balances ═══');
  const docs = await fetchCollection('clientBalances');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();
    const mappedClientId = mapClientId(d.clientId || doc.id);

    rows.push({
      client_id: mappedClientId,
      balances: d.balances || {},
      balance: d.balance ?? 0,
      currency: d.currency || 'USD',
      updated_at: toISO(d.updatedAt) || new Date().toISOString(),
    });
  }

  await insertBatch('client_balances', rows);
  console.log(`  ✓ ${rows.length} client balances migrated`);
}

// ─────────────────────────────────────────────
// Step 11: Migrate Client Transactions
// ─────────────────────────────────────────────
async function migrateClientTransactions() {
  console.log('\n═══ Step 11: Migrating client transactions ═══');
  const docs = await fetchCollection('clientTransactions');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      client_id: mapClientId(d.clientId),
      transaction_code: d.transactionCode || null,
      type: d.type || 'deposit',
      amount: d.amount ?? 0,
      currency: d.currency || 'USD',
      balance_after: d.balanceAfter ?? null,
      description: d.description || null,
      created_by: mapUserId(d.createdBy),
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('client_transactions', rows);
  console.log(`  ✓ ${rows.length} client transactions migrated`);
}

// ─────────────────────────────────────────────
// Step 12: Migrate Exchange Rates
// ─────────────────────────────────────────────
async function migrateExchangeRates() {
  console.log('\n═══ Step 12: Migrating exchange rates ═══');
  const docs = await fetchCollection('exchangeRates');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      from_currency: d.fromCurrency || '',
      to_currency: d.toCurrency || '',
      rate: d.rate ?? 0,
      set_by: mapUserId(d.setBy),
      effective_at: toISO(d.effectiveAt) || new Date().toISOString(),
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('exchange_rates', rows);
  console.log(`  ✓ ${rows.length} exchange rates migrated`);
}

// ─────────────────────────────────────────────
// Step 13: Migrate Notifications
// ─────────────────────────────────────────────
async function migrateNotifications() {
  console.log('\n═══ Step 13: Migrating notifications ═══');
  const docs = await fetchCollection('notifications');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    // Map IDs inside the data object
    const nData = { ...(d.data || {}) };
    if (nData.transferId) nData.transferId = mapTransferId(nData.transferId) || nData.transferId;

    rows.push({
      id: randomUUID(),
      target_branch_id: mapBranchId(d.targetBranchId) || d.targetBranchId || '',
      target_user_id: mapUserId(d.targetUserId) || null,
      type: d.type || 'systemAlert',
      title: d.title || '',
      body: d.body || '',
      data: nData,
      is_read: d.isRead === true,
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('notifications', rows);
  console.log(`  ✓ ${rows.length} notifications migrated`);
}

// ─────────────────────────────────────────────
// Step 14: Migrate Audit Logs
// ─────────────────────────────────────────────
async function migrateAuditLogs() {
  console.log('\n═══ Step 14: Migrating audit logs ═══');
  const docs = await fetchCollection('auditLogs');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      action: d.action || '',
      entity_type: d.entityType || '',
      entity_id: d.entityId || '',
      performed_by: mapUserId(d.performedBy),
      details: d.details || {},
      ip_address: d.ipAddress || null,
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('audit_logs', rows);
  console.log(`  ✓ ${rows.length} audit logs migrated`);
}

// ─────────────────────────────────────────────
// Step 15: Migrate System Audit Logs
// ─────────────────────────────────────────────
async function migrateSystemAuditLogs() {
  console.log('\n═══ Step 15: Migrating system audit logs ═══');
  const docs = await fetchCollection('systemAuditLogs');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      action: d.action || '',
      entity_type: d.entityType || '',
      entity_id: d.entityId || '',
      performed_by: mapUserId(d.performedBy),
      details: d.details || {},
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('system_audit_logs', rows);
  console.log(`  ✓ ${rows.length} system audit logs migrated`);
}

// ─────────────────────────────────────────────
// Step 16: Migrate Commissions
// ─────────────────────────────────────────────
async function migrateCommissions() {
  console.log('\n═══ Step 16: Migrating commissions ═══');
  const docs = await fetchCollection('commissions');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: randomUUID(),
      transfer_id: mapTransferId(d.transferId) || null,
      branch_id: mapBranchId(d.branchId) || null,
      amount: d.amount ?? 0,
      currency: d.currency || 'USD',
      type: d.type || 'fixed',
      created_at: toISO(d.createdAt) || new Date().toISOString(),
    });
  }

  await insertBatch('commissions', rows);
  console.log(`  ✓ ${rows.length} commissions migrated`);
}

// ─────────────────────────────────────────────
// Step 17: Migrate Counters
// ─────────────────────────────────────────────
async function migrateCounters() {
  console.log('\n═══ Step 17: Migrating counters ═══');
  const docs = await fetchCollection('counters');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: doc.id,
      data: d,
    });
  }

  await insertBatch('counters', rows);
  console.log(`  ✓ ${rows.length} counters migrated`);
}

// ─────────────────────────────────────────────
// Step 18: Migrate System Settings
// ─────────────────────────────────────────────
async function migrateSystemSettings() {
  console.log('\n═══ Step 18: Migrating system settings ═══');
  const docs = await fetchCollection('system_settings');
  const rows = [];

  for (const doc of docs) {
    const d = doc.data();

    rows.push({
      id: doc.id || 'general',
      session_duration_days: d.sessionDurationDays ?? d.session_duration_days ?? 7,
      data: d,
    });
  }

  await insertBatch('system_settings', rows);
  console.log(`  ✓ ${rows.length} system settings migrated`);
}

// ─────────────────────────────────────────────
// Step 19: Migrate User Sessions
// ─────────────────────────────────────────────
async function migrateUserSessions() {
  console.log('\n═══ Step 19: Migrating user sessions ═══');
  const userSessionDocs = await fetchCollection('user_sessions');
  const rows = [];

  for (const userDoc of userSessionDocs) {
    const userId = userDoc.id;
    const mappedUserId = mapUserId(userId);
    if (!mappedUserId) continue;

    // Fetch subcollection sessions
    const sessionSnapshot = await db
      .collection('user_sessions')
      .doc(userId)
      .collection('sessions')
      .get();

    for (const sessionDoc of sessionSnapshot.docs) {
      const d = sessionDoc.data();

      rows.push({
        id: sessionDoc.id,
        user_id: mappedUserId,
        platform: d.platform || 'Unknown',
        device_type: d.deviceType || 'Unknown',
        ip: d.ip || null,
        last_seen: toISO(d.lastSeen) || new Date().toISOString(),
        created_at: toISO(d.createdAt) || new Date().toISOString(),
      });
    }
  }

  await insertBatch('user_sessions', rows);
  console.log(`  ✓ ${rows.length} user sessions migrated`);
}

// ─────────────────────────────────────────────
// Now re-update user profiles with correct branch IDs
// (branches weren't mapped yet when users were inserted)
// ─────────────────────────────────────────────
async function fixUserBranchIds() {
  console.log('\n═══ Fixing user assigned_branch_ids with correct branch UUIDs ═══');
  const userDocs = await fetchCollection('users');

  for (const doc of userDocs) {
    const d = doc.data();
    const newUserId = userIdMap.get(doc.id);
    if (!newUserId) continue;

    const oldBranchIds = d.assignedBranchIds || [];
    if (oldBranchIds.length === 0) continue;

    const newBranchIds = oldBranchIds.map(id => mapBranchId(id) || id);

    const { error } = await supabase
      .from('users')
      .update({ assigned_branch_ids: newBranchIds })
      .eq('id', newUserId);

    if (error) {
      console.error(`  ERROR fixing branch IDs for user ${newUserId}:`, error.message);
    }
  }
  console.log('  ✓ Branch IDs fixed');
}

// ─────────────────────────────────────────────
// MAIN
// ─────────────────────────────────────────────
async function main() {
  console.log('╔══════════════════════════════════════════════════╗');
  console.log('║  EthnoCount: Firebase → Supabase Migration      ║');
  console.log('╚══════════════════════════════════════════════════╝');
  console.log(`  Firebase project: ${serviceAccount.project_id}`);
  console.log(`  Supabase URL: ${SUPABASE_URL}`);
  console.log('');

  try {
    // Order matters — respect foreign key dependencies
    await migrateUsers();       // 1. Users (creates Auth + profiles)
    await migrateBranches();    // 2. Branches
    await migrateBranchAccounts(); // 3. Branch Accounts (refs branches)
    await migrateAccountBalances(); // 4. Account Balances (refs accounts + branches)
    await migrateClients();     // 5. Clients (refs users)
    await migrateClientBalances(); // 6. Client Balances (refs clients)
    await migrateTransfers();   // 7. Transfers (refs branches, accounts, users)
    await migrateLedgerEntries(); // 8. Ledger (refs branches, accounts, users, transfers)
    await migratePurchases();   // 9. Purchases (refs branches, users)
    await migrateDeletedPurchases(); // 10. Deleted Purchases (refs users)
    await migrateClientTransactions(); // 11. Client Transactions (refs clients, users)
    await migrateExchangeRates(); // 12. Exchange Rates (refs users)
    await migrateNotifications(); // 13. Notifications
    await migrateAuditLogs();   // 14. Audit Logs (refs users)
    await migrateSystemAuditLogs(); // 15. System Audit Logs (refs users)
    await migrateCommissions(); // 16. Commissions (refs transfers)
    await migrateCounters();    // 17. Counters
    await migrateSystemSettings(); // 18. System Settings
    await migrateUserSessions(); // 19. User Sessions (refs users)
    await fixUserBranchIds();   // Fix branch ID refs in user profiles

    // Save the ID mapping
    const fs = await import('fs');
    const mapping = {
      users: Object.fromEntries(userIdMap),
      branches: Object.fromEntries(branchIdMap),
      accounts: Object.fromEntries(accountIdMap),
      transfers: Object.fromEntries(transferIdMap),
      clients: Object.fromEntries(clientIdMap),
      purchases: Object.fromEntries(purchaseIdMap),
    };
    fs.writeFileSync('./id_mapping.json', JSON.stringify(mapping, null, 2));
    console.log('\n  ✓ ID mapping saved to id_mapping.json');

    console.log('\n╔══════════════════════════════════════════════════╗');
    console.log('║  Migration complete!                             ║');
    console.log('╚══════════════════════════════════════════════════╝');
    console.log('\nID Mappings:');
    console.log(`  Users:     ${userIdMap.size}`);
    console.log(`  Branches:  ${branchIdMap.size}`);
    console.log(`  Accounts:  ${accountIdMap.size}`);
    console.log(`  Transfers: ${transferIdMap.size}`);
    console.log(`  Clients:   ${clientIdMap.size}`);
    console.log(`  Purchases: ${purchaseIdMap.size}`);
    console.log('\nIMPORTANT: Users have temporary passwords.');
    console.log('They should use "Forgot Password" to set new passwords.');

  } catch (err) {
    console.error('\n FATAL ERROR:', err);
    process.exit(1);
  }

  process.exit(0);
}

main();
