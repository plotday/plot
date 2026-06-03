export type Connection = {
  name: string;
  logo: string;
  logoDark?: string;
  category: string;
  entities: string[];
  available: boolean;
  // True for "premium" connections (Unipile-backed, real per-connection cost).
  // Pro plan includes 1; Team plan counts each as 3 from the shared pool;
  // Free/Core can't enable premium connections.
  premium?: boolean;
};

// simple-icons with brand color for light, lighter variant for dark
const si = (name: string, color: string, colorDark?: string) => ({
  logo: `https://api.iconify.design/simple-icons/${name}.svg?color=%23${color}`,
  logoDark: `https://api.iconify.design/simple-icons/${name}.svg?color=%23${colorDark || "ffffff"}`,
});

export const CONNECTIONS: Connection[] = [
  // ── Available sources (deployed to production) ──
  {
    name: "Google Calendar",
    logo: "https://api.iconify.design/logos/google-calendar.svg",
    category: "Calendar",
    entities: ["Events", "RSVPs"],
    available: true,
  },
  {
    name: "Gmail",
    logo: "https://api.iconify.design/logos/google-gmail.svg",
    category: "Email",
    entities: ["Emails", "Threads"],
    available: true,
  },
  {
    name: "Linear",
    logo: "https://api.iconify.design/logos/linear-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/linear.svg?color=%235E6AD2",
    category: "Project Management",
    entities: ["Issues", "Projects"],
    available: true,
  },
  {
    name: "GitHub",
    logo: "https://api.iconify.design/logos/github-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/github.svg?color=%23ffffff",
    category: "Development",
    entities: ["Issues", "Pull Requests", "Actions"],
    available: true,
  },
  {
    name: "Google Drive",
    logo: "https://api.iconify.design/logos/google-drive.svg",
    category: "Documents",
    entities: ["Comment Threads"],
    available: true,
  },
  {
    name: "LinkedIn",
    logo: "https://api.iconify.design/logos/linkedin-icon.svg",
    category: "Communication",
    entities: ["Messages", "Connection requests"],
    available: true,
    premium: true,
  },
  {
    name: "WhatsApp",
    logo: "https://api.iconify.design/logos/whatsapp-icon.svg",
    category: "Communication",
    entities: ["Messages", "Groups"],
    available: true,
    premium: true,
  },
  {
    name: "Instagram",
    logo: "https://api.iconify.design/skill-icons/instagram.svg",
    category: "Communication",
    entities: ["Messages", "Requests"],
    available: true,
    premium: true,
  },

  // ── Written but not yet deployed ──
  {
    name: "Jira",
    logo: "https://api.iconify.design/logos/jira.svg",
    category: "Project Management",
    entities: ["Issues", "Sprints"],
    available: false,
  },
  {
    name: "Asana",
    ...si("asana", "F06A6A", "F06A6A"),
    category: "Project Management",
    entities: ["Tasks", "Projects"],
    available: false,
  },
  {
    name: "Notion",
    logo: "https://api.iconify.design/logos/notion-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/notion.svg?color=%23ffffff",
    category: "Documents",
    entities: ["Pages", "Databases"],
    available: false,
  },
  {
    name: "Slack",
    logo: "https://api.iconify.design/logos/slack-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    available: false,
  },
  {
    name: "Outlook Calendar",
    ...si("microsoftoutlook", "0078D4", "47A5ED"),
    category: "Calendar",
    entities: ["Events", "RSVPs"],
    available: false,
  },

  // ── Upcoming connections ──

  // Calendar
  {
    name: "Apple Calendar",
    logo: "/assets/logo-apple-calendar.svg",
    category: "Calendar",
    entities: ["Events", "Reminders"],
    available: false,
  },
  {
    name: "Calendly",
    ...si("calendly", "006BFF", "4D9AFF"),
    category: "Calendar",
    entities: ["Events", "Invitees"],
    available: false,
  },
  {
    name: "Cal.com",
    ...si("caldotcom", "111827", "ffffff"),
    category: "Calendar",
    entities: ["Events", "Bookings"],
    available: false,
  },

  // Communication
  {
    name: "Microsoft Teams",
    logo: "https://api.iconify.design/logos/microsoft-teams.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    available: true,
  },
  {
    name: "Discord",
    logo: "https://api.iconify.design/logos/discord-icon.svg",
    category: "Communication",
    entities: ["Messages", "Channels"],
    available: false,
  },
  {
    name: "Zoom",
    logo: "https://api.iconify.design/logos/zoom-icon.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
    available: false,
  },
  {
    name: "Google Meet",
    logo: "https://api.iconify.design/logos/google-meet.svg",
    category: "Communication",
    entities: ["Meetings", "Recordings"],
    available: false,
  },
  {
    name: "Loom",
    logo: "https://api.iconify.design/logos/loom-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/loom.svg?color=%23625DF5",
    category: "Communication",
    entities: ["Videos", "Comments"],
    available: false,
  },
  {
    name: "Twilio",
    logo: "https://api.iconify.design/logos/twilio-icon.svg",
    category: "Communication",
    entities: ["Messages", "Calls"],
    available: false,
  },

  // Email
  {
    name: "Outlook Mail",
    ...si("microsoftoutlook", "0078D4", "47A5ED"),
    category: "Email",
    entities: ["Emails", "Threads"],
    available: false,
  },
  {
    name: "SendGrid",
    ...si("sendgrid", "1A82E2", "4DA6F0"),
    category: "Email",
    entities: ["Emails", "Stats"],
    available: false,
  },

  // Project Management
  {
    name: "Trello",
    logo: "https://api.iconify.design/logos/trello.svg",
    category: "Project Management",
    entities: ["Cards", "Boards"],
    available: false,
  },
  {
    name: "Monday.com",
    logo: "https://api.iconify.design/logos/monday-icon.svg",
    category: "Project Management",
    entities: ["Items", "Boards"],
    available: false,
  },
  {
    name: "ClickUp",
    ...si("clickup", "7B68EE", "9B8AFE"),
    category: "Project Management",
    entities: ["Tasks", "Spaces"],
    available: false,
  },
  {
    name: "Basecamp",
    ...si("basecamp", "1D2D35", "ffffff"),
    category: "Project Management",
    entities: ["To-dos", "Messages"],
    available: false,
  },
  {
    name: "Shortcut",
    logo: "https://api.iconify.design/logos/shortcut-icon.svg",
    category: "Project Management",
    entities: ["Stories", "Epics"],
    available: false,
  },
  {
    name: "Teamwork",
    logo: "https://api.iconify.design/logos/teamwork-icon.svg",
    category: "Project Management",
    entities: ["Tasks", "Projects"],
    available: false,
  },

  // Design
  {
    name: "Figma",
    logo: "https://api.iconify.design/logos/figma.svg",
    category: "Design",
    entities: ["Comments", "Files"],
    available: false,
  },
  {
    name: "Miro",
    logo: "https://api.iconify.design/logos/miro-icon.svg",
    category: "Design",
    entities: ["Boards", "Comments"],
    available: false,
  },
  {
    name: "Canva",
    ...si("canva", "00C4CC", "00C4CC"),
    category: "Design",
    entities: ["Designs", "Comments"],
    available: false,
  },
  {
    name: "Adobe Creative Cloud",
    ...si("adobe", "FF0000", "FF4444"),
    category: "Design",
    entities: ["Files", "Comments"],
    available: false,
  },
  {
    name: "Webflow",
    ...si("webflow", "146EF5", "146EF5"),
    category: "Design",
    entities: ["Forms", "CMS Items"],
    available: false,
  },
  {
    name: "Framer",
    logo: "https://api.iconify.design/logos/framer.svg",
    logoDark: "https://api.iconify.design/simple-icons/framer.svg?color=%230055FF",
    category: "Design",
    entities: ["Forms", "Analytics"],
    available: false,
  },

  // Documents
  {
    name: "Confluence",
    logo: "https://api.iconify.design/logos/confluence.svg",
    category: "Documents",
    entities: ["Pages", "Comments"],
    available: false,
  },
  {
    name: "Coda",
    ...si("coda", "F46A54", "F46A54"),
    category: "Documents",
    entities: ["Docs", "Tables"],
    available: false,
  },
  {
    name: "Dropbox Paper",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Documents",
    entities: ["Docs", "Comments"],
    available: false,
  },
  {
    name: "Microsoft Word",
    ...si("microsoftword", "2B579A", "4B8BBE"),
    category: "Documents",
    entities: ["Documents", "Comments"],
    available: false,
  },
  {
    name: "Google Docs",
    ...si("googledocs", "4285F4", "4285F4"),
    category: "Documents",
    entities: ["Documents", "Comments"],
    available: false,
  },
  {
    name: "DocuSign",
    ...si("docusign", "FFCD00", "FFCD00"),
    category: "Documents",
    entities: ["Envelopes", "Signatures"],
    available: false,
  },

  // Development
  {
    name: "GitLab",
    logo: "https://api.iconify.design/logos/gitlab-icon.svg",
    category: "Development",
    entities: ["Issues", "Merge Requests"],
    available: false,
  },
  {
    name: "Bitbucket",
    logo: "https://api.iconify.design/logos/bitbucket.svg",
    category: "Development",
    entities: ["Issues", "Pull Requests"],
    available: false,
  },
  {
    name: "Sentry",
    logo: "https://api.iconify.design/logos/sentry-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/sentry.svg?color=%23ffffff",
    category: "Development",
    entities: ["Issues", "Alerts"],
    available: false,
  },
  {
    name: "Vercel",
    logo: "https://api.iconify.design/logos/vercel-icon.svg",
    logoDark: "https://api.iconify.design/simple-icons/vercel.svg?color=%23ffffff",
    category: "Development",
    entities: ["Deployments", "Comments"],
    available: false,
  },
  {
    name: "PagerDuty",
    ...si("pagerduty", "06AC38", "06AC38"),
    category: "Development",
    entities: ["Incidents", "Alerts"],
    available: false,
  },
  {
    name: "Datadog",
    logo: "https://api.iconify.design/logos/datadog.svg",
    category: "Development",
    entities: ["Alerts", "Monitors"],
    available: false,
  },
  {
    name: "LaunchDarkly",
    logo: "https://api.iconify.design/logos/launchdarkly-icon.svg",
    category: "Development",
    entities: ["Flags", "Changes"],
    available: false,
  },
  {
    name: "Supabase",
    logo: "https://api.iconify.design/logos/supabase-icon.svg",
    category: "Development",
    entities: ["Alerts", "Logs"],
    available: false,
  },
  {
    name: "Firebase",
    logo: "https://api.iconify.design/logos/firebase-icon.svg",
    category: "Development",
    entities: ["Alerts", "Analytics"],
    available: false,
  },

  // CRM
  {
    name: "Salesforce",
    logo: "https://api.iconify.design/logos/salesforce.svg",
    category: "CRM",
    entities: ["Leads", "Opportunities", "Tasks"],
    available: false,
  },
  {
    name: "HubSpot",
    ...si("hubspot", "FF7A59"),
    category: "CRM",
    entities: ["Contacts", "Deals", "Tasks"],
    available: false,
  },
  {
    name: "Attio",
    logo: "/assets/logo-attio.svg",
    logoDark: "/assets/logo-attio-dark.svg",
    category: "CRM",
    entities: ["Contacts", "Deals", "Tasks"],
    available: false,
  },
  {
    name: "Pipedrive",
    logo: "/assets/logo-pipedrive.svg",
    logoDark: "/assets/logo-pipedrive-dark.svg",
    category: "CRM",
    entities: ["Deals", "Activities"],
    available: false,
  },

  // Customer Support
  {
    name: "Zendesk",
    logo: "https://api.iconify.design/logos/zendesk-icon.svg",
    category: "Customer Support",
    entities: ["Tickets", "Comments"],
    available: false,
  },
  {
    name: "Intercom",
    logo: "https://api.iconify.design/logos/intercom-icon.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tickets"],
    available: false,
  },
  {
    name: "Front",
    logo: "https://api.iconify.design/logos/frontapp.svg",
    category: "Customer Support",
    entities: ["Conversations", "Tags"],
    available: false,
  },

  // Cloud Storage
  {
    name: "Dropbox",
    logo: "https://api.iconify.design/logos/dropbox.svg",
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    available: false,
  },
  {
    name: "OneDrive",
    ...si("microsoftonedrive", "0078D4", "2B88D8"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    available: false,
  },
  {
    name: "Box",
    ...si("box", "0061D5", "3B8DF0"),
    category: "Cloud Storage",
    entities: ["Files", "Comments"],
    available: false,
  },

  // Finance
  {
    name: "Stripe",
    ...si("stripe", "635BFF"),
    category: "Finance",
    entities: ["Payments", "Invoices"],
    available: false,
  },
  {
    name: "QuickBooks",
    ...si("quickbooks", "2CA01C", "2FBF4E"),
    category: "Finance",
    entities: ["Invoices", "Expenses"],
    available: false,
  },
  {
    name: "Xero",
    ...si("xero", "13B5EA", "13B5EA"),
    category: "Finance",
    entities: ["Invoices", "Bills"],
    available: false,
  },

  // HR
  {
    name: "Gusto",
    ...si("gusto", "F45D48", "F45D48"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
    available: false,
  },
  {
    name: "BambooHR",
    ...si("bamboo", "73C41D", "73C41D"),
    category: "HR",
    entities: ["Time Off", "Tasks"],
    available: false,
  },

  // Marketing
  {
    name: "Mailchimp",
    logo: "https://api.iconify.design/logos/mailchimp-freddie.svg",
    category: "Marketing",
    entities: ["Campaigns", "Reports"],
    available: false,
  },

  // Analytics
  {
    name: "Google Analytics",
    logo: "https://api.iconify.design/logos/google-analytics.svg",
    category: "Analytics",
    entities: ["Reports", "Alerts"],
    available: false,
  },
  {
    name: "Amplitude",
    logo: "https://api.iconify.design/logos/amplitude-icon.svg",
    category: "Analytics",
    entities: ["Reports", "Experiments"],
    available: false,
  },
  {
    name: "Mixpanel",
    ...si("mixpanel", "7856FF", "9B7FFF"),
    category: "Analytics",
    entities: ["Reports", "Alerts"],
    available: false,
  },
  {
    name: "PostHog",
    ...si("posthog", "F54E00", "F54E00"),
    category: "Analytics",
    entities: ["Insights", "Flags"],
    available: false,
  },

  // Notes
  {
    name: "Evernote",
    ...si("evernote", "00A82D", "00A82D"),
    category: "Notes",
    entities: ["Notes", "Notebooks"],
    available: false,
  },
  {
    name: "Apple Notes",
    ...si("apple", "000000", "ffffff"),
    category: "Notes",
    entities: ["Notes", "Folders"],
    available: false,
  },
  {
    name: "Obsidian",
    ...si("obsidian", "7C3AED", "A78BFA"),
    category: "Notes",
    entities: ["Notes", "Vaults"],
    available: false,
  },

  // Productivity
  {
    name: "Todoist",
    logo: "https://api.iconify.design/logos/todoist-icon.svg",
    category: "Productivity",
    entities: ["Tasks", "Projects"],
    available: false,
  },
  {
    name: "Airtable",
    ...si("airtable", "18BFFF", "18BFFF"),
    category: "Productivity",
    entities: ["Tasks", "Comments"],
    available: true,
  },
  {
    name: "Google Sheets",
    ...si("googlesheets", "34A853", "34A853"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
    available: false,
  },
  {
    name: "Microsoft Excel",
    ...si("microsoftexcel", "217346", "33AB67"),
    category: "Productivity",
    entities: ["Spreadsheets", "Comments"],
    available: false,
  },
  {
    name: "Fellow",
    logo: "/assets/logo-fellow.svg",
    logoDark: "/assets/logo-fellow-dark.svg",
    category: "Productivity",
    entities: ["Meeting Notes", "Action Items"],
    available: false,
  },
  {
    name: "Granola",
    logo: "/assets/logo-granola.png",
    category: "Productivity",
    entities: ["Meeting Notes", "Transcripts"],
    available: false,
  },
  {
    name: "Google Tasks",
    logo: "/assets/logo-google-tasks.svg",
    category: "Productivity",
    entities: ["Tasks", "Lists"],
    available: false,
  },
  {
    name: "Apple Reminders",
    ...si("apple", "000000", "ffffff"),
    category: "Productivity",
    entities: ["Reminders", "Lists"],
    available: false,
  },
  {
    name: "Typeform",
    logo: "/assets/logo-typeform.svg",
    logoDark: "/assets/logo-typeform-dark.svg",
    category: "Productivity",
    entities: ["Responses", "Forms"],
    available: false,
  },
  {
    name: "SurveyMonkey",
    ...si("surveymonkey", "00BF6F", "00BF6F"),
    category: "Productivity",
    entities: ["Responses", "Surveys"],
    available: false,
  },

  // Automation
  {
    name: "Zapier",
    ...si("zapier", "FF4A00", "FF4A00"),
    category: "Automation",
    entities: ["Zaps", "Tasks"],
    available: false,
  },
  {
    name: "Make",
    ...si("make", "6D00CC", "9B4DFF"),
    category: "Automation",
    entities: ["Scenarios", "Operations"],
    available: false,
  },
  {
    name: "n8n",
    ...si("n8n", "EA4B71", "EA4B71"),
    category: "Automation",
    entities: ["Workflows", "Executions"],
    available: false,
  },

  // E-commerce
  {
    name: "Shopify",
    logo: "https://api.iconify.design/logos/shopify.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
    available: false,
  },
  {
    name: "WooCommerce",
    logo: "https://api.iconify.design/logos/woocommerce-icon.svg",
    category: "E-commerce",
    entities: ["Orders", "Products"],
    available: false,
  },

  // Cloud
  {
    name: "AWS",
    logo: "https://api.iconify.design/logos/aws.svg",
    logoDark: "https://api.iconify.design/simple-icons/amazonaws.svg?color=%23FF9900",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
    available: false,
  },
  {
    name: "Google Cloud",
    logo: "https://api.iconify.design/logos/google-cloud.svg",
    category: "Cloud",
    entities: ["Alerts", "Deployments"],
    available: false,
  },
  {
    name: "Cloudflare",
    logo: "https://api.iconify.design/logos/cloudflare-icon.svg",
    category: "Cloud",
    entities: ["Workers", "Analytics"],
    available: false,
  },

  // Security
  {
    name: "1Password",
    ...si("1password", "0094F5", "3DB4FF"),
    category: "Security",
    entities: ["Events", "Alerts"],
    available: false,
  },
  {
    name: "Okta",
    ...si("okta", "007DC1", "2EAADC"),
    category: "Security",
    entities: ["Events", "Users"],
    available: false,
  },

  // Product
  {
    name: "Productboard",
    logo: "https://api.iconify.design/logos/productboard-icon.svg",
    category: "Product",
    entities: ["Features", "Insights"],
    available: false,
  },
];

export const CATEGORIES = [
  ...new Set(CONNECTIONS.map((c) => c.category)),
].sort();
