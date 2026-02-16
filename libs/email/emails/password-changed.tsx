import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function PasswordChanged() {
  return (
    <EmailLayout preview="Your Plot password has been changed">
      <Heading style={h1}>Your password has been changed</Heading>
      <Text style={text}>
        The password for your Plot account was recently changed. If you made this
        change, no further action is needed.
      </Text>
      <Text style={hint}>
        If you didn't change your password, please reset it immediately and
        contact us at team@plot.day
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
