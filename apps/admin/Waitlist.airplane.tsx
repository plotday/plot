import { Heading, Link, Stack, Table } from "@airplane/views";
import airplane from "airplane";

const TableLink = ({ value }) => {
  return <Link href={value}>🔗</Link>;
};

const Waitlist = () => {
  return (
    <Stack spacing="lg">
      <Stack spacing={0}>
        <Heading>Waitlist</Heading>
      </Stack>
      <Table
        title="Waitlist"
        task="view_waitlist"
        outputTransform={(data) =>
          data.map((d: any) => ({
            ...d,
            sync_accounts: d.sync_accounts?.join?.(", "),
            check_url: `https://plot.day/check?email=${encodeURIComponent(
              d.email
            )}`,
          }))
        }
        columns={[
          {
            label: "Email",
            accessor: "email",
            type: "string",
            width: 200,
          },
          {
            label: "Signed up",
            accessor: "created_at",
            type: "datetime",
            width: 200,
          },
          {
            label: "Status",
            accessor: "status",
            type: "string",
            width: 150,
          },
          {
            label: "Events",
            accessor: "event_count",
            type: "number",
            width: 100,
          },
          {
            label: "Check Link",
            accessor: "check_url",
            type: "string",
            width: 100,
            Component: TableLink,
          },
          {
            label: "Accounts checked",
            accessor: "sync_accounts",
            type: "string",
            width: 400,
          },
          {
            label: "Error",
            accessor: "sync_error",
            type: "string",
            width: 400,
          },
          {
            label: "Provider",
            accessor: "provider",
            type: "string",
            width: 100,
          },
          {
            label: "Invitation used",
            accessor: "invitation",
            type: "string",
            width: 150,
          },
        ]}
      />
    </Stack>
  );
};

export default airplane.view(
  {
    slug: "waitlist",
    name: "Waitlist",
  },
  Waitlist
);
