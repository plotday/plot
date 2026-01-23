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
  priorityName,
  inviteUrl,
  recipientName,
}: PriorityInvitationProps) {
  const greeting = recipientName ? `Hi ${recipientName},` : "Hi,";

  return (
    <EmailLayout preview={`${inviterName} invited you to collaborate on Plot`}>
      <Heading style={h1}>You're invited!</Heading>
      <Text style={text}>{greeting}</Text>
      <Text style={text}>
        <strong>{inviterName}</strong> has invited you to collaborate on{" "}
        <strong>{priorityName}</strong> in Plot.
      </Text>
      <Text style={text}>
        Plot helps teams stay focused on what matters most. Accept this
        invitation to start collaborating.
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
