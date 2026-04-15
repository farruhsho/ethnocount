import { onCall, HttpsError } from 'firebase-functions/v2/https';
import * as admin from 'firebase-admin';

export const createUser = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    // Only creator can manage users
    const callerDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!callerDoc.exists || callerDoc.data()?.role !== 'creator') {
        throw new HttpsError('permission-denied', 'Only Creator can manage users.');
    }

    const { email, password, displayName, role, assignedBranchIds } = data;

    if (!email || !password || !displayName || !role) {
        throw new HttpsError('invalid-argument', 'email, password, displayName and role are required.');
    }

    const allowedRoles = ['accountant', 'admin', 'creator'];
    if (!allowedRoles.includes(role)) {
        throw new HttpsError('invalid-argument', `Role must be one of: ${allowedRoles.join(', ')}.`);
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
    } catch (error: any) {
        if (error instanceof HttpsError) throw error;
        throw new HttpsError('internal', error.message || 'Error creating user');
    }
});

export const updateUser = onCall(async (request) => {
    const { data, auth } = request;

    if (!auth) throw new HttpsError('unauthenticated', 'User must be authenticated.');

    const callerDoc = await admin.firestore().collection('users').doc(auth.uid).get();
    if (!callerDoc.exists || callerDoc.data()?.role !== 'creator') {
        throw new HttpsError('permission-denied', 'Only Creator can manage users.');
    }

    const { userId, role, assignedBranchIds, isActive, displayName } = data;

    if (!userId) throw new HttpsError('invalid-argument', 'userId is required.');

    const updates: Record<string, any> = {};
    if (role !== undefined) updates.role = role;
    if (assignedBranchIds !== undefined) updates.assignedBranchIds = assignedBranchIds;
    if (isActive !== undefined) updates.isActive = isActive;
    if (displayName !== undefined) updates.displayName = displayName.trim();

    await admin.firestore().collection('users').doc(userId).update(updates);

    if (isActive === false) {
        await admin.auth().updateUser(userId, { disabled: true });
    } else if (isActive === true) {
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
