import { render as reactEmailRender } from "@react-email/render";

import WaitlistWelcome from "./emails/waitlist-welcome";

export type EmailType = "waitlist-welcome";

export const render = (type: EmailType, props?: Record<string, unknown>) => {
  let Component;
  switch (type) {
    case "waitlist-welcome":
      Component = WaitlistWelcome;
      break;
    default:
      throw new Error(`Unknown email type: ${type}`);
  }
  return {
    html: reactEmailRender(<Component {...props} />, {
      pretty: true,
    }),
    text: reactEmailRender(<Component {...props} />, {
      plainText: true,
    }),
  };
};
