import { render as reactEmailRender } from "@react-email/render";

import PriorityInvitation from "./emails/priority-invitation";
import WaitlistWelcome from "./emails/waitlist-welcome";

export type EmailType = "waitlist-welcome" | "priority-invitation";

interface PriorityInvitationProps {
  inviterName: string;
  priorityName: string;
  inviteUrl: string;
  recipientName?: string;
}

type EmailProps = {
  "waitlist-welcome": undefined;
  "priority-invitation": PriorityInvitationProps;
};

export const render = async <T extends EmailType>(
  type: T,
  ...args: EmailProps[T] extends undefined ? [] : [EmailProps[T]]
) => {
  const props = args[0];
  let Component;
  switch (type) {
    case "waitlist-welcome":
      Component = WaitlistWelcome;
      break;
    case "priority-invitation":
      Component = PriorityInvitation;
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
