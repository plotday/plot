import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function NewDeviceSignIn() {
  return (
    <EmailLayout preview="New sign-in to your Plot account">
      <Heading style={h1}>New sign-in detected</Heading>
      <Text style={text}>
        We noticed a sign-in to your Plot account from a new or unrecognized
        device. If this was you, no action is needed.
      </Text>
      <Text style={hint}>
        If you didn't sign in recently, your account may be compromised. Please
        change your password immediately and contact us at team@plot.day
      </Text>
      <Text style={hint}>Questions? Contact us at team@plot.day.</Text>
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
