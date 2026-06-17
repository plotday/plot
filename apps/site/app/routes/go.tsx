import { useEffect, useRef, useState } from "react";

import {
  Anchor,
  Box,
  Button,
  Container,
  Group,
  Stack,
  Text,
  Title,
} from "@mantine/core";

import { IconBrandLinkedin } from "@tabler/icons-react";
import { Link } from "react-router";
import { mergeMeta } from "~/lib/meta";

import type { Route } from "./+types/go";
import classes from "./go.module.css";

const CAL_SCRIPT = `(function (C, A, L) { let p = function (a, ar) { a.q.push(ar); }; let d = C.document; C.Cal = C.Cal || function () { let cal = C.Cal; let ar = arguments; if (!cal.loaded) { cal.ns = {}; cal.q = cal.q || []; d.head.appendChild(d.createElement("script")).src = A; cal.loaded = true; } if (ar[0] === L) { const api = function () { p(api, arguments); }; const namespace = ar[1]; api.q = api.q || []; if(typeof namespace === "string"){cal.ns[namespace] = cal.ns[namespace] || api;p(cal.ns[namespace], ar);p(cal, ["initNamespace", namespace]);} else p(cal, ar); return;} p(cal, ar); }; })(window, "https://app.cal.com/embed/embed.js", "init");
Cal("init", "onboarding", {origin:"https://app.cal.com"});
Cal.ns.onboarding("ui", {"cssVarsPerTheme":{"light":{"cal-brand":"#23986f"},"dark":{"cal-brand":"#23986f"}},"hideEventTypeDetails":false,"layout":"month_view"});`;

export function meta(_: Route.MetaArgs) {
  return mergeMeta([
    { title: "Get started with Plot" },
    {
      name: "description",
      content:
        "Join a personal onboarding session with Kris and Beth and get set up in Plot together.",
    },
    { property: "og:title", content: "Get started with Plot" },
    {
      property: "og:description",
      content:
        "Join a personal onboarding session with Kris and Beth and get set up in Plot together.",
    },
  ]);
}

export default function Go() {
  const inPageCtaRef = useRef<HTMLButtonElement>(null);
  const [stickyHidden, setStickyHidden] = useState(false);

  useEffect(() => {
    if (typeof window === "undefined") return;
    if ((window as unknown as { Cal?: unknown }).Cal) return;
    const script = document.createElement("script");
    script.type = "text/javascript";
    script.text = CAL_SCRIPT;
    document.head.appendChild(script);
  }, []);

  useEffect(() => {
    const target = inPageCtaRef.current;
    if (!target) return;
    const observer = new IntersectionObserver(
      ([entry]) => setStickyHidden(entry.isIntersecting),
      { threshold: 0.6 },
    );
    observer.observe(target);
    return () => observer.disconnect();
  }, []);

  return (
    <Stack gap={0}>
      <Box className={classes.heroSection} pt={80} pb={60}>
        <div className={classes.heroGlow} />
        <Container size="sm">
          <Stack gap="xl" align="center" ta="center">
            <Text className={classes.heroEyebrow}>A personal invitation</Text>
            <Title order={1} className={classes.heroTitle}>
              <Text span inherit variant="gradient">
                A better way to collaborate
              </Text>
            </Title>
            <Text className={classes.lead}>
              Something&rsquo;s gone sideways with modern collaboration. The
              tools that should help us connect end up keeping us reactive,
              fragmented, and behind on the conversations that actually matter.
            </Text>
            <Text className={classes.body}>
              We&rsquo;re building a different way. Plot pulls together every
              conversation that needs a thoughtful reply — email, chat, and
              threads from the tools you use — and organizes them by project and
              priority. You decide when to engage; the rest of your day is yours
              to make real progress on your best work.
            </Text>
            <Text className={classes.body}>
              We&rsquo;d love for you to give it a try! We&rsquo;re running
              personal sessions to get you off to a strong start by setting you
              up in Plot together and showing you the ropes. While we hope to be
              immediately helpful for you, there&rsquo;s no commitment to
              continue beyond the session. We&rsquo;re simply grateful for the
              shared learning.
            </Text>
            <Text className={classes.body}>
              Join us in building a better way to collaborate.
            </Text>
            <Text className={classes.signoff}>Kris and Beth</Text>

            <div className={classes.divider} />

            <Box className={classes.bios} mt="md">
              <div className={classes.bioCard}>
                <img
                  src="/assets/headshot-kris.jpg"
                  alt="Kris"
                  className={classes.headshot}
                />
                <div>
                  <div className={classes.bioName}>
                    <Group gap="sm" align="center">
                      Kris Braun
                      <Anchor
                        href="https://www.linkedin.com/in/krisbraun/"
                        title="Kris' LinkedIn"
                        display="inline-flex"
                      >
                        <IconBrandLinkedin size={20} />
                      </Anchor>
                    </Group>
                  </div>
                  <Text className={classes.bioText}>
                    Kris created Plot while building companies and causes as a
                    way to amplify the momentum required to start something new.
                  </Text>
                </div>
              </div>
              <div className={classes.bioCard}>
                <img
                  src="/assets/headshot-beth.jpg"
                  alt="Beth"
                  className={classes.headshot}
                />
                <div>
                  <div className={classes.bioName}>Beth Round</div>
                  <Text className={classes.bioText}>
                    Beth scaled operations in an organization growing from five
                    to over forty cities worldwide, learning to cultivate just
                    the right amount of order from chaos.
                  </Text>
                </div>
              </div>
            </Box>
          </Stack>
        </Container>
      </Box>

      <Box className={classes.bookSection} pt={64} pb={80}>
        <Container size="sm">
          <Stack gap="lg" align="center" ta="center">
            <Title order={2} className={classes.bookTitle}>
              Let's do this!
            </Title>
            <Text className={classes.body} ta="center">
              Find a slot that works for you.
            </Text>
            <Button
              ref={inPageCtaRef}
              size="xl"
              className={classes.bookCta}
              data-cal-link="team/plot/onboarding"
              data-cal-namespace="onboarding"
              data-cal-config='{"layout":"month_view","useSlotsViewOnSmallScreen":"true","theme":"auto"}'
            >
              Pick a time
            </Button>
          </Stack>
        </Container>
      </Box>

      <Box className={classes.learnSection} pt={48} pb={80}>
        <Container size="sm">
          <Stack gap="md" align="center" ta="center">
            <Anchor component={Link} to="/" className={classes.learnLink}>
              Learn more about Plot &rarr;
            </Anchor>
          </Stack>
        </Container>
      </Box>

      <div
        className={`${classes.stickyFooter} ${stickyHidden ? classes.stickyFooterHidden : ""}`}
        aria-hidden={stickyHidden}
      >
        <Container size="sm" className={classes.stickyFooterInner}>
          <Button
            size="md"
            className={classes.bookCta}
            tabIndex={stickyHidden ? -1 : 0}
            data-cal-link="team/plot/onboarding"
            data-cal-namespace="onboarding"
            data-cal-config='{"layout":"month_view","useSlotsViewOnSmallScreen":"true","theme":"auto"}'
          >
            Pick a time
          </Button>
        </Container>
      </div>
    </Stack>
  );
}
