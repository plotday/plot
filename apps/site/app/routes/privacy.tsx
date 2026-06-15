import { Container, Title, TypographyStylesProvider } from "@mantine/core";

import { mergeMeta } from "~/lib/meta";

import type { Route } from "./+types/privacy";

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Privacy Policy | Plot" },
    {
      name: "description",
      content:
        "How Plot collects, uses, and protects the personal information of people and teams who use our website and products.",
    },
  ]);
}

export default function Privacy() {
  return (
    <Container mt="lg">
      <Title order={1} mb="lg">
        Privacy Policy
      </Title>
      <p><em>Last updated: April 23, 2026</em></p>
      <TypographyStylesProvider p={0}>
        <p>
          Our mission is to serve people and teams doing great things.
          Protecting the privacy of individuals and organizations is critical to
          that mission.
        </p>
        <p>
          This policy describes how Plot Technologies Inc. (&quot;Plot&quot;,
          &quot;the product&quot;, &quot;the service&quot;, our&quot;,
          &quot;us&quot; or &quot;we&quot;) respects and protects the privacy of
          those who access our website, plot.day, and other sites and products
          we own and operate (&quot;users&quot;).
        </p>
        <h2 id="1-information-we-collect">1. Information we collect</h2>
        <h3 id="personal-information-you-provide-us-directly">
          Personal information you provide us directly
        </h3>
        <p>We may ask for personal information, such as your:</p>
        <ul>
          <li>Name</li>
          <li>Email</li>
          <li>Company and role</li>
          <li>Payment information</li>
        </ul>
        <h3 id="content-you-add">Content you add</h3>
        <p>
          You may add content to Plot. Most content you add is private to you.
          However, Priorities (containers for your threads)
          can be shared with other users. All content within a shared Priority
          is visible to its members, unless you mark specific items as private.
          Private items within a shared Priority are only visible to you.
        </p>
        <h3 id="extensions-and-integrations">
          Extensions, Connections, and integrations
        </h3>
        <p>
          You may optionally install extensions called Twists to extend Plot's
          functionality, and create Connections to sync data from third-party
          services. Twists can be provided by Plot, created by yourself, or
          published by other users. Connections link Plot to a specific account
          on a third-party service (such as Google Calendar or a project
          management tool) and sync data on an ongoing basis.
        </p>
        <p>
          When you install a Twist, you explicitly grant it permission to
          operate. Twists may access the following categories of your data
          within Plot: activities, notes, priorities, and user profile
          information. Third-party Twists run in a sandboxed environment with
          access only to the tools and permissions they request.
        </p>
        <p>
          When you create a Connection, you authorize Plot to access specific
          data from your third-party service account. Connections may receive
          data via webhooks and push notifications from connected services,
          meaning data may flow into Plot automatically without you actively
          triggering it. The data accessed depends on the specific Connection
          and the scopes you authorize.
        </p>
        <p>
          Plot stores OAuth authentication tokens for connected third-party
          services to maintain your Connections. You can revoke access at any
          time by removing the Connection in your account settings.
        </p>
        <p>
          You control which Twists you install and which Connections you
          create, and can remove them at any time. Only Twists and Connections
          you explicitly authorize have access to your data. We recommend
          reviewing what a Twist or Connection does and what permissions it
          requests before installing or authorizing it.
        </p>
        <h3 id="data-from-third-party-services-you-authorize">
          Data from third-party services you authorize
        </h3>
        <p>
          For product functionality, you may authorize Plot to read data from
          third-party services that manage relevant data such as your calendar
          events, contacts, tasks, and email. Plot stores copies of this
          information for processing and fast access.
        </p>
        <p>
          Connections you create may sync data on an ongoing basis via
          channels and webhooks. This means third-party services may push data
          updates to Plot automatically, without you actively triggering each
          sync.
        </p>
        <p>
          Additionally, Twists you install may connect to third-party services
          you authorize, reading and synchronizing data between those services
          and Plot. The data accessed depends on the specific Twist or
          Connection and the permissions you grant.
        </p>
        <h3 id="data-retention-for-connections">
          Data retention for Connections and Twists
        </h3>
        <p>
          When you remove a Connection or uninstall a Twist, Plot will stop
          syncing new data from the associated service. Previously synced data
          (such as calendar events, tasks, or contacts) will remain in your
          Plot account unless you explicitly delete it. You can delete
          individual items or request bulk deletion of synced data by
          contacting us.
        </p>
        <p>
          When you disconnect a third-party account that was used by a
          Connection, the Connection will stop functioning and no new data will
          be synced. OAuth tokens for the disconnected account will be deleted.
        </p>
        <h3 id="local-first-architecture">Local-first data storage</h3>
        <p>
          Plot uses a local-first architecture, meaning your data is stored
          on your device and synced to our cloud servers for backup,
          multi-device sync, and collaboration. This means your data is
          available to you even when you are offline. When an internet
          connection is available, your local data is synced with our servers
          to keep your devices in sync and enable collaboration with others.
        </p>
        <h3 id="ai-processing">Artificial intelligence processing</h3>
        <p>
          Plot may use artificial intelligence ("AI") and machine learning
          technologies to process your data for the purpose of organizing,
          prioritizing, and surfacing relevant information. When AI features
          are enabled, your data may be processed by third-party AI service
          providers who are bound by our data processing agreements.
        </p>
        <p>
          Some Twists may also use AI to provide their functionality. When a
          Twist uses AI, this is disclosed before installation. You can opt
          out of all AI processing via your account settings.
        </p>
        <h3 id="information-we-collect-automatically">
          Information we collect automatically
        </h3>
        <p>
          When you visit our website or use our product, we may automatically
          log the standard data provided by your web browser. That may include
          your computer’s Internet Protocol (IP) address, your browser type and
          version, the pages you visit, the time and date of your visit, the
          time spent on each page, and other details.
        </p>
        <p>
          We may also collect data about the device you’re using to access our
          website or product. This data may include the device type, operating
          system, unique device identifiers, device settings, and geo-location
          data. What we collect can depend on the individual settings of your
          device and software. We recommend checking the policies of your device
          manufacturer or software provider to learn what information they make
          available to us.
        </p>
        <h3 id="cookies-and-web-beacons">Cookies and web beacons</h3>
        <p>
          When you visit our website or use our product, we may send cookies to
          your device to uniquely identify you. You can control the cookies on
          your device, including resetting them and/or blocking them. Use of
          some product features may depend on cookies to operate.
        </p>
        <p>
          We may also add clear images called web beacons in HTML-based emails
          to detect when emails are successfully viewed.
        </p>
        <h2 id="2-how-we-use-your-information">
          2. How we use your information
        </h2>
        <p>
          We use the information we collect to build and operate Plot to best
          serve you and other users, according to these purposes:
        </p>
        <ul>
          <li>
            Providing you with our product: The primary use of any information
            we collect is to allow operation of the product you are using. This
            includes operating secure accounts, authentication and
            authorization, and content storage and retrieval.
          </li>
          <li>
            To understand product usage and improve the product: Information we
            collect automatically is primarily stored in an anonymized form
            without personally identifiable information. This information allows
            us to understand patterns in user behaviour so we can continually
            refine Plot to serve users better. Some of this information may also
            be associated with your account to support personalizations, such as
            tips and tricks offered based on your usage.
          </li>
          <li>
            Communicating with you about Plot: We use your contact information
            to send you relevant communications about the product, such as
            technical, security or administrative matters.
          </li>
          <li>
            Promoting engagement with Plot: We may also use information to send
            you communications to encourage usage of Plot and its features and
            benefits. You can opt-out of these communications as described
            below.
          </li>
          <li>
            Supporting users: Authorized employees of Plot, with your
            permission, may access your information as part of a consultation or
            to help you resolve an issue you are experiencing with the product.
          </li>
          <li>
            As required by law: Plot will use or disclose your information to
            legal authorities only as necessary to comply with the law, enforce
            our Terms of Use, or protect the security of our product.
          </li>
        </ul>
        <h3 id="sharing-your-information">Sharing your information</h3>
        <p>
          We may share your information with third-party service providers
          essential to the operation of the product. These service providers are
          only provided the information required to perform the services
          required. We carefully review the Privacy Policies and Terms of Service
          of our third-party service providers to ensure they reflect our
          commitments to you.
        </p>
        <p>Our third-party service providers include:</p>
        <ul>
          <li>Hosting, storage and data-processing</li>
          <li>Email delivery</li>
          <li>Analytics</li>
          <li>Billing</li>
          <li>AI and machine learning service providers</li>
        </ul>
        <h3 id="ways-we-do-not-use-your-information">
          Ways we <strong>do not</strong> use your information
        </h3>
        <p>
          Plot does not use any of your information for serving third-party
          advertisements. We will not sell your information to a third party.
        </p>
        <p>
          Plot's use and transfer to any other app of information received
          from Google APIs adheres to the{" "}
          <a href="https://developers.google.com/terms/api-services-user-data-policy#additional_requirements_for_specific_api_scopes">
            Google API Services User Data Policy
          </a>
          , including the Limited Use requirements. Specifically:
        </p>
        <ul>
          <li>
            Plot's use of information received from Google APIs is limited to
            providing or improving user-facing features of the Service that
            are prominent in the Service's user interface.
          </li>
          <li>
            Plot does not transfer information received from Google APIs to
            others except as necessary to provide or improve those user-facing
            features, to comply with applicable law, or as part of a merger,
            acquisition, or sale of assets with notice to users.
          </li>
          <li>
            Plot does not use information received from Google APIs for
            serving advertisements, including retargeted, personalized, or
            interest-based advertising.
          </li>
          <li>
            <strong>
              Plot does not use information received from Google APIs, or data
              derived from it, to develop, improve, or train generalized or
              non-personalized artificial intelligence or machine learning
              models.
            </strong>{" "}
            Where Plot uses AI to provide user-facing features on your Google
            data (such as summarizing a message or extracting tasks from an
            email), that processing is performed on your behalf by third-party
            AI providers who are contractually prohibited from retaining your
            data beyond what is necessary to return a response, and from using
            it to train their models.
          </li>
          <li>
            Plot does not allow humans to read your Google user data except
            (a) with your explicit consent for specific data, (b) as necessary
            for security purposes (such as investigating abuse), (c) to
            comply with applicable law, or (d) for internal operations where
            the data has been aggregated and anonymized.
          </li>
        </ul>
        <h2 id="3-protecting-your-information">
          3. Protecting your information
        </h2>
        <p>
          Plot takes the protection of your information very seriously, applying
          appropriate safeguards to preserve the security of the information we
          collect. To protect the privacy and security of information restricted
          to your account, we take reasonable measures to verify your identity
          before granting access to your account. You are responsible for
          maintaining the secrecy of any account passwords and controlling
          access to any associated accounts given access to your Plot account
          (e.g. your Google Account used for sign in).
        </p>
        <p>
          In the event that any information collected by us is compromised by
          unauthorized access, we will investigate and notify any individuals
          associated with accounts that were affected. We will also apply
          additional protections in a reasonable timeframe to prevent further
          unauthorized access.
        </p>
        <p>
          We employ measures to preserve the integrity of your data, including
          regular backups. With electronic records, data loss is a possibility.
          While we will do everything reasonable to protect and, if necessary,
          recover your data, it is your responsibility, if necessary, to keep a
          copy of critical information outside Plot.
        </p>
        <h2 id="4-international-transfers-of-personal-information">
          4. International transfers of personal information
        </h2>
        <p>
          The personal information we collect is stored and processed in Canada
          and/or the United States, or where we or our partners, affiliates and
          third-party providers maintain facilities. By providing us with your
          personal information, you consent to the disclosure to these overseas
          third parties.
        </p>
        <p>
          We will ensure that any transfer of personal information from
          countries in the European Economic Area (EEA) to countries outside the
          EEA will be protected by appropriate safeguards, for example by using
          standard data protection clauses approved by the European Commission,
          or the use of binding corporate rules or other legally accepted means.
        </p>
        <p>
          Where we transfer personal information from a non-EEA country to
          another country, you acknowledge that third parties in other
          jurisdictions may not be subject to similar data protection laws to
          the ones in our jurisdiction. There are risks if any such third party
          engages in any act or practice that would contravene the data privacy
          laws in our jurisdiction and this might mean that you will not be able
          to seek redress under our jurisdiction’s privacy laws.
        </p>
        <h2 id="5-your-rights-and-controlling-your-personal-information">
          5. Your rights and controlling your personal information
        </h2>
        <p>
          <strong>Choice and consent:</strong> By providing personal information
          to us, you consent to us collecting, holding, using and disclosing
          your personal information in accordance with this privacy policy. If
          you are under 16 years of age, you must have, and warrant to the
          extent permitted by law to us, that you have your parent or legal
          guardian’s permission to access and use the website and they (your
          parents or guardian) have consented to you providing us with your
          personal information. You do not have to provide personal information
          to us, however, if you do not, it may affect your use of this website
          or the products and/or services offered on or through it.
        </p>
        <p>
          <strong>Information from third parties:</strong> If we receive
          personal information about you from a third party, we will protect it
          as set out in this privacy policy. If you are a third party providing
          personal information about somebody else, you represent and warrant
          that you have such person’s consent to provide the personal
          information to us.
        </p>
        <p>
          <strong>Restrict:</strong> You may choose to restrict the collection
          or use of your personal information. If you have previously agreed to
          us using your personal information for direct marketing purposes, you
          may change your mind at any time by contacting us using the details
          below. If you ask us to restrict or limit how we process your personal
          information, we will let you know how the restriction affects your use
          of our website or products and services.
        </p>
        <p>
          <strong>Access and data portability:</strong> You may request details
          of the personal information that we hold about you. You may request a
          copy of the personal information we hold about you. Where possible, we
          will provide this information in CSV format or other easily readable
          machine format. You may request that we erase the personal information
          we hold about you at any time. You may also request that we transfer
          this personal information to another third party.
        </p>
        <p>
          <strong>Account deletion:</strong> You can delete your Plot account
          and associated data at any time by visiting our{" "}
          <a href="/account/delete">account deletion page</a>. When you request
          account deletion, your account will be immediately deactivated and you
          will no longer be able to sign in. Your data will be retained for 14
          days to allow for account recovery, after which it will be permanently
          deleted. Some data may be retained for legal or accounting purposes
          (such as transaction records). To recover your account within the
          14-day period, please contact us at privacy@plot.day.
        </p>
        <p>
          <strong>Correction:</strong> If you believe that any information we
          hold about you is inaccurate, out of date, incomplete, irrelevant or
          misleading, please contact us using the details below. We will take
          reasonable steps to correct any information found to be inaccurate,
          incomplete, misleading or out of date.
        </p>
        <p>
          <strong>Notification of data breaches:</strong> We will comply with laws
          applicable to us in respect of any data breach.
        </p>
        <p>
          <strong>Complaints:</strong> If you believe that we have breached a
          relevant data protection law and wish to make a complaint, please
          contact us using the details below and provide us with full details of
          the alleged breach. We will promptly investigate your complaint and
          respond to you, in writing, setting out the outcome of our
          investigation and the steps we will take to deal with your complaint.
          You also have the right to contact a regulatory body or data
          protection authority in relation to your complaint.
        </p>
        <p>
          <strong>Unsubscribe:</strong> To unsubscribe from our e-mail database
          or opt-out of communications (including marketing communications),
          please contact us using the details below or opt-out using the opt-out
          facilities provided in the communication.
        </p>
        <h2 id="6-business-transfers">6. Business transfers</h2>
        <p>
          If we or our assets are acquired, or in the unlikely event that we go
          out of business or enter bankruptcy, we would include data among the
          assets transferred to any parties who acquire us. You acknowledge that
          such transfers may occur, and that any parties who acquire us may
          continue to use your personal information according to this policy.
        </p>
        <h2 id="7-children-s-privacy">7. Children’s privacy</h2>
        <p>
          Plot does not knowingly collect or solicit personal information from
          children under the age of 13 and the product and its content are not
          directed at children under the age of 13. In the event that we learn
          that we have collected personal information from a child under age 13
          without verification of parental consent, we will delete that
          information as quickly as possible. If you believe that we might have
          any information from or about a child under 13, please contact us
          using the information below.
        </p>
        <h2 id="8-limits-of-our-policy">8. Limits of our policy</h2>
        <p>
          Our website may link to external sites that are not operated by us.
          Please be aware that we have no control over the content and policies
          of those sites, and cannot accept responsibility or liability for
          their respective privacy practices.
        </p>
        <h2 id="9-changes-to-this-policy">9. Changes to this policy</h2>
        <p>
          At our discretion, we may change our privacy policy to reflect current
          acceptable practices. We will take reasonable steps to let users know
          about changes via our website. Your continued use of this site after
          any changes to this policy will be regarded as acceptance of our
          practices around privacy and personal information.
        </p>
        <p>
          If we make a significant change to this privacy policy, for example
          changing a lawful basis on which we process your personal information,
          we will ask you to re-consent to the amended privacy policy.
        </p>
        <h2 id="10-how-to-contact-us">10. How to contact us</h2>
        <p>
          If you have any questions about this Privacy Policy or wish to make a
          request, please contact us at:
        </p>
        <p>
          <strong>Plot Technologies Inc Data Controller</strong>
          <br />
          privacy@plot.day
        </p>
        <p>This policy is effective as of April 23, 2026.</p>
      </TypographyStylesProvider>
    </Container>
  );
}
