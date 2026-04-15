"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.revokeAllSessions = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
/**
 * Revokes all refresh tokens for the current user.
 * After calling this, all devices (including the current one) will need to sign in again
 * when their ID token expires (typically within 1 hour).
 */
exports.revokeAllSessions = (0, https_1.onCall)(async (request) => {
    const { auth } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    try {
        await admin.auth().revokeRefreshTokens(auth.uid);
        return { success: true };
    }
    catch (error) {
        throw new https_1.HttpsError('internal', error.message || 'Failed to revoke sessions');
    }
});
//# sourceMappingURL=revokeAllSessions.js.map