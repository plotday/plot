import { Heading, Stack, Table } from "@airplane/views";
import airplane from "airplane";

const Waitlist = () => {
  return (
    <Stack spacing="lg">
      <Stack spacing={0}>
        <Heading>Waitlist</Heading>
      </Stack>
      <Table
        title="Waitlist"
        task="view_waitlist"
        columns={[
          { label: "Email", accessor: "email", width: 300 },
          {
            label: "Created",
            accessor: "created_at",
            type: "datetime",
            width: 200,
          },
          {
            label: "Joined",
            accessor: "account_created_at",
            type: "datetime",
            width: 200,
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
