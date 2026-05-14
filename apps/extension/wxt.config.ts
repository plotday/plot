import { defineConfig } from "wxt";

export default defineConfig({
  manifest: {
    name: "Plot — Save to your day",
    short_name: "Plot",
    description:
      "Capture the current page into Plot in one click. Auto-filed to the best priority.",
    permissions: ["activeTab", "storage", "scripting"],
    host_permissions: [
      "https://app.plot.day/*",
      "http://localhost:8788/*",
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
