import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

/**
 * When a notification document is created, send FCM push to users
 * subscribed to the target branch topic.
 */
export const onNotificationCreated = functions.firestore
  .document('notifications/{notificationId}')
  .onCreate(async (snap) => {
    const data = snap.data();
    const targetBranchId = data?.targetBranchId as string | undefined;
    const targetUserId = data?.targetUserId as string | undefined;
    const title = (data?.title as string) || 'Уведомление';
    const body = (data?.body as string) || '';
    const type = data?.type as string | undefined;
    const payload = (data?.data as Record<string, unknown>) || {};

    const topic = targetUserId
        ? `user_${targetUserId}`
        : targetBranchId
            ? `branch_${targetBranchId}`
            : undefined;

    if (!topic) return;

    const dataPayload: Record<string, string> = {
      type: type || '',
      transferId: String(payload?.transferId || ''),
    };
    for (const [k, v] of Object.entries(payload)) {
      if (typeof v === 'string') dataPayload[k] = v;
    }

    const message: admin.messaging.Message = {
      topic,
      notification: {
        title,
        body,
      },
      data: dataPayload,
      android: {
        priority: 'high' as const,
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
    } catch (e) {
      functions.logger.error('FCM send error:', e);
    }
  });
