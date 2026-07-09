/* SPEC:
Every morning, post a thread with today's weather forecast for my city so I
can plan the day. One thread per day, titled with the date.
*/
import { Twist, type ToolBuilder } from "@plotday/twister";
import { Network } from "@plotday/twister/tools/network";
import { Plot, ThreadAccess } from "@plotday/twister/tools/plot";

export default class WeatherDigest extends Twist<WeatherDigest> {
  build(build: ToolBuilder) {
    return {
      plot: build(Plot, {
        thread: { access: ThreadAccess.Create },
      }),
      network: build(Network, {
        urls: ["https://api.open-meteo.com/*"],
      }),
    };
  }

  async activate() {
    await this.scheduleRecurring(
      "morning-digest",
      await this.callback(this.postDigest),
      { intervalMs: 24 * 60 * 60 * 1000 }
    );
  }

  async postDigest(): Promise<void> {
    const response = await fetch(
      "https://api.open-meteo.com/v1/forecast?latitude=43.65&longitude=-79.38&daily=temperature_2m_max,precipitation_probability_mean&timezone=auto&forecast_days=1"
    );
    if (!response.ok) {
      return;
    }
    const data = (await response.json()) as {
      daily: {
        temperature_2m_max: number[];
        precipitation_probability_mean: number[];
      };
    };

    const today = new Date().toISOString().slice(0, 10);
    await this.tools.plot.createThread({
      title: `Weather for ${today}`,
      notes: [
        {
          content: `High of ${data.daily.temperature_2m_max[0]}°C, ${data.daily.precipitation_probability_mean[0]}% chance of rain.`,
        },
      ],
    });
  }
}
