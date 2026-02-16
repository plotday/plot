import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function AccountLocked() {
  return (
    <EmailLayout preview="Your Plot account has been locked">
      <Heading style={h1}>Your account has been locked</Heading>
      <Text style={text}>
        Your Plot account has been temporarily locked due to multiple failed
        sign-in attempts. This is a security precaution to protect your account.
      </Text>
      <Text style={text}>
        If this was you, please wait a few minutes before trying again. If you
        need immediate help, contact us at team@plot.day
      </Text>
      <Text style={hint}>
        If you didn't attempt to sign in, someone may be trying to access your
        account. We recommend changing your password as soon as possible.
      </Text>
      <Text style={hint}>Questions? Contact us at team@plot.day</Text>
    </EmailLayout>
  );
}

const h1 = {
  color: "#1f2937",
  fontSize: "24px",
  fontWeight: "700",
  lineHeight: "32px",
  margin: "0 0 16px",
};

const text = {
  color: "#374151",
  fontSize: "16px",
  lineHeight: "24px",
  margin: "0 0 24px",
};

const hint = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "24px 0 0",
};
