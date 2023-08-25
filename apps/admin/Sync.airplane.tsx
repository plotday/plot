import { Heading, Stack, Table } from "@airplane/views";
import airplane from "airplane";

const Sync = () => {
  return (
    <Stack spacing="lg">
      <Stack spacing={0}>
        <Heading>Sync Dashboard</Heading>
      </Stack>
      <Table
        title="Sync"
        task="view_sync_admin"
        rowID="account_id"
        columns={[
          { label: "Email", accessor: "email", width: 300 },
          { label: "Provider", accessor: "provider", width: 100 },
          {
            label: "Calendar ID",
            accessor: "calendar_provider_id",
            width: 100,
          },
          { label: "Events", accessor: "event_count", width: 80 },
          {
            label: "Synced at",
            accessor: "synced_at",
            type: "datetime",
            width: 200,
          },
          {
            label: "Last full sync",
            accessor: "full_sync_at",
            type: "datetime",
            width: 200,
          },
          { label: "Duration", accessor: "sync_seconds", width: 80 },
          { label: "Error", accessor: "synced_error" },
          {
            label: "First sync",
            accessor: "first_synced_at",
            type: "datetime",
          },
        ]}
        rowActions={{ slug: "manual_sync", label: "Full resync" }}
      />
    </Stack>
  );
};

export default airplane.view(
  {
    slug: "sync",
    name: "Sync",
  },
  Sync
);
