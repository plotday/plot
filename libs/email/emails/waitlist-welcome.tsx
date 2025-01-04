import { Html } from "@react-email/html";
import { Text } from "@react-email/text";

export default function Email() {
  return (
    <Html>
      <Text>Welcome to the waitlist!</Text>
      <Text>We'll be in touch soon.</Text>
    </Html>
  );
}
