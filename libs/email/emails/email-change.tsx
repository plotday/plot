import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function EmailChange({ code }: { code: string }) {
  return (
    <EmailLayout preview="Confirm your new email address">
      <Heading style={h1}>Confirm email change</Heading>
      <Text style={text}>
        You recently requested to change the email address for your Plot
        account. Enter this code in the app to confirm this change:
      </Text>
      <Text style={otpCode}>{code}</Text>
      <Text style={hint}>
        This code will expire in one hour for your security.
      </Text>
      <Text style={hint}>
        If you didn't request this change, please ignore this email and your
        email address will remain unchanged. If you're concerned about your
        account security, contact us at team@plot.day
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

const otpCode = {
  color: "#1f2937",
  fontSize: "32px",
  fontWeight: "700",
  letterSpacing: "0.25em",
  lineHeight: "40px",
  margin: "0 0 24px",
  textAlign: "center" as const,
  fontFamily: "monospace",
};

const hint = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "24px 0 0",
};
