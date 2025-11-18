import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function EmailConfirmation() {
  return (
    <EmailLayout preview="Confirm your email address for Plot">
      <Heading style={h1}>Welcome to Plot!</Heading>
      <Text style={text}>
        Please confirm your email address by entering the code below in the app:
      </Text>
      <Text style={otpCode}>{"{{ .Token }}"}</Text>
      <Text style={hint}>
        If you didn't create a Plot account, you can safely ignore this email.
        This code will expire in one hour for security your security.
      </Text>
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
