import { render as reactEmailRender } from "@react-email/render";

import AccountLocked from "./emails/account-locked";
import EmailChange from "./emails/email-change";
import EmailConfirmation from "./emails/email-confirmation";
import NewDeviceSignIn from "./emails/new-device-sign-in";
import PasswordChanged from "./emails/password-changed";
import PasswordRemoved from "./emails/password-removed";
import PasswordReset from "./emails/password-reset";
import PriorityInvitation from "./emails/priority-invitation";
import SignInVerification from "./emails/sign-in-verification";

export type EmailType =
  | "priority-invitation"
  | "email-confirmation"
  | "password-reset"
  | "email-change"
  | "account-locked"
  | "password-changed"
  | "password-removed"
  | "new-device-sign-in"
  | "sign-in-verification";

interface PriorityInvitationProps {
  inviterName: string;
  priorityName: string;
  inviteUrl: string;
  recipientName?: string;
}

interface AuthCodeProps {
  code: string;
}

type EmailProps = {
  "priority-invitation": PriorityInvitationProps;
  "email-confirmation": AuthCodeProps;
  "password-reset": AuthCodeProps;
  "email-change": AuthCodeProps;
  "account-locked": undefined;
  "password-changed": undefined;
  "password-removed": undefined;
  "new-device-sign-in": undefined;
  "sign-in-verification": AuthCodeProps;
};

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
