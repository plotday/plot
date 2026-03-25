import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function LinkEmail({ code }: { code: string }) {
  return (
    <EmailLayout preview="Link this email to your Plot account">
      <Heading style={h1}>Link this email to your Plot account</Heading>
      <Text style={text}>
        Enter this code in Plot to link this email address to your account:
      </Text>
      <Text style={otpCode}>{code}</Text>
      <Text style={hint}>This code expires in 10 minutes.</Text>
      <Text style={hint}>
        If you didn't request this, you can safely ignore this email.
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
