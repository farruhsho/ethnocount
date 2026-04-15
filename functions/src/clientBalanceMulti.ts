import * as admin from 'firebase-admin';
import type { DocumentData } from 'firebase-admin/firestore';

export const strictRound = (num: number, decimals: number = 2): number =>
    Number(Math.round(Number(num + 'e' + decimals)) + 'e-' + decimals);

/** Read per-currency balances from clientBalances doc (multi-currency or legacy). */
export function readBalancesMap(
    balanceData: DocumentData | undefined,
    clientCurrency: string,
): Record<string, number> {
    const raw = balanceData?.balances;
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
        const out: Record<string, number> = {};
        for (const [k, v] of Object.entries(raw)) {
            if (typeof v === 'number' && !Number.isNaN(v)) {
                out[k] = strictRound(v);
            }
        }
        if (Object.keys(out).length > 0) {
            return out;
        }
    }
    const cur = (balanceData?.currency as string) || clientCurrency || 'USD';
    const b = strictRound(balanceData?.balance || 0);
    return { [cur]: b };
}

export function primaryMirrorBalance(
    balances: Record<string, number>,
    clientCurrency: string,
): number {
    return strictRound(balances[clientCurrency] ?? 0);
}

export function setClientBalanceWrite(
    clientId: string,
    clientCurrency: string,
    balances: Record<string, number>,
): Record<string, unknown> {
    return {
        clientId,
        balances,
        balance: primaryMirrorBalance(balances, clientCurrency),
        currency: clientCurrency,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };
}
