import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

/**
 * Revokes all refresh tokens for the current user.
 * After calling this, all devices (including the current one) will need to sign in again
 * when their ID token expires (typically within 1 hour).
 */
export const revokeAllSessions = onCall(async (request) => {
    const { auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    try {
        await admin.auth().revokeRefreshTokens(auth.uid);
        return { success: true };
    } catch (error: any) {
        throw new HttpsError('internal', error.message || 'Failed to revoke sessions');
    }
});
