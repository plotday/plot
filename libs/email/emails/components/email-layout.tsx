import React, { type ReactNode } from "react";

import {
  Body,
  Container,
  Head,
  Html,
  Img,
  Preview,
  Section,
  Text,
} from "@react-email/components";

interface EmailLayoutProps {
  preview: string;
  children: ReactNode;
}

export default function EmailLayout({ preview, children }: EmailLayoutProps) {
  return (
    <Html>
      <Head />
      <Preview>{preview}</Preview>
      <Body style={main}>
        <Container style={container}>
          <Section style={header}>
            <Img
              src="https://plot.day/assets/p.png"
              alt="Plot"
              width="32"
              height="32"
              style={logo}
            />
          </Section>
          <Section style={content}>{children}</Section>
          <Section style={footer}>
            <Text style={footerText}>
              © 2025{" "}
              <a href="https://plot.day" style={footerText}>
                Plot
              </a>
            </Text>
          </Section>
        </Container>
      </Body>
    </Html>
  );
}

const main = {
  backgroundColor: "#ffffff",
  fontFamily:
    '-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Ubuntu,sans-serif',
};

const container = {
  backgroundColor: "#ffffff",
  margin: "0 auto",
  padding: "20px 0 48px",
  maxWidth: "600px",
};

const header = {
  padding: "12px 0",
  margin: "0 0 24px 0",
  textAlign: "center" as const,
  backgroundColor: "#23986f",
};

const logo = {
  margin: "0 auto",
};

const content = {
  padding: "0 48px",
};

const footer = {
  padding: "32px 48px",
  borderTop: "1px solid #f0f0f0",
  marginTop: "32px",
};

const footerText = {
  color: "#9ca3af",
  fontSize: "12px",
  lineHeight: "16px",
  margin: "4px 0",
  textAlign: "center" as const,
};
