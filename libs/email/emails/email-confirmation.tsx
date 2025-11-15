import React from "react";
import { Heading, Hr, Text } from "@react-email/components";
import EmailButton from "./components/email-button";
import EmailLayout from "./components/email-layout";

export default function EmailConfirmation() {
  return (
    <EmailLayout preview="Confirm your email address for Plot">
      <Heading style={h1}>Confirm your email</Heading>
      <Text style={text}>
        Welcome to Plot! Please confirm your email address to get started.
      </Text>
      <EmailButton href="{{ .ConfirmationURL }}">
        Confirm email address
      </EmailButton>
      <Hr style={divider} />
      <Text style={otpLabel}>Or enter this code in the app:</Text>
      <Text style={otpCode}>{"{{ .Token }}"}</Text>
      <Text style={hint}>
        If you didn't create a Plot account, you can safely ignore this email.
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

const divider = {
  borderColor: "#e5e7eb",
  margin: "32px 0 24px",
};

const otpLabel = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "0 0 12px",
  textAlign: "center" as const,
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
