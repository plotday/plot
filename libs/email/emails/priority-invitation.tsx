import { Heading, Text } from "@react-email/components";

import EmailButton from "./components/email-button";
import EmailLayout from "./components/email-layout";

interface PriorityInvitationProps {
  inviterName: string;
  priorityName: string;
  inviteUrl: string;
  recipientName?: string;
}

export default function PriorityInvitation({
  inviterName,
  inviteUrl,
  recipientName,
}: PriorityInvitationProps) {
  return (
    <EmailLayout preview={`Join to make progress together`}>
      <Heading style={h1}>You've been invited to Plot!</Heading>
      {recipientName && <Text style={text}>Hi {recipientName},</Text>}
      <Text style={text}>
        <strong>{inviterName}</strong> has invited you to collaborate on Plot,
        where you can share plans and take action.
      </Text>
      <Text style={text}>
        Plot is completely free to use, and getting started only takes a moment.
      </Text>
      <EmailButton href={inviteUrl}>Accept Invitation</EmailButton>
      <Text style={hint}>
        If you weren't expecting this invitation, you can safely ignore this
        email.
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
  margin: "0 0 16px",
};

const hint = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "24px 0 0",
};
