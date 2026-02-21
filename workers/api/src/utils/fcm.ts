/**
 * Firebase Cloud Messaging (FCM) HTTP v1 API client.
 * Sends push notifications to individual device tokens.
 */

import { getGcpAccessToken } from "./gcp-auth";

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";

export type NotificationPayload = {
  title: string;
  body: string;
  data?: Record<string, string>;
};

interface FcmConfig {
  projectId: string;
  serviceAccountEmail: string;
  serviceAccountKey: string;
}

/**
 * Sends a push notification to a single device via FCM HTTP v1 API.
 *
 * @returns success: true if sent, false if the token is invalid/unregistered.
 */
export async function sendPushNotification(
  config: FcmConfig,
  deviceToken: string,
  notification: NotificationPayload
): Promise<{ success: boolean; error?: string; unregistered?: boolean }> {
  const accessToken = await getGcpAccessToken(
    config.serviceAccountEmail,
    config.serviceAccountKey,
    FCM_SCOPE
  );

  const url = `https://fcm.googleapis.com/v1/projects/${config.projectId}/messages:send`;

  const message: Record<string, unknown> = {
    token: deviceToken,
    notification: {
      title: notification.title,
      body: notification.body,
    },
  };

  if (notification.data) {
    message.data = notification.data;
  }

  const response = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ message }),
  });

  if (response.ok) {
    return { success: true };
  }

  const errorBody = await response.text();

  // Handle invalid/unregistered tokens (stale devices)
  if (
    response.status === 404 ||
    errorBody.includes("UNREGISTERED") ||
    errorBody.includes("NOT_FOUND")
  ) {
    return {
      success: false,
      error: "Token is unregistered or invalid",
      unregistered: true,
    };
  }

  return { success: false, error: errorBody };
}
