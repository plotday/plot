import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function PasswordReset() {
  return (
    <EmailLayout preview="Reset your Plot password">
      <Heading style={h1}>Reset your password</Heading>
      <Text style={text}>
        We received a request to reset your password for your Plot account.
        Enter this code in the app to create a new password:
      </Text>
      <Text style={otpCode}>{"{{ .Token }}"}</Text>
      <Text style={hint}>
        This code will expire in one hour for your security.
      </Text>
      <Text style={hint}>
        If you didn't request a password reset, you can safely ignore this
        email. Your password will remain unchanged. If you're concerned about
        your account security, contact us at team@plot.day
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
