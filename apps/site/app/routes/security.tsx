import { Container, Title, TypographyStylesProvider } from "@mantine/core";

export default function Security() {
  return (
    <Container mt="lg">
      <Title order={1} mb="lg">
        Data &amp; Security
      </Title>
      <p>
        <em>Last updated: June 10, 2026</em>
      </p>
      <TypographyStylesProvider p={0}>
        <p>
          Plot connects to the tools where your work happens — your email,
          your calendar, your team chat. That means we hold data worth
          protecting, and we treat that as part of the product. This page
          explains where your data lives, who can see it, and how we keep it
          safe.
        </p>

        <h2 id="where-your-data-lives">Where your data lives</h2>
        <p>
          Plot is local-first. The app keeps a copy of your data on your
          device, so it works offline and stays fast. That copy is protected
          by your device&apos;s own storage encryption.
        </p>
        <p>
          Your data syncs to our servers for backup, for your other devices,
          and for sharing with the people you choose. Our database runs on
          Google Cloud in Toronto, Canada, and is backed up automatically
          every day. Our API runs on Cloudflare&apos;s network.
        </p>

        <h2 id="encryption">Encryption</h2>
        <p>
          Everything moving between your device and our servers is encrypted
          in transit with TLS. Everything stored on our servers is encrypted
          at rest by our infrastructure providers.
        </p>
        <p>
          The most sensitive pieces — the tokens that link your connected
          accounts, and any AI keys you bring — are encrypted a second time
          at the application level with AES-256, using keys we manage.
        </p>

        <h2 id="your-connected-accounts">Your connected accounts</h2>
        <p>
          Connections use OAuth: you sign in with the provider directly, and
          Plot receives a scoped token — never your password. Each connection
          asks only for the access its features need, and you can disconnect
          at any time. Disconnecting removes the stored tokens.
        </p>
        <p>
          Connectors run inside a sandboxed runtime with access only to the
          capabilities they declare.
        </p>
        <p>
          Plot&apos;s use of information received from Google Workspace APIs
          adheres to the{" "}
          <a href="https://developers.google.com/terms/api-services-user-data-policy">
            Google User Data Policy
          </a>
          , including the Limited Use requirements. Because Plot can access
          Gmail, we also pass an annual independent security assessment
          (CASA) that Google requires for that access.
        </p>

        <h2 id="ai">AI</h2>
        <p>
          AI in Plot does things you can see — summarize a thread, suggest
          where something belongs. We send only what a feature needs to our
          AI providers (Anthropic, Google, and OpenAI), under agreements that
          prohibit them from training on your data or keeping it beyond the
          response. We never use your data to train models either. You can
          turn off AI processing entirely in your account settings.
        </p>

        <h2 id="who-can-see-your-work">Who can see your work</h2>
        <p>
          Your threads are visible to you and the people you&apos;ve shared
          them with — directly, through a group, or through your team. Drafts
          stay private until you send them. These rules are enforced in the
          database itself, on every query, not just in the app.
        </p>
        <p>
          People at Plot don&apos;t read your data. The narrow exceptions —
          debugging with your consent, investigating abuse, legal
          requirements — are spelled out in our{" "}
          <a href="/privacy">privacy policy</a>.
        </p>

        <h2 id="deleting-your-data">Deleting your data</h2>
        <p>
          You can delete your account from the app at any time. We hold your
          data for 14 days in case you change your mind, then everything is
          erased automatically and permanently — your content, your
          connection tokens, and your files.
        </p>

        <h2 id="payments">Payments</h2>
        <p>
          Payments are handled by Stripe. Your card details go to Stripe
          directly and never touch our servers.
        </p>

        <h2 id="services-we-rely-on">The services we rely on</h2>
        <p>Plot runs on a small set of providers, each doing one job:</p>
        <ul>
          <li>
            <strong>Cloudflare</strong> — API hosting, networking, and file
            storage
          </li>
          <li>
            <strong>Google Cloud</strong> — database hosting (Toronto,
            Canada)
          </li>
          <li>
            <strong>Clerk</strong> — sign-in and authentication
          </li>
          <li>
            <strong>Stripe</strong> — payments
          </li>
          <li>
            <strong>Anthropic, Google, and OpenAI</strong> — AI features
            (optional; never used for training)
          </li>
          <li>
            <strong>Unipile</strong> — powers the LinkedIn, WhatsApp, and
            Instagram connections
          </li>
          <li>
            <strong>PostHog</strong> — product analytics and error tracking
          </li>
          <li>
            <strong>Resend</strong> — email notifications
          </li>
          <li>
            <strong>Firebase and Apple Push</strong> — notifications to your
            devices
          </li>
        </ul>
        <p>
          That&apos;s the full list. We don&apos;t sell your data, and we
          don&apos;t show ads.
        </p>

        <h2 id="report-a-security-issue">If you find a security issue</h2>
        <p>
          Email <a href="mailto:security@plot.day">security@plot.day</a> — it
          reaches us directly, and we respond quickly. We also publish{" "}
          <a href="/.well-known/security.txt">security.txt</a> for automated
          discovery.
        </p>

        <h2 id="where-we-are">Where we are</h2>
        <p>
          We&apos;re a small team, and we don&apos;t have a SOC 2 report yet.
          What we do have: the controls on this page, an independent security
          assessment every year, and an architecture that keeps your data on
          your device first. If you&apos;re evaluating Plot for your business
          and need more than this page, write to{" "}
          <a href="mailto:security@plot.day">security@plot.day</a> — a person
          will answer.
        </p>
      </TypographyStylesProvider>
    </Container>
  );
}
