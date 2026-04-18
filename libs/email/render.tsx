import { render as reactEmailRender } from "@react-email/render";

import AccountLocked from "./emails/account-locked";
import EmailChange from "./emails/email-change";
import EmailConfirmation from "./emails/email-confirmation";
import NewDeviceSignIn from "./emails/new-device-sign-in";
import PasswordChanged from "./emails/password-changed";
import PasswordRemoved from "./emails/password-removed";
import PasswordReset from "./emails/password-reset";
import PriorityInvitation from "./emails/priority-invitation";
import ThreadInvitation from "./emails/thread-invitation";
import LinkEmail from "./emails/link-email";
import NotificationDigest from "./emails/notification-digest";
import SignInVerification from "./emails/sign-in-verification";

export type EmailType =
  | "priority-invitation"
  | "thread-invitation"
  | "email-confirmation"
  | "password-reset"
  | "email-change"
  | "account-locked"
  | "password-changed"
  | "password-removed"
  | "new-device-sign-in"
  | "sign-in-verification"
  | "link-email"
  | "notification-digest";

interface PriorityInvitationProps {
  inviterName: string;
  priorityName: string;
  inviteUrl: string;
  recipientName?: string;
}

interface ThreadInvitationProps {
  inviterName: string;
  threadTitle: string;
  inviteUrl: string;
  recipientName?: string;
}

interface AuthCodeProps {
  code: string;
}

type EmailProps = {
  "priority-invitation": PriorityInvitationProps;
  "thread-invitation": ThreadInvitationProps;
  "email-confirmation": AuthCodeProps;
  "password-reset": AuthCodeProps;
  "email-change": AuthCodeProps;
  "account-locked": undefined;
  "password-changed": undefined;
  "password-removed": undefined;
  "new-device-sign-in": undefined;
  "sign-in-verification": AuthCodeProps;
  "link-email": AuthCodeProps;
  "notification-digest": NotificationDigestProps;
};

interface NotificationDigestProps {
  recipientName: string | null;
  priorities: Array<{
    title: string;
    summary: string;
    url: string;
  }>;
  appUrl: string;
  unsubscribeUrl: string;
}

export const render = async <T extends EmailType>(
  type: T,
  ...args: EmailProps[T] extends undefined ? [] : [EmailProps[T]]
) => {
  const props = args[0];
  let Component;
  switch (type) {
    case "priority-invitation":
      Component = PriorityInvitation;
      break;
    case "thread-invitation":
      Component = ThreadInvitation;
      break;
    case "email-confirmation":
      Component = EmailConfirmation;
      break;
    case "password-reset":
      Component = PasswordReset;
      break;
    case "email-change":
      Component = EmailChange;
      break;
    case "account-locked":
      Component = AccountLocked;
      break;
    case "password-changed":
      Component = PasswordChanged;
      break;
    case "password-removed":
      Component = PasswordRemoved;
      break;
    case "new-device-sign-in":
      Component = NewDeviceSignIn;
      break;
    case "sign-in-verification":
      Component = SignInVerification;
      break;
    case "link-email":
      Component = LinkEmail;
      break;
    case "notification-digest":
      Component = NotificationDigest;
      break;
    default:
      throw new Error(`Unknown email type: ${type}`);
  }
  return {
    html: await reactEmailRender(<Component {...(props as any)} />, {
      pretty: true,
    }),
    text: await reactEmailRender(<Component {...(props as any)} />, {
      plainText: true,
    }),
  };
};
