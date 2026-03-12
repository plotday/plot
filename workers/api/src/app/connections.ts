import { Hono } from "hono";
import type { Bindings } from "../env";

type UpcomingConnection = {
  name: string;
  logo: string;
  logoDark?: string;
  category: string;
  entities: string[];
};

// simple-icons with brand color for light, lighter variant for dark
const si = (name: string, color: string, colorDark?: string) => ({
  logo: `https://api.iconify.design/simple-icons/${name}.svg?color=%23${color}`,
  logoDark: `https://api.iconify.design/simple-icons/${name}.svg?color=%23${colorDark || "ffffff"}`,
});

// Non-available connections from the site's connections data
const UPCOMING_CONNECTIONS: UpcomingConnection[] = [
  // Written but not yet deployed
  {
    name: "Jira",
    logo: "https://api.iconify.design/logos/jira.svg",
    category: "Project Management",
    entities: ["Issues", "Sprints"],
  },
  {
    name: "Asana",
    logo: "https://api.iconify.design/logos/asana-icon.svg",
    category: "Project Management",
    entities: ["Tasks", "Projects"],
  },
  {
    name: "Notion",
    logo: "https://api.iconify.design/logos/notion-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/notion.svg?color=%23ffffff",
    category: "Documents",
    entities: ["Pages", "Databases"],
  },
  {
    name: "Slack",
    logo: "https://api.iconify.design/logos/slack-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
  },
  {
    name: "Outlook Calendar",
    ...si("microsoftoutlook", "0078D4", "2B88D8"),
    category: "Calendar",
    entities: ["Events", "RSVPs"],
  },

  // Calendar
  {
    name: "Apple Calendar",
    ...si("apple", "000000", "ffffff"),
    category: "Calendar",
    entities: ["Events", "Reminders"],
  },
  {
    name: "Calendly",
    ...si("calendly", "006BFF", "4D9AFF"),
    category: "Calendar",
    entities: ["Events", "Invitees"],
  },
  {
    name: "Cal.com",
    ...si("caldotcom", "111827", "ffffff"),
    category: "Calendar",
    entities: ["Events", "Bookings"],
  },

  // Communication
  {
    name: "Microsoft Teams",
    logo: "https://api.iconify.design/logos/microsoft-teams.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
  },
  {
    name: "Discord",
    logo: "https://api.iconify.design/logos/discord-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
  },
  {
    name: "Zoom",
    logo: "https://api.iconify.design/logos/zoom-icon.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
  },
  {
    name: "Google Meet",
    logo: "https://api.iconify.design/logos/google-meet.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
  },
  {
    name: "Loom",
    logo: "https://api.iconify.design/logos/loom-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/loom.svg?color=%23625DF5",
    category: "Communication",
    entities: ["Videos", "Comments"],
  },
  {
    name: "Twilio",
    logo: "https://api.iconify.design/logos/twilio-icon.svg",
    category: "Communication",
    entities: ["Messages", "Calls"],
  },

  // Email
  {
    name: "Outlook Mail",
    ...si("microsoftoutlook", "0078D4", "2B88D8"),
    category: "Email",
    entities: ["Emails", "Threads"],
  },
  {
    name: "SendGrid",
    ...si("sendgrid", "1A82E2", "4DA6F0"),
    category: "Email",
    entities: ["Emails", "Stats"],
  },

  // Project Management
  {
    name: "Trello",
    logo: "https://api.iconify.design/logos/trello.svg",
    category: "Project Management",
    entities: ["Cards", "Boards"],
  },
  {
    name: "Monday.com",
    logo: "https://api.iconify.design/logos/monday-icon.svg",
    category: "Project Management",
    entities: ["Items", "Boards"],
  },
  {
    name: "ClickUp",
    ...si("clickup", "7B68EE", "9B8AFE"),
    category: "Project Management",
    entities: ["Tasks", "Spaces"],
  },
  {
    name: "Basecamp",
    ...si("basecamp", "1D2D35", "ffffff"),
    category: "Project Management",
    entities: ["To-dos", "Messages"],
  },
  {
    name: "Shortcut",
    logo: "https://api.iconify.design/logos/shortcut-icon.svg",
    category: "Project Management",
    entities: ["Stories", "Epics"],
  },
  {
    name: "Teamwork",
    logo: "https://api.iconify.design/logos/teamwork-icon.svg",
    category: "Project Management",
    entities: ["Tasks", "Projects"],
  },

  // Design
  {
    name: "Figma",
    logo: "https://api.iconify.design/logos/figma.svg",
    category: "Design",
    entities: ["Comments", "Files"],
  },
  {
    name: "Miro",
    logo: "https://api.iconify.design/logos/miro-icon.svg",
    category: "Design",
    entities: ["Boards", "Comments"],
  },
  {
    name: "Canva",
    ...si("canva", "00C4CC", "00C4CC"),
    category: "Design",
    entities: ["Designs", "Comments"],
  },
  {
    name: "Adobe Creative Cloud",
    ...si("adobe", "FF0000", "FF4444"),
    category: "Design",
    entities: ["Files", "Comments"],
  },
  {
    name: "Webflow",
    logo: "https://api.iconify.design/logos/webflow.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/webflow.svg?color=%23146EF5",
    category: "Design",
    entities: ["Forms", "CMS Items"],
  },
  {
    name: "Framer",
    logo: "https://api.iconify.design/logos/framer.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/framer.svg?color=%230055FF",
    category: "Design",
    entities: ["Forms", "Analytics"],
  },

  // Documents
  {
    name: "Confluence",
    logo: "https://api.iconify.design/logos/confluence.svg",
    category: "Documents",
    entities: ["Pages", "Comments"],
  },
  {
    name: "Coda",
    ...si("coda", "F46A54", "F46A54"),
    category: "Documents",
    entities: ["Docs", "Tables"],
  },
  {
    name: "Dropbox Paper",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Documents",
    entities: ["Docs", "Comments"],
  },
  {
    name: "Microsoft Word",
    ...si("microsoftword", "2B579A", "4B8BBE"),
    category: "Documents",
    entities: ["Documents", "Comments"],
  },
  {
    name: "Google Docs",
    ...si("googledocs", "4285F4", "4285F4"),
    category: "Documents",
    entities: ["Documents", "Comments"],
  },
  {
    name: "DocuSign",
    ...si("docusign", "FFCD00", "FFCD00"),
    category: "Documents",
    entities: ["Envelopes", "Signatures"],
  },

  // Development
  {
    name: "GitLab",
    logo: "https://api.iconify.design/logos/gitlab.svg",
    category: "Development",
    entities: ["Issues", "Merge Requests"],
  },
  {
    name: "Bitbucket",
    logo: "https://api.iconify.design/logos/bitbucket.svg",
    category: "Development",
    entities: ["Issues", "Pull Requests"],
  },
  {
    name: "Sentry",
    logo: "https://api.iconify.design/logos/sentry-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/sentry.svg?color=%23ffffff",
    category: "Development",
    entities: ["Issues", "Alerts"],
  },
  {
    name: "Vercel",
    logo: "https://api.iconify.design/logos/vercel-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/vercel.svg?color=%23ffffff",
    category: "Development",
    entities: ["Deployments", "Comments"],
  },
  {
    name: "PagerDuty",
    ...si("pagerduty", "06AC38", "06AC38"),
    category: "Development",
    entities: ["Incidents", "Alerts"],
  },
  {
    name: "Datadog",
    logo: "https://api.iconify.design/logos/datadog.svg",
    category: "Development",
    entities: ["Alerts", "Monitors"],
  },
  {
    name: "LaunchDarkly",
    logo: "https://api.iconify.design/logos/launchdarkly-icon.svg",
    category: "Development",
    entities: ["Flags", "Changes"],
  },
  {
    name: "Supabase",
    logo: "https://api.iconify.design/logos/supabase-icon.svg",
    category: "Development",
    entities: ["Alerts", "Logs"],
  },
  {
    name: "Firebase",
    logo: "https://api.iconify.design/logos/firebase.svg",
    category: "Development",
    entities: ["Alerts", "Analytics"],
  },

  // CRM
  {
    name: "Salesforce",
    logo: "https://api.iconify.design/logos/salesforce.svg",
    category: "CRM",
    entities: ["Leads", "Opportunities", "Tasks"],
  },
  {
    name: "HubSpot",
    logo: "https://api.iconify.design/logos/hubspot.svg",
    category: "CRM",
    entities: ["Contacts", "Deals", "Tasks"],
  },
  {
    name: "Pipedrive",
    logo: "https://api.iconify.design/logos/pipedrive.svg",
    category: "CRM",
    entities: ["Deals", "Activities"],
  },

  // Customer Support
  {
    name: "Zendesk",
    logo: "https://api.iconify.design/logos/zendesk-icon.svg",
    category: "Customer Support",
    entities: ["Tickets", "Comments"],
  },
  {
    name: "Intercom",
    logo: "https://api.iconify.design/logos/intercom-icon.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tickets"],
  },
  {
    name: "Front",
    logo: "https://api.iconify.design/logos/frontapp.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tags"],
  },

  // Cloud Storage
  {
    name: "Dropbox",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
  },
  {
    name: "OneDrive",
    ...si("microsoftonedrive", "0078D4", "2B88D8"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
  },
  {
    name: "Box",
    ...si("box", "0061D5", "3B8DF0"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
  },

  // Finance
  {
    name: "Stripe",
    logo: "https://api.iconify.design/logos/stripe.svg",
    category: "Finance",
    entities: ["Payments", "Invoices"],
  },
  {
    name: "QuickBooks",
    ...si("quickbooks", "2CA01C", "2FBF4E"),
    category: "Finance",
    entities: ["Invoices", "Expenses"],
  },
  {
    name: "Xero",
    ...si("xero", "13B5EA", "13B5EA"),
    category: "Finance",
    entities: ["Invoices", "Bills"],
  },

  // HR
  {
    name: "Gusto",
    ...si("gusto", "F45D48", "F45D48"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
  },
  {
    name: "BambooHR",
    ...si("bamboo", "73C41D", "73C41D"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
  },

  // Marketing
  {
    name: "Mailchimp",
    logo: "https://api.iconify.design/logos/mailchimp-freddie.svg",
    category: "Marketing",
    entities: ["Campaigns", "Reports"],
  },

  // Analytics
  {
    name: "Google Analytics",
    logo: "https://api.iconify.design/logos/google-analytics.svg",
    category: "Analytics",
    entities: ["Reports", "Alerts"],
  },
  {
    name: "Amplitude",
    logo: "https://api.iconify.design/logos/amplitude-icon.svg",
    category: "Analytics",
    entities: ["Reports", "Experiments"],
  },
  {
    name: "Mixpanel",
    ...si("mixpanel", "7856FF", "9B7FFF"),
    category: "Analytics",
    entities: ["Reports", "Alerts"],
  },
  {
    name: "PostHog",
    ...si("posthog", "F54E00", "F54E00"),
    category: "Analytics",
    entities: ["Insights", "Flags"],
  },

  // Notes
  {
    name: "Evernote",
    ...si("evernote", "00A82D", "00A82D"),
    category: "Notes",
    entities: ["Notes", "Notebooks"],
  },
  {
    name: "Apple Notes",
    ...si("apple", "000000", "ffffff"),
    category: "Notes",
    entities: ["Notes", "Folders"],
  },
  {
    name: "Obsidian",
    ...si("obsidian", "7C3AED", "A78BFA"),
    category: "Notes",
    entities: ["Notes", "Vaults"],
  },

  // Productivity
  {
    name: "Todoist",
    logo: "https://api.iconify.design/logos/todoist-icon.svg",
    category: "Productivity",
    entities: ["Tasks", "Projects"],
  },
  {
    name: "Airtable",
    ...si("airtable", "18BFFF", "18BFFF"),
    category: "Productivity",
    entities: ["Records", "Tables"],
  },
  {
    name: "Google Sheets",
    ...si("googlesheets", "34A853", "34A853"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
  },
  {
    name: "Microsoft Excel",
    ...si("microsoftexcel", "217346", "33AB67"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
  },
  {
    name: "Google Tasks",
    ...si("googletasks", "4285F4", "4285F4"),
    category: "Productivity",
    entities: ["Tasks", "Lists"],
  },
  {
    name: "Apple Reminders",
    ...si("apple", "000000", "ffffff"),
    category: "Productivity",
    entities: ["Reminders", "Lists"],
  },
  {
    name: "Typeform",
    ...si("typeform", "262627", "ffffff"),
    category: "Productivity",
    entities: ["Responses", "Forms"],
  },
  {
    name: "SurveyMonkey",
    ...si("surveymonkey", "00BF6F", "00BF6F"),
    category: "Productivity",
    entities: ["Responses", "Surveys"],
  },

  // Automation
  {
    name: "Zapier",
    ...si("zapier", "FF4A00", "FF4A00"),
    category: "Automation",
    entities: ["Zaps", "Tasks"],
  },
  {
    name: "Make",
    ...si("make", "6D00CC", "9B4DFF"),
    category: "Automation",
    entities: ["Scenarios", "Operations"],
  },
  {
    name: "n8n",
    ...si("n8n", "EA4B71", "EA4B71"),
    category: "Automation",
    entities: ["Workflows", "Executions"],
  },

  // E-commerce
  {
    name: "Shopify",
    logo: "https://api.iconify.design/logos/shopify.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
  },
  {
    name: "WooCommerce",
    logo: "https://api.iconify.design/logos/woocommerce-icon.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
  },

  // Cloud
  {
    name: "AWS",
    logo: "https://api.iconify.design/logos/aws.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/amazonaws.svg?color=%23FF9900",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
  },
  {
    name: "Google Cloud",
    logo: "https://api.iconify.design/logos/google-cloud.svg",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
  },
  {
    name: "Cloudflare",
    logo: "https://api.iconify.design/logos/cloudflare-icon.svg",
    category: "Cloud",
    entities: ["Workers", "Analytics"],
  },

  // Security
  {
    name: "1Password",
    ...si("1password", "0094F5", "3DB4FF"),
    category: "Security",
    entities: ["Events", "Alerts"],
  },
  {
    name: "Okta",
    ...si("okta", "007DC1", "2EAADC"),
    category: "Security",
    entities: ["Events", "Users"],
  },

  // Product
  {
    name: "Productboard",
    logo: "https://api.iconify.design/logos/productboard-icon.svg",
    category: "Product",
    entities: ["Features", "Insights"],
  },
];

const connections = new Hono<{ Bindings: Bindings }>();

connections.get("/connections/upcoming", async (c) => {
  const kv = c.env.VOTES;

  // Fetch all vote counts
  const votes: Record<string, number> = {};
  const list = await kv.list({ prefix: "votes:" });
  if (list.keys.length > 0) {
    const entries = await Promise.all(
      list.keys.map(async (key: { name: string }) => {
        const val = await kv.get(key.name);
        return [
          key.name.replace("votes:", ""),
          parseInt(val || "0", 10),
        ] as const;
      }),
    );
    for (const [name, count] of entries) {
      votes[name] = count;
    }
  }

  // Get user's votes
  const userId = c.var.user.id;
  let votedByUser: string[] = [];
  const userVotesRaw = await kv.get(`user-votes:${userId}`);
  if (userVotesRaw) {
    votedByUser = JSON.parse(userVotesRaw);
  }

  const connectionsWithVotes = UPCOMING_CONNECTIONS.map((conn) => ({
    ...conn,
    votes: votes[conn.name] || 0,
  }));

  return c.json({ connections: connectionsWithVotes, votedByUser });
});

connections.post("/connections/vote", async (c) => {
  const userId = c.var.user.id;

  const body = await c.req.json<{ name: string }>();
  const { name } = body;
  if (!name) {
    return c.json({ error: "Missing name" }, 400);
  }

  // Validate connection name exists
  if (!UPCOMING_CONNECTIONS.some((conn) => conn.name === name)) {
    return c.json({ error: "Unknown connection" }, 400);
  }

  const kv = c.env.VOTES;

  // Check if user already voted for this connection
  const userVotesKey = `user-votes:${userId}`;
  const userVotesRaw = await kv.get(userVotesKey);
  const userVotes: string[] = userVotesRaw ? JSON.parse(userVotesRaw) : [];

  if (userVotes.includes(name)) {
    // Already voted — return current count
    const current = parseInt((await kv.get(`votes:${name}`)) || "0", 10);
    return c.json({ name, votes: current });
  }

  // Increment vote count
  const voteKey = `votes:${name}`;
  const current = parseInt((await kv.get(voteKey)) || "0", 10);
  const newCount = current + 1;
  await kv.put(voteKey, String(newCount));

  // Record user's vote
  userVotes.push(name);
  await kv.put(userVotesKey, JSON.stringify(userVotes));

  // Track in PostHog
  c.var.tracker.capture("[Action] Connection Voted", {
    connection_name: name,
  });

  return c.json({ name, votes: newCount });
});

export default connections;
