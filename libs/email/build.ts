import { render } from "@react-email/render";
import { writeFileSync, mkdirSync } from "fs";
import { join } from "path";
import EmailConfirmation from "./emails/email-confirmation";
import PasswordReset from "./emails/password-reset";
import EmailChange from "./emails/email-change";

// Create email-templates directory if it doesn't exist
const distDir = join(__dirname, "../db/supabase/email-templates");
mkdirSync(distDir, { recursive: true });

// Template configurations
const templates = [
  {
    name: "confirmation",
    component: EmailConfirmation,
    filename: "email-confirmation.html",
  },
  {
    name: "recovery",
    component: PasswordReset,
    filename: "password-reset.html",
  },
  {
    name: "email_change",
    component: EmailChange,
    filename: "email-change.html",
  },
];

// Generate HTML for each template
async function buildTemplates() {
  for (const template of templates) {
    console.log(`Generating ${template.name} template...`);

    const html = await render(template.component(), {
      pretty: true,
    });

    const outputPath = join(distDir, template.filename);
    writeFileSync(outputPath, html, "utf-8");

    console.log(`✓ Generated ${template.filename}`);
  }

  console.log("\nAll email templates generated successfully!");
  console.log(`Output directory: ${distDir}`);
}

buildTemplates().catch((error) => {
  console.error("Error building templates:", error);
  process.exit(1);
});
