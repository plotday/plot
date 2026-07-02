import { useState } from "react";

import { useAuth, useClerk } from "@clerk/react-router";

import {
  Alert,
  Button,
  Container,
  List,
  Stack,
  Text,
  Title,
  Checkbox,
} from "@mantine/core";

import type { Route } from "./+types/account.delete";
import { cloudflareContext } from "../lib/cloudflare-context";

export function meta(_: Route.MetaArgs) {
  return [
    {
      title: "Delete Account | Plot",
    },
  ];
}

export async function loader({ context }: Route.LoaderArgs) {
  return {
    apiUrl: context.get(cloudflareContext).env.API_ROOT || "https://api.plot.day",
  };
}

export default function DeleteAccount({ loaderData }: Route.ComponentProps) {
  const { isSignedIn, isLoaded, getToken } = useAuth();
  const { signOut } = useClerk();
  const [confirmed, setConfirmed] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();

    if (!confirmed) {
      setError(
        "Please confirm that you understand this action cannot be undone"
      );
      return;
    }

    setIsLoading(true);
    setError(null);

    try {
      const token = await getToken();

      if (!token) {
        throw new Error("You must be signed in to delete your account");
      }

      // Call the API to delete the account
      const response = await fetch(`${loaderData.apiUrl}/app/account`, {
        method: "DELETE",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
      });

      if (!response.ok) {
        throw new Error("Failed to delete account. Please try again.");
      }

      // Sign out and show success
      await signOut();
      setSuccess(true);
    } catch (err) {
      console.error("Error deleting account:", err);
      setError(err instanceof Error ? err.message : "Failed to delete account");
      setIsLoading(false);
    }
  };

  if (!isLoaded) return null;

  if (success) {
    return (
      <Container size="sm" mt="xl">
        <Stack gap="md">
          <Title order={2}>Account Deletion Requested</Title>

          <Alert color="green" title="Success">
            Your account has been successfully deactivated. You will receive a
            confirmation email shortly.
          </Alert>

          <Text>
            Your account and all associated data will be permanently deleted
            within 14 days. If you change your mind, please contact us at{" "}
            <a href="mailto:team@plot.day">team@plot.day</a> within this period
            to request account recovery.
          </Text>

          <Button component="a" href="/" variant="default">
            Return to Home
          </Button>
        </Stack>
      </Container>
    );
  }

  return (
    <Container size="sm" mt="xl">
      <Stack gap="md">
        <Title order={2}>Delete Your Plot Account</Title>

        <Alert color="red" title="Warning: This action cannot be undone">
          Deleting your account will permanently remove all your data from Plot.
        </Alert>

        <Text fw={600}>When you delete your account, the following will occur:</Text>

        <List withPadding>
          <List.Item>
            Your account will be immediately deactivated and you will no longer
            be able to sign in
          </List.Item>
          <List.Item>
            Any active subscriptions will be automatically canceled (no refund)
          </List.Item>
          <List.Item>
            Your data will be retained for 14 days to allow for account recovery
          </List.Item>
          <List.Item>
            After 14 days, all your data including tasks, messages, priorities,
            and settings will be permanently deleted
          </List.Item>
          <List.Item>
            Some data may be retained for legal or accounting purposes (e.g.,
            transaction records)
          </List.Item>
        </List>

        <Text size="sm" c="dimmed">
          If you wish to recover your account within the 14-day period, please
          contact us at <a href="mailto:team@plot.day">team@plot.day</a>.
        </Text>

        {!isSignedIn ? (
          <Button
            component="a"
            href="/signin?returnTo=/account/delete"
            color="red"
          >
            Sign in to continue
          </Button>
        ) : (
          <form onSubmit={handleSubmit}>
            <Stack gap="md">
              <Checkbox
                label="I understand that this action cannot be undone and my data will be permanently deleted after 14 days"
                checked={confirmed}
                onChange={(e) => setConfirmed(e.currentTarget.checked)}
                disabled={isLoading}
              />

              {error && (
                <Alert color="red" title="Error">
                  {error}
                </Alert>
              )}

              <Button type="submit" loading={isLoading} color="red">
                Delete My Account
              </Button>

              <Button
                component="a"
                href="/"
                variant="subtle"
                disabled={isLoading}
              >
                Cancel
              </Button>
            </Stack>
          </form>
        )}
      </Stack>
    </Container>
  );
}
