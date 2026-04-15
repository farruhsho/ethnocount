"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.onNotificationCreated = void 0;
const functions = require("firebase-functions");
const admin = require("firebase-admin");
/**
 * When a notification document is created, send FCM push to users
 * subscribed to the target branch topic.
 */
exports.onNotificationCreated = functions.firestore
    .document('notifications/{notificationId}')
    .onCreate(async (snap) => {
    const data = snap.data();
    const targetBranchId = data === null || data === void 0 ? void 0 : data.targetBranchId;
    const title = (data === null || data === void 0 ? void 0 : data.title) || 'Уведомление';
    const body = (data === null || data === void 0 ? void 0 : data.body) || '';
    const type = data === null || data === void 0 ? void 0 : data.type;
    const payload = (data === null || data === void 0 ? void 0 : data.data) || {};
    if (!targetBranchId)
        return;
    const topic = `branch_${targetBranchId}`;
    const dataPayload = {
        type: type || '',
        transferId: String((payload === null || payload === void 0 ? void 0 : payload.transferId) || ''),
    };
    for (const [k, v] of Object.entries(payload)) {
        if (typeof v === 'string')
            dataPayload[k] = v;
    }
    const message = {
        topic,
        notification: {
            title,
            body,
        },
        data: dataPayload,
        android: {
            priority: 'high',
            notification: {
                sound: 'default',
                defaultVibrateTimings: true,
            },
        },
        apns: {
            payload: {
                aps: {
                    sound: 'default',
                    contentAvailable: true,
                },
            },
            fcmOptions: {},
        },
    };
    try {
        await admin.messaging().send(message);
        functions.logger.info(`FCM sent to topic ${topic}: ${title}`);
    }
    catch (e) {
        functions.logger.error('FCM send error:', e);
    }
});
//# sourceMappingURL=onNotificationCreated.js.map