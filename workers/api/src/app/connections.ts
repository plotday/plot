import { Hono } from "hono";
import type { Bindings } from "../env";

type UpcomingConnection = {
  name: string;
  logo: string;
  logoDark?: string;
  category: string;
  entities: string[];
  description?: string;
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
    description: "Track issues and sprints from Jira",
  },
  {
    name: "Asana",
    ...si("asana", "F06A6A", "F06A6A"),
    category: "Project Management",
    entities: ["Tasks", "Projects"],
    description: "Manage tasks and projects from Asana",
  },
  {
    name: "Notion",
    logo: "https://api.iconify.design/logos/notion-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/notion.svg?color=%23ffffff",
    category: "Documents",
    entities: ["Pages", "Databases"],
    description: "Sync pages and databases from Notion",
  },
  {
    name: "Slack",
    logo: "https://api.iconify.design/logos/slack-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    description: "See messages and threads from Slack",
  },
  {
    name: "Outlook Calendar",
    ...si("microsoftoutlook", "0078D4", "2B88D8"),
    category: "Calendar",
    entities: ["Events", "RSVPs"],
    description: "Sync events and RSVPs from Outlook",
  },

  // Calendar
  {
    name: "Apple Calendar",
    ...si("apple", "000000", "ffffff"),
    category: "Calendar",
    entities: ["Events", "Reminders"],
    description: "Sync events from Apple Calendar",
  },
  {
    name: "Calendly",
    ...si("calendly", "006BFF", "4D9AFF"),
    category: "Calendar",
    entities: ["Events", "Invitees"],
    description: "Track scheduled meetings from Calendly",
  },
  {
    name: "Cal.com",
    ...si("caldotcom", "111827", "ffffff"),
    category: "Calendar",
    entities: ["Events", "Bookings"],
    description: "Track bookings and events from Cal.com",
  },

  // Communication
  {
    name: "Microsoft Teams",
    logo: "https://api.iconify.design/logos/microsoft-teams.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    description: "See messages and channels from Teams",
  },
  {
    name: "Discord",
    logo: "https://api.iconify.design/logos/discord-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    description: "See messages and channels from Discord",
  },
  {
    name: "Zoom",
    logo: "https://api.iconify.design/logos/zoom-icon.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
    description: "Track meetings and recordings from Zoom",
  },
  {
    name: "Google Meet",
    logo: "https://api.iconify.design/logos/google-meet.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
    description: "Track meetings from Google Meet",
  },
  {
    name: "Loom",
    logo: "https://api.iconify.design/logos/loom-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/loom.svg?color=%23625DF5",
    category: "Communication",
    entities: ["Videos", "Comments"],
    description: "See video updates and comments from Loom",
  },
  {
    name: "Twilio",
    logo: "https://api.iconify.design/logos/twilio-icon.svg",
    category: "Communication",
    entities: ["Messages", "Calls"],
    description: "Track messages and calls from Twilio",
  },

  // Email
  {
    name: "Outlook Mail",
    ...si("microsoftoutlook", "0078D4", "2B88D8"),
    category: "Email",
    entities: ["Emails", "Threads"],
    description: "Sync emails and threads from Outlook",
  },
  {
    name: "SendGrid",
    ...si("sendgrid", "1A82E2", "4DA6F0"),
    category: "Email",
    entities: ["Emails", "Stats"],
    description: "Track email delivery and stats from SendGrid",
  },

  // Project Management
  {
    name: "Trello",
    logo: "https://api.iconify.design/logos/trello.svg",
    category: "Project Management",
    entities: ["Cards", "Boards"],
    description: "Track cards and boards from Trello",
  },
  {
    name: "Monday.com",
    logo: "https://api.iconify.design/logos/monday-icon.svg",
    category: "Project Management",
    entities: ["Items", "Boards"],
    description: "Manage items and boards from Monday.com",
  },
  {
    name: "ClickUp",
    ...si("clickup", "7B68EE", "9B8AFE"),
    category: "Project Management",
    entities: ["Tasks", "Spaces"],
    description: "Track tasks and spaces from ClickUp",
  },
  {
    name: "Basecamp",
    ...si("basecamp", "1D2D35", "ffffff"),
    category: "Project Management",
    entities: ["To-dos", "Messages"],
    description: "Sync to-dos and messages from Basecamp",
  },
  {
    name: "Shortcut",
    logo: "https://api.iconify.design/logos/shortcut-icon.svg",
    category: "Project Management",
    entities: ["Stories", "Epics"],
    description: "Track stories and epics from Shortcut",
  },
  {
    name: "Teamwork",
    logo: "https://api.iconify.design/logos/teamwork-icon.svg",
    category: "Project Management",
    entities: ["Tasks", "Projects"],
    description: "Manage tasks and projects from Teamwork",
  },

  // Design
  {
    name: "Figma",
    logo: "https://api.iconify.design/logos/figma.svg",
    category: "Design",
    entities: ["Comments", "Files"],
    description: "See design comments and files from Figma",
  },
  {
    name: "Miro",
    logo: "https://api.iconify.design/logos/miro-icon.svg",
    category: "Design",
    entities: ["Boards", "Comments"],
    description: "Track boards and comments from Miro",
  },
  {
    name: "Canva",
    ...si("canva", "00C4CC", "00C4CC"),
    category: "Design",
    entities: ["Designs", "Comments"],
    description: "See designs and comments from Canva",
  },
  {
    name: "Adobe Creative Cloud",
    ...si("adobe", "FF0000", "FF4444"),
    category: "Design",
    entities: ["Files", "Comments"],
    description: "Track files and feedback from Adobe CC",
  },
  {
    name: "Webflow",
    logo: "https://api.iconify.design/logos/webflow.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/webflow.svg?color=%23146EF5",
    category: "Design",
    entities: ["Forms", "CMS Items"],
    description: "Track form submissions and CMS from Webflow",
  },
  {
    name: "Framer",
    logo: "https://api.iconify.design/logos/framer.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/framer.svg?color=%230055FF",
    category: "Design",
    entities: ["Forms", "Analytics"],
    description: "Track forms and analytics from Framer",
  },

  // Documents
  {
    name: "Confluence",
    logo: "https://api.iconify.design/logos/confluence.svg",
    category: "Documents",
    entities: ["Pages", "Comments"],
    description: "Sync wiki pages and comments from Confluence",
  },
  {
    name: "Coda",
    ...si("coda", "F46A54", "F46A54"),
    category: "Documents",
    entities: ["Docs", "Tables"],
    description: "Sync docs and tables from Coda",
  },
  {
    name: "Dropbox Paper",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Documents",
    entities: ["Docs", "Comments"],
    description: "Track docs and comments from Dropbox Paper",
  },
  {
    name: "Microsoft Word",
    ...si("microsoftword", "2B579A", "4B8BBE"),
    category: "Documents",
    entities: ["Documents", "Comments"],
    description: "Track documents and comments from Word",
  },
  {
    name: "Google Docs",
    ...si("googledocs", "4285F4", "4285F4"),
    category: "Documents",
    entities: ["Documents", "Comments"],
    description: "Track documents and comments from Google Docs",
  },
  {
    name: "DocuSign",
    ...si("docusign", "FFCD00", "FFCD00"),
    category: "Documents",
    entities: ["Envelopes", "Signatures"],
    description: "Track signature requests from DocuSign",
  },

  // Development
  {
    name: "GitLab",
    logo: "https://api.iconify.design/logos/gitlab.svg",
    category: "Development",
    entities: ["Issues", "Merge Requests"],
    description: "Track issues and merge requests from GitLab",
  },
  {
    name: "Bitbucket",
    logo: "https://api.iconify.design/logos/bitbucket.svg",
    category: "Development",
    entities: ["Issues", "Pull Requests"],
    description: "Track issues and PRs from Bitbucket",
  },
  {
    name: "Sentry",
    logo: "https://api.iconify.design/logos/sentry-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/sentry.svg?color=%23ffffff",
    category: "Development",
    entities: ["Issues", "Alerts"],
    description: "Track errors and alerts from Sentry",
  },
  {
    name: "Vercel",
    logo: "https://api.iconify.design/logos/vercel-icon.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/vercel.svg?color=%23ffffff",
    category: "Development",
    entities: ["Deployments", "Comments"],
    description: "Track deployments and comments from Vercel",
  },
  {
    name: "PagerDuty",
    ...si("pagerduty", "06AC38", "06AC38"),
    category: "Development",
    entities: ["Incidents", "Alerts"],
    description: "Track incidents and alerts from PagerDuty",
  },
  {
    name: "Datadog",
    logo: "https://api.iconify.design/logos/datadog.svg",
    category: "Development",
    entities: ["Alerts", "Monitors"],
    description: "Track alerts and monitors from Datadog",
  },
  {
    name: "LaunchDarkly",
    logo: "https://api.iconify.design/logos/launchdarkly-icon.svg",
    category: "Development",
    entities: ["Flags", "Changes"],
    description: "Track feature flags from LaunchDarkly",
  },
  {
    name: "Supabase",
    logo: "https://api.iconify.design/logos/supabase-icon.svg",
    category: "Development",
    entities: ["Alerts", "Logs"],
    description: "Track alerts and logs from Supabase",
  },
  {
    name: "Firebase",
    logo: "https://api.iconify.design/logos/firebase.svg",
    category: "Development",
    entities: ["Alerts", "Analytics"],
    description: "Track alerts and analytics from Firebase",
  },

  // CRM
  {
    name: "Salesforce",
    logo: "https://api.iconify.design/logos/salesforce.svg",
    category: "CRM",
    entities: ["Leads", "Opportunities", "Tasks"],
    description: "Track leads and opportunities from Salesforce",
  },
  {
    name: "HubSpot",
    logo: "https://api.iconify.design/logos/hubspot.svg",
    category: "CRM",
    entities: ["Contacts", "Deals", "Tasks"],
    description: "Track contacts and deals from HubSpot",
  },
  {
    name: "Pipedrive",
    logo: "https://api.iconify.design/logos/pipedrive.svg",
    category: "CRM",
    entities: ["Deals", "Activities"],
    description: "Track deals and activities from Pipedrive",
  },

  // Customer Support
  {
    name: "Zendesk",
    logo: "https://api.iconify.design/logos/zendesk-icon.svg",
    category: "Customer Support",
    entities: ["Tickets", "Comments"],
    description: "Track support tickets from Zendesk",
  },
  {
    name: "Intercom",
    logo: "https://api.iconify.design/logos/intercom-icon.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tickets"],
    description: "Track conversations and tickets from Intercom",
  },
  {
    name: "Front",
    logo: "https://api.iconify.design/logos/frontapp.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tags"],
    description: "Track shared inbox conversations from Front",
  },

  // Cloud Storage
  {
    name: "Dropbox",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    description: "Track files and comments from Dropbox",
  },
  {
    name: "OneDrive",
    ...si("microsoftonedrive", "0078D4", "2B88D8"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    description: "Track files and comments from OneDrive",
  },
  {
    name: "Box",
    ...si("box", "0061D5", "3B8DF0"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    description: "Track files and comments from Box",
  },

  // Finance
  {
    name: "Stripe",
    logo: "https://api.iconify.design/logos/stripe.svg",
    category: "Finance",
    entities: ["Payments", "Invoices"],
    description: "Track payments and invoices from Stripe",
  },
  {
    name: "QuickBooks",
    ...si("quickbooks", "2CA01C", "2FBF4E"),
    category: "Finance",
    entities: ["Invoices", "Expenses"],
    description: "Track invoices and expenses from QuickBooks",
  },
  {
    name: "Xero",
    ...si("xero", "13B5EA", "13B5EA"),
    category: "Finance",
    entities: ["Invoices", "Bills"],
    description: "Track invoices and bills from Xero",
  },

  // HR
  {
    name: "Gusto",
    ...si("gusto", "F45D48", "F45D48"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
    description: "Track time off and HR tasks from Gusto",
  },
  {
    name: "BambooHR",
    ...si("bamboo", "73C41D", "73C41D"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
    description: "Track time off and HR tasks from BambooHR",
  },

  // Marketing
  {
    name: "Mailchimp",
    logo: "https://api.iconify.design/logos/mailchimp-freddie.svg",
    category: "Marketing",
    entities: ["Campaigns", "Reports"],
    description: "Track email campaigns from Mailchimp",
  },

  // Analytics
  {
    name: "Google Analytics",
    logo: "https://api.iconify.design/logos/google-analytics.svg",
    category: "Analytics",
    entities: ["Reports", "Alerts"],
    description: "Track website analytics from Google Analytics",
  },
  {
    name: "Amplitude",
    logo: "https://api.iconify.design/logos/amplitude-icon.svg",
    category: "Analytics",
    entities: ["Reports", "Experiments"],
    description: "Track product analytics from Amplitude",
  },
  {
    name: "Mixpanel",
    ...si("mixpanel", "7856FF", "9B7FFF"),
    category: "Analytics",
    entities: ["Reports", "Alerts"],
    description: "Track product analytics from Mixpanel",
  },
  {
    name: "PostHog",
    ...si("posthog", "F54E00", "F54E00"),
    category: "Analytics",
    entities: ["Insights", "Flags"],
    description: "Track product insights and flags from PostHog",
  },

  // Notes
  {
    name: "Evernote",
    ...si("evernote", "00A82D", "00A82D"),
    category: "Notes",
    entities: ["Notes", "Notebooks"],
    description: "Sync notes and notebooks from Evernote",
  },
  {
    name: "Apple Notes",
    ...si("apple", "000000", "ffffff"),
    category: "Notes",
    entities: ["Notes", "Folders"],
    description: "Sync notes and folders from Apple Notes",
  },
  {
    name: "Obsidian",
    ...si("obsidian", "7C3AED", "A78BFA"),
    category: "Notes",
    entities: ["Notes", "Vaults"],
    description: "Sync notes and vaults from Obsidian",
  },

  // Productivity
  {
    name: "Todoist",
    logo: "https://api.iconify.design/logos/todoist-icon.svg",
    category: "Productivity",
    entities: ["Tasks", "Projects"],
    description: "Track tasks and projects from Todoist",
  },
  {
    name: "Airtable",
    ...si("airtable", "18BFFF", "18BFFF"),
    category: "Productivity",
    entities: ["Records", "Tables"],
    description: "Sync records and tables from Airtable",
  },
  {
    name: "Google Sheets",
    ...si("googlesheets", "34A853", "34A853"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
    description: "Track spreadsheets from Google Sheets",
  },
  {
    name: "Microsoft Excel",
    ...si("microsoftexcel", "217346", "33AB67"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
    description: "Track spreadsheets from Microsoft Excel",
  },
  {
    name: "Google Tasks",
    ...si("googletasks", "4285F4", "4285F4"),
    category: "Productivity",
    entities: ["Tasks", "Lists"],
    description: "Sync tasks and lists from Google Tasks",
  },
  {
    name: "Apple Reminders",
    ...si("apple", "000000", "ffffff"),
    category: "Productivity",
    entities: ["Reminders", "Lists"],
    description: "Sync reminders and lists from Apple Reminders",
  },
  {
    name: "Typeform",
    ...si("typeform", "262627", "ffffff"),
    category: "Productivity",
    entities: ["Responses", "Forms"],
    description: "Track form responses from Typeform",
  },
  {
    name: "SurveyMonkey",
    ...si("surveymonkey", "00BF6F", "00BF6F"),
    category: "Productivity",
    entities: ["Responses", "Surveys"],
    description: "Track survey responses from SurveyMonkey",
  },

  // Automation
  {
    name: "Zapier",
    ...si("zapier", "FF4A00", "FF4A00"),
    category: "Automation",
    entities: ["Zaps", "Tasks"],
    description: "Track automated workflows from Zapier",
  },
  {
    name: "Make",
    ...si("make", "6D00CC", "9B4DFF"),
    category: "Automation",
    entities: ["Scenarios", "Operations"],
    description: "Track automation scenarios from Make",
  },
  {
    name: "n8n",
    ...si("n8n", "EA4B71", "EA4B71"),
    category: "Automation",
    entities: ["Workflows", "Executions"],
    description: "Track workflow executions from n8n",
  },

  // E-commerce
  {
    name: "Shopify",
    logo: "https://api.iconify.design/logos/shopify.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
    description: "Track orders and products from Shopify",
  },
  {
    name: "WooCommerce",
    logo: "https://api.iconify.design/logos/woocommerce-icon.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
    description: "Track orders and products from WooCommerce",
  },

  // Cloud
  {
    name: "AWS",
    logo: "https://api.iconify.design/logos/aws.svg",
    logoDark:
      "https://api.iconify.design/simple-icons/amazonaws.svg?color=%23FF9900",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
    description: "Track alerts and deployments from AWS",
  },
  {
    name: "Google Cloud",
    logo: "https://api.iconify.design/logos/google-cloud.svg",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
    description: "Track alerts and deployments from Google Cloud",
  },
  {
    name: "Cloudflare",
    logo: "https://api.iconify.design/logos/cloudflare-icon.svg",
    category: "Cloud",
    entities: ["Workers", "Analytics"],
    description: "Track workers and analytics from Cloudflare",
  },

  // Security
  {
    name: "1Password",
    ...si("1password", "0094F5", "3DB4FF"),
    category: "Security",
    entities: ["Events", "Alerts"],
    description: "Track security events from 1Password",
  },
  {
    name: "Okta",
    ...si("okta", "007DC1", "2EAADC"),
    category: "Security",
    entities: ["Events", "Users"],
    description: "Track identity events from Okta",
  },

  // Product
  {
    name: "Productboard",
    logo: "https://api.iconify.design/logos/productboard-icon.svg",
    category: "Product",
    entities: ["Features", "Insights"],
    description: "Track feature requests from Productboard",
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
