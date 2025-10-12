import { useEffect } from "react";

import { Stack, Text } from "@mantine/core";

import type { Route } from "./+types/home";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Get Started | Plot",
    },
  ];
}

export default function GetStarted() {
  // The code below will load the embed
  useEffect(() => {
    const widgetScriptSrc = "https://tally.so/widgets/embed.js";

    const load = () => {
      // Load Tally embeds
      if (typeof globalThis.Tally !== "undefined") {
        globalThis.Tally.loadEmbeds();
        return;
      }

      // Fallback if window.Tally is not available
      document
        .querySelectorAll("iframe[data-tally-src]:not([src])")
        .forEach((iframeEl) => {
          iframeEl.src = iframeEl.dataset.tallySrc;
        });
    };

    // If Tally is already loaded, load the embeds
    if (typeof globalThis.Tally !== "undefined") {
      load();
      return;
    }

    // If the Tally widget script is not loaded yet, load it
    if (document.querySelector(`script[src="${widgetScriptSrc}"]`) === null) {
      const script = document.createElement("script");
      script.src = widgetScriptSrc;
      script.onload = load;
      script.onerror = load;
      document.body.appendChild(script);
      return;
    }
  }, []);

  return (
    <Stack m={24} mt={0}>
      <Text>
        We're committed to seeing you make meaningful change to your days,
        weeks, and years!
      </Text>
      <Text>
        While in the future 🤖 we expect Plot to guide you to that impact on
        your own, for now we're personally onboarding everyone to get it right.
      </Text>
      <iframe
        data-tally-src="https://tally.so/embed/3EvdlA?alignLeft=1&hideTitle=1&dynamicHeight=1"
        loading="lazy"
        width="100%"
        height="1101"
        frameBorder={0}
        marginHeight={0}
        marginWidth={0}
        title="Get Started | Plot"
      ></iframe>
    </Stack>
  );
}
