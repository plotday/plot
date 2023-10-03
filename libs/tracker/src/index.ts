import { createInstance } from "@amplitude/analytics-node";
import UaParser from "ua-parser-js";

import type { EventOptions, IdentifyProperties } from "./ampli";
import { Ampli } from "./ampli";
import { Fetch } from "./transport";

export type Tracker = Ampli;

export const init = (apiKey: string, appVersion: string, headers: Headers) => {
  const instance = createInstance();
  instance.init(apiKey, {
    transportProvider: new Fetch(),
  });
  const tracker = new Ampli();
  tracker.load({ client: { instance } });

  let baseOptions: EventOptions = {
    platform: "Web",
    app_version: appVersion,
  };
  const ip = headers.get("CF-Connecting-IP");
  if (ip) {
    baseOptions = { ...baseOptions, ip };
  }
  const language = headers.get("Accept-Language");
  if (language) {
    baseOptions = { ...baseOptions, language };
  }
  const uaString = headers.get("User-Agent");
  if (uaString) {
    baseOptions = { ...baseOptions, user_agent: uaString };
    const ua = new UaParser(uaString);
    baseOptions = {
      ...baseOptions,
      os_name: ua.getBrowser().name,
      os_version: ua.getBrowser().version,
      device_brand: ua.getOS().name,
      device_manufacturer: ua.getDevice().vendor,
      device_model: ua.getDevice().model,
    };
  }

  const originalIdentify = tracker.identify;
  tracker.identify = (
    userId: string | undefined,
    properties?: IdentifyProperties,
    options?: EventOptions
  ) => {
    return originalIdentify.bind(tracker)(userId, properties, {
      ...baseOptions,
      ...options,
    });
  };

  return tracker;
};
