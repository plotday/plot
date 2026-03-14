import { useState, useEffect, useCallback } from "react";

import { useAuth } from "@clerk/react-router";
import { useParams, useSearchParams } from "react-router";

import {
  ActionIcon,
  Alert,
  Badge,
  Box,
  Button,
  Container,
  Group,
  Loader,
  Select,
  Stack,
  Switch,
  Text,
  TextInput,
  Title,
} from "@mantine/core";

import { IconTrash } from "@tabler/icons-react";

import type { Route } from "./+types/organization.$id";
import classes from "./organization.$id.module.css";

type OrgDetails = {
  id: string;
  name: string;
  created_at: string;
  members: {
    userId: string;
    role: string;
    email: string;
    name: string | null;
    joinedAt: string;
  }[];
  domains: {
    id: string;
    name: string;
    autoJoin: boolean;
  }[];
  subscription: {
    plan: string;
    status: string;
    billingCycleStart: string;
    billingCycleEnd: string;
  } | null;
  invitations: {
    id: string;
    email: string;
    role: string;
    createdAt: string;
  }[];
};

export function meta(_: Route.MetaArgs) {
  return [
    { title: "Organization | Plot" },
    { name: "description", content: "Manage your organization." },
  ];
}

export async function loader({ context }: Route.LoaderArgs) {
  return {
    apiUrl: context.cloudflare.env.API_ROOT || "https://api.plot.day",
  };
}

export default function OrganizationPage({
  loaderData,
}: Route.ComponentProps) {
  const { isSignedIn, isLoaded, getToken } = useAuth();
  const { id: orgId } = useParams();
  const [searchParams] = useSearchParams();
  const [org, setOrg] = useState<OrgDetails | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [actionLoading, setActionLoading] = useState(false);
  const [editName, setEditName] = useState("");
  const [inviteEmail, setInviteEmail] = useState("");
  const [inviteRole, setInviteRole] = useState<string>("member");

  const isSuccess = searchParams.get("success") === "true";

  const apiCall = useCallback(
    async (path: string, options?: RequestInit) => {
      const token = await getToken();
      return fetch(`${loaderData.apiUrl}${path}`, {
        ...options,
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
          ...options?.headers,
        },
      });
    },
    [getToken, loaderData.apiUrl]
  );

  const fetchOrg = useCallback(async () => {
    try {
      const res = await apiCall(`/app/organization/${orgId}`);
      if (res.ok) {
        const data = (await res.json()) as OrgDetails;
        setOrg(data);
        setEditName(data.name);
      } else if (res.status === 403) {
        setError("You don't have admin access to this organization.");
      } else {
        setError("Failed to load organization.");
      }
    } catch {
      setError("Failed to load organization.");
    } finally {
      setLoading(false);
    }
  }, [apiCall, orgId]);

  useEffect(() => {
    if (!isSignedIn) {
      setLoading(false);
      return;
    }
    fetchOrg();
  }, [isSignedIn, fetchOrg]);

  const handleUpdateName = async () => {
    if (!editName.trim() || editName === org?.name) return;
    setActionLoading(true);
    try {
      const res = await apiCall(`/app/organization/${orgId}`, {
        method: "PATCH",
        body: JSON.stringify({ name: editName.trim() }),
      });
      if (res.ok) {
        await fetchOrg();
      } else {
        const data = (await res.json()) as { error?: string };
        setError(data.error || "Failed to update name");
      }
    } catch {
      setError("Failed to update name");
    } finally {
      setActionLoading(false);
    }
  };

  const handleInvite = async () => {
    if (!inviteEmail.trim()) return;
    setActionLoading(true);
    setError(null);
    try {
      const res = await apiCall(`/app/organization/${orgId}/members`, {
        method: "POST",
        body: JSON.stringify({ email: inviteEmail.trim(), role: inviteRole }),
      });
      if (res.ok) {
        setInviteEmail("");
        await fetchOrg();
      } else {
        const data = (await res.json()) as { error?: string };
        setError(data.error || "Failed to add member");
      }
    } catch {
      setError("Failed to add member");
    } finally {
      setActionLoading(false);
    }
  };

  const handleRemoveMember = async (userId: string) => {
    setActionLoading(true);
    try {
      await apiCall(`/app/organization/${orgId}/members/${userId}`, {
        method: "DELETE",
      });
      await fetchOrg();
    } catch {
      setError("Failed to remove member");
    } finally {
      setActionLoading(false);
    }
  };

  const handleChangeRole = async (userId: string, role: string) => {
    setActionLoading(true);
    try {
      const res = await apiCall(`/app/organization/${orgId}/members/${userId}`, {
        method: "PATCH",
        body: JSON.stringify({ role }),
      });
      if (!res.ok) {
        const data = (await res.json()) as { error?: string };
        setError(data.error || "Failed to change role");
      }
      await fetchOrg();
    } catch {
      setError("Failed to change role");
    } finally {
      setActionLoading(false);
    }
  };

  const handleToggleAutoJoin = async (domainId: string, autoJoin: boolean) => {
    try {
      await apiCall(`/app/organization/${orgId}/domains/${domainId}`, {
        method: "PATCH",
        body: JSON.stringify({ autoJoin }),
      });
      await fetchOrg();
    } catch {
      setError("Failed to update domain");
    }
  };

  const handleRemoveDomain = async (domainId: string) => {
    try {
      await apiCall(`/app/organization/${orgId}/domains/${domainId}`, {
        method: "DELETE",
      });
      await fetchOrg();
    } catch {
      setError("Failed to remove domain");
    }
  };

  const handlePortal = async () => {
    setActionLoading(true);
    try {
      const res = await apiCall(
        `/app/organization/${orgId}/upgrade/portal`,
        { method: "POST" }
      );
      if (res.ok) {
        const { url } = (await res.json()) as { url: string };
        window.location.href = url;
      } else {
        const data = (await res.json()) as { error?: string };
        setError(data.error || "Failed to open billing portal");
        setActionLoading(false);
      }
    } catch {
      setError("Failed to open billing portal");
      setActionLoading(false);
    }
  };

  if (!isLoaded) return null;

  if (!isSignedIn) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Text c="dimmed" ta="center">
          Sign in to manage your organization.
        </Text>
      </Container>
    );
  }

  if (loading) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        <Stack align="center" gap="md">
          <Loader />
          <Text c="dimmed">Loading organization...</Text>
        </Stack>
      </Container>
    );
  }

  if (!org) {
    return (
      <Container size="sm" mt="xl" mb="xl">
        {error && (
          <Alert color="red" title="Error">
            {error}
          </Alert>
        )}
      </Container>
    );
  }

  return (
    <Container size="sm" mt="xl" mb="xl">
      <Stack gap="lg">
        <Title order={2}>{org.name}</Title>

        {isSuccess && (
          <Alert color="green" title="Subscription active" mb="md">
            Your Business subscription is now active.
          </Alert>
        )}

        {error && (
          <Alert color="red" title="Error" mb="md" withCloseButton onClose={() => setError(null)}>
            {error}
          </Alert>
        )}

        {/* Name */}
        <Box className={classes.section}>
          <Stack gap="sm">
            <Text fw={600}>Organization name</Text>
            <Group>
              <TextInput
                value={editName}
                onChange={(e) => setEditName(e.currentTarget.value)}
                style={{ flex: 1 }}
              />
              <Button
                onClick={handleUpdateName}
                loading={actionLoading}
                disabled={!editName.trim() || editName === org.name}
                size="sm"
              >
                Save
              </Button>
            </Group>
          </Stack>
        </Box>

        {/* Subscription */}
        <Box className={classes.section}>
          <Stack gap="sm">
            <Group justify="space-between">
              <Text fw={600}>Subscription</Text>
              {org.subscription && (
                <Badge
                  color={org.subscription.status === "active" ? "green" : "yellow"}
                  variant="light"
                >
                  {org.subscription.plan} - {org.subscription.status}
                </Badge>
              )}
            </Group>
            {org.subscription?.billingCycleEnd && (
              <Text c="dimmed" size="sm">
                Current period ends{" "}
                {new Date(org.subscription.billingCycleEnd).toLocaleDateString()}
              </Text>
            )}
            <Button onClick={handlePortal} loading={actionLoading} variant="outline" size="sm">
              Manage billing
            </Button>
          </Stack>
        </Box>

        {/* Members */}
        <Box className={classes.section}>
          <Stack gap="sm">
            <Text fw={600}>Members ({org.members.length})</Text>
            {org.members.map((m) => (
              <Box key={m.userId} className={classes.memberRow}>
                <Box className={classes.memberInfo}>
                  <Text size="sm" fw={500}>
                    {m.name || m.email}
                  </Text>
                  {m.name && (
                    <Text size="xs" c="dimmed">
                      {m.email}
                    </Text>
                  )}
                </Box>
                <Box className={classes.memberActions}>
                  <Select
                    value={m.role}
                    onChange={(v) => v && handleChangeRole(m.userId, v)}
                    data={[
                      { value: "admin", label: "Admin" },
                      { value: "member", label: "Member" },
                    ]}
                    size="xs"
                    w={110}
                  />
                  <ActionIcon
                    variant="subtle"
                    color="red"
                    size="sm"
                    onClick={() => handleRemoveMember(m.userId)}
                  >
                    <IconTrash size={14} />
                  </ActionIcon>
                </Box>
              </Box>
            ))}

            {/* Pending invitations */}
            {org.invitations.length > 0 && (
              <>
                <Text size="sm" c="dimmed" mt="xs">
                  Pending invitations
                </Text>
                {org.invitations.map((inv) => (
                  <Box key={inv.id} className={classes.invitationRow}>
                    <Box className={classes.memberInfo}>
                      <Text size="sm">{inv.email}</Text>
                      <Text size="xs" c="dimmed">
                        Invited as {inv.role}
                      </Text>
                    </Box>
                    <Badge variant="light" color="yellow" size="sm">
                      Pending
                    </Badge>
                  </Box>
                ))}
              </>
            )}

            {/* Add member */}
            <Group mt="xs">
              <TextInput
                placeholder="Email address"
                value={inviteEmail}
                onChange={(e) => setInviteEmail(e.currentTarget.value)}
                size="sm"
                style={{ flex: 1 }}
              />
              <Select
                value={inviteRole}
                onChange={(v) => v && setInviteRole(v)}
                data={[
                  { value: "member", label: "Member" },
                  { value: "admin", label: "Admin" },
                ]}
                size="sm"
                w={110}
              />
              <Button onClick={handleInvite} loading={actionLoading} size="sm">
                Add
              </Button>
            </Group>
          </Stack>
        </Box>

        {/* Domains */}
        <Box className={classes.section}>
          <Stack gap="sm">
            <Text fw={600}>Domains</Text>
            {org.domains.length === 0 && (
              <Text size="sm" c="dimmed">
                No domains linked.
              </Text>
            )}
            {org.domains.map((d) => (
              <Box key={d.id} className={classes.domainRow}>
                <Text size="sm">{d.name}</Text>
                <Group gap="xs">
                  <Switch
                    label="Auto-join"
                    checked={d.autoJoin}
                    onChange={(e) =>
                      handleToggleAutoJoin(d.id, e.currentTarget.checked)
                    }
                    size="xs"
                  />
                  <ActionIcon
                    variant="subtle"
                    color="red"
                    size="sm"
                    onClick={() => handleRemoveDomain(d.id)}
                  >
                    <IconTrash size={14} />
                  </ActionIcon>
                </Group>
              </Box>
            ))}
          </Stack>
        </Box>
      </Stack>
    </Container>
  );
}
