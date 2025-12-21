import { Heading, Text } from "@react-email/components";

import EmailLayout from "./components/email-layout";

export default function WaitlistWelcome() {
  return (
    <EmailLayout preview="Welcome to the Plot waitlist">
      <Heading style={h1}>Welcome to the waitlist!</Heading>
      <Text style={text}>
        Thanks for your interest in Plot! We're excited to have you on the
        list.
      </Text>
      <Text style={text}>
        We're onboarding new users regularly and will send you an invitation as
        soon as a spot opens up.
      </Text>
      <Text style={text}>In the meantime, you can:</Text>
      <Text style={listItem}>• Follow us for updates at plot.day</Text>
      <Text style={listItem}>
        • Learn more about what Plot can do for you
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
  margin: "0 0 16px",
};

const listItem = {
  color: "#374151",
  fontSize: "16px",
  lineHeight: "24px",
  margin: "0 0 8px",
};

const hint = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "24px 0 0",
};
