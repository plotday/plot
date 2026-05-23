import { Connector, type Channel, type Authorization, type AuthToken } from "@plotday/twister";

export class LinkedIn extends Connector<LinkedIn> {
  build() {
    return {};
  }

  async getChannels(_auth: Authorization | null, _token: AuthToken | null): Promise<Channel[]> {
    return [];
  }

  async onChannelEnabled(_channel: Channel): Promise<void> {
    // Implementation in Task 4.2
  }

  async onChannelDisabled(_channel: Channel): Promise<void> {
    // Implementation in Task 4.2
  }
}

export default LinkedIn;
