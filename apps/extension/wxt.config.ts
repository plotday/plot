import { defineConfig } from "wxt";

export default defineConfig({
  manifest: {
    name: "Save to Plot",
    short_name: "Plot",
    description:
      "Create a thread in Plot for the current page. Click a second time to open in Plot.",
    permissions: ["activeTab", "storage", "scripting"],
    host_permissions: [
      "https://app.plot.day/*",
      "https://plot.day/*",
      "http://localhost:8788/*",
      "http://localhost:5173/*",
    ],
    action: {
      default_title: "Save this page to Plot",
      default_icon: {
        "16": "icon/16.png",
        "32": "icon/32.png",
        "48": "icon/48.png",
        "128": "icon/128.png",
      },
    },
    icons: {
      "16": "icon/16.png",
      "32": "icon/32.png",
      "48": "icon/48.png",
      "128": "icon/128.png",
    },
  },
});
