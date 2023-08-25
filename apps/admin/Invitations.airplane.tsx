import { Card, Form, Heading, Stack, Table } from "@airplane/views";
import airplane from "airplane";

const Invitations = () => {
  return (
    <Stack spacing="lg">
      <Stack spacing={0}>
        <Heading>Invitation Dashboard</Heading>
      </Stack>
      <Stack direction="row">
        <Table
          width="3/4"
          title="Invitations"
          task="view_invitations"
          columns={[
            { label: "Code", accessor: "code", width: 100 },
            {
              label: "Uses",
              accessor: "uses",
              width: 80,
            },
            {
              label: "Remaining",
              accessor: "remaining",
              canEdit: true,
              width: 80,
            },
            {
              label: "Created",
              accessor: "created_at",
              type: "datetime",
            },
          ]}
          rowActions={[{ slug: "update_invitation", label: "Update" }]}
          rowActionsMenu={[{ slug: "delete_invitation", label: "Delete" }]}
        />
        <Card width="1/4">
          <Heading level={3}>Create invitation</Heading>
          <Form
            task={{
              slug: "create_invitation",
              fieldOptions: [{ slug: "remaining", defaultValue: 1 }],
            }}
          />
        </Card>
      </Stack>
    </Stack>
  );
};

export default airplane.view(
  {
    slug: "invitations",
    name: "Invitations",
  },
  Invitations
);
