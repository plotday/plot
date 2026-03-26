import React from "react";
import { Text, Link } from "@react-email/components";

import EmailButton from "./components/email-button";
import EmailLayout from "./components/email-layout";

interface NotificationDigestProps {
  recipientName: string | null;
  priorities: Array<{
    title: string;
    summary: string;
    url: string;
  }>;
  appUrl: string;
}

export default function NotificationDigest({
  recipientName,
  priorities,
  appUrl,
}: NotificationDigestProps) {
  return (
    <EmailLayout preview="New activity in Plot">
      {recipientName && <Text style={text}>Hi {recipientName},</Text>}
      <Text style={text}>Here's what's happening in Plot.</Text>
      {priorities.map((priority, i) => (
        <React.Fragment key={i}>
          <Text style={priorityTitle}>{priority.title}</Text>
          <Text style={summaryText}>
            {priority.summary}{" "}
            <Link href={priority.url} style={jumpInLink}>
              Jump in &rarr;
            </Link>
          </Text>
        </React.Fragment>
      ))}
      <EmailButton href={appUrl}>Open Plot</EmailButton>
      <Text style={hint}>
        You're receiving this because you have unread notifications in Plot.
      </Text>
    </EmailLayout>
  );
}

const text = {
  color: "#374151",
  fontSize: "16px",
  lineHeight: "24px",
  margin: "0 0 16px",
};

const priorityTitle = {
  color: "#1f2937",
  fontSize: "16px",
  fontWeight: "600",
  lineHeight: "24px",
  margin: "16px 0 4px",
};

const summaryText = {
  color: "#4b5563",
  fontSize: "15px",
  lineHeight: "22px",
  margin: "0 0 12px",
};

const jumpInLink = {
  color: "#23986f",
  textDecoration: "none",
  fontWeight: "500",
};

const hint = {
  color: "#6b7280",
  fontSize: "14px",
  lineHeight: "20px",
  margin: "24px 0 0",
};
