import { useEffect, useState } from "react";

import {
  Form,
  Link,
  useNavigate,
  useNavigation,
  useParams,
  useSearchParams,
} from "@remix-run/react";

import {
  Button,
  Group,
  Menu,
  Modal,
  Stack,
  Text,
  TextInput,
} from "@mantine/core";
import { useDisclosure } from "@mantine/hooks";

import {
  IconCaretDownFilled,
  IconChevronLeft,
  IconDotsVertical,
  IconMinusVertical,
} from "@tabler/icons-react";

import type { DbCategory } from "@plotday/db";
import { pathToUrl, urlToPath } from "@plotday/db";

import { useCategories } from "app/hooks";

export const CategoryEditor = ({
  category,
  opened,
  close,
}: {
  category: DbCategory;
  opened: boolean;
  close: () => void;
}) => {
  const name = category.path.indexOf(".") === -1 ? "Other" : category?.name;
  const navigation = useNavigation();
  useEffect(() => {
    if (opened && navigation.state === "loading") {
      close();
    }
  }, [opened, close, navigation.state]);

  return (
    <Modal opened={opened} onClose={close} title="Edit priority">
      <Stack>
        <Form
          method="PATCH"
          action={pathToUrl(category.path)}
          id="edit-priority"
          replace
        >
          <TextInput
            name="name"
            label="Name"
            placeholder="Name"
            defaultValue={name}
          />
        </Form>
        <Group justify="space-between">
          <Form method="DELETE" action={pathToUrl(category.path)}>
            <Button variant="subtle" type="submit">
              Delete
            </Button>
          </Form>
          <Button variant="subtle" type="submit" form="edit-priority">
            Save
          </Button>
        </Group>
      </Stack>
    </Modal>
  );
};

export const Navigator = () => {
  const categories = useCategories();
  const [searchParams] = useSearchParams();
  const params = useParams();
  const navigate = useNavigate();
  const [role, setRole] = useState(urlToPath(params.role ?? ""));
  useEffect(() => {
    setRole(urlToPath(params.role ?? ""));
  }, [params.role]);
  const path = `${role}.${urlToPath(params.category ?? "")}`;
  const readOnly =
    params.category && ["other", "meetings"].includes(params.category);
  const topLevel = categories.filter(
    (category) => category.path.indexOf(".") === -1 && category.path !== role
  );
  const roleCategory = categories.filter(
    (category) =>
      (!role && category.path.indexOf(".") === -1) || category.path === role
  )?.[0];
  const category = categories.filter(
    (category) => category.path === (params.category === "other" ? role : path)
  )?.[0];
  const name = params.category === "other" ? "Other" : category?.name;
  const [opened, { open, close }] = useDisclosure(false);

  return (
    <>
      <Group gap={0} wrap="nowrap">
        {role && !category && topLevel.length === 0 && (
          <Text py="xs" px="sm" fw="bold" lh={1}>
            {roleCategory?.name}
          </Text>
        )}
        {role && !category && topLevel.length > 0 && (
          <Menu shadow="md" width={200}>
            <Menu.Target>
              <Button
                variant="subtle"
                rightSection={<IconCaretDownFilled size={16} />}
              >
                {roleCategory?.name}
              </Button>
            </Menu.Target>

            <Menu.Dropdown>
              {topLevel.map((category) => (
                <Menu.Item
                  key={category.id}
                  onClick={() => {
                    setRole(category.path);
                    navigate(`/+${category.path}`);
                  }}
                >
                  {category.name}
                </Menu.Item>
              ))}
            </Menu.Dropdown>
          </Menu>
        )}
        {(!role || category) && (
          <Button
            pl="sm"
            pr="xs"
            radius={0}
            variant="subtle"
            component={Link}
            to={`/+${roleCategory.path}?${searchParams}`}
            c="var(--mantine-color-text)"
          >
            <IconChevronLeft />
            {roleCategory?.name}
          </Button>
        )}
        {category && (
          <>
            {readOnly && (
              <>
                <IconMinusVertical color="var(--mantine-color-dimmed)" />
                <Text fz="sm" fw={600} pl="xs" pr="xs">
                  {name}
                </Text>
              </>
            )}
            {!readOnly && (
              <Button
                pl="xs"
                pr="xs"
                radius={0}
                variant="subtle"
                c="var(--mantine-color-text)"
                rightSection={<IconDotsVertical size={14} />}
                onClick={open}
              >
                {name}
              </Button>
            )}
          </>
        )}
      </Group>
      {category && (
        <CategoryEditor opened={opened} close={close} category={category} />
      )}
    </>
  );
};
