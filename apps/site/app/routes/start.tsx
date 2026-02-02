import { useEffect } from "react";

import { Stack, Text } from "@mantine/core";

import type { Route } from "./+types/home";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Try Plot",
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
      <Text fw={700}>We'd love to have you!</Text>
      <Text>
        Plot is in private trial with select teams, working closely with early
        users. If you want hands-on access now, let us know and we'll reach out
        when a spot opens.
      </Text>
      <Text>
        Not ready to dive in yet? You can also just sign up to be notified when
        Plot is available to everyone.
      </Text>
      <Text fw={700}>Either way, we're glad you're here.</Text>
      <iframe
        data-tally-src="https://tally.so/embed/3EvdlA?alignLeft=1&hideTitle=1&dynamicHeight=1"
        loading="lazy"
        width="100%"
        height="1101"
        frameBorder={0}
        marginHeight={0}
        marginWidth={0}
        title="Try Plot"
      ></iframe>
    </Stack>
  );
}
