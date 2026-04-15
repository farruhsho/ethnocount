"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.updateUser = exports.createUser = void 0;
const https_1 = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
exports.createUser = (0, https_1.onCall)(async (request) => {
    var _a;
    const { data, auth } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    // Only creator can manage users
    const callerDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!callerDoc.exists || ((_a = callerDoc.data()) === null || _a === void 0 ? void 0 : _a.role) !== 'creator') {
        throw new https_1.HttpsError('permission-denied', 'Only Creator can manage users.');
    }
    const { email, password, displayName, role, assignedBranchIds } = data;
    if (!email || !password || !displayName || !role) {
        throw new https_1.HttpsError('invalid-argument', 'email, password, displayName and role are required.');
    }
    const allowedRoles = ['accountant', 'admin', 'creator'];
    if (!allowedRoles.includes(role)) {
        throw new https_1.HttpsError('invalid-argument', `Role must be one of: ${allowedRoles.join(', ')}.`);
    }
    try {
        // Create Firebase Auth user
        const userRecord = await admin.auth().createUser({
            email: email.trim(),
            password,
            displayName: displayName.trim(),
            emailVerified: false,
        });
        // Create Firestore profile
        await admin.firestore().collection('users').doc(userRecord.uid).set({
            displayName: displayName.trim(),
            email: email.trim().toLowerCase(),
            role,
            assignedBranchIds: assignedBranchIds || [],
            isActive: true,
            createdBy: auth.uid,
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        // Audit log
        await admin.firestore().collection('auditLogs').add({
            action: 'create_user',
            entityType: 'user',
            entityId: userRecord.uid,
            performedBy: auth.uid,
            details: { email, displayName, role },
            createdAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        return { success: true, userId: userRecord.uid };
    }
    catch (error) {
        if (error instanceof https_1.HttpsError)
            throw error;
        throw new https_1.HttpsError('internal', error.message || 'Error creating user');
    }
});
exports.updateUser = (0, https_1.onCall)(async (request) => {
    var _a;
    const { data, auth } = request;
    if (!auth)
        throw new https_1.HttpsError('unauthenticated', 'User must be authenticated.');
    const callerDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!callerDoc.exists || ((_a = callerDoc.data()) === null || _a === void 0 ? void 0 : _a.role) !== 'creator') {
        throw new https_1.HttpsError('permission-denied', 'Only Creator can manage users.');
    }
    const { userId, role, assignedBranchIds, isActive, displayName } = data;
    if (!userId)
        throw new https_1.HttpsError('invalid-argument', 'userId is required.');
    const updates = {};
    if (role !== undefined)
        updates.role = role;
    if (assignedBranchIds !== undefined)
        updates.assignedBranchIds = assignedBranchIds;
    if (isActive !== undefined)
        updates.isActive = isActive;
    if (displayName !== undefined)
        updates.displayName = displayName.trim();
    await admin.firestore().collection('users').doc(userId).update(updates);
    if (isActive === false) {
        await admin.auth().updateUser(userId, { disabled: true });
    }
    else if (isActive === true) {
        await admin.auth().updateUser(userId, { disabled: false });
    }
    await admin.firestore().collection('auditLogs').add({
        action: 'update_user',
        entityType: 'user',
        entityId: userId,
        performedBy: auth.uid,
        details: updates,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return { success: true };
});
//# sourceMappingURL=createUser.js.map