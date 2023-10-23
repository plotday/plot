import { useSearchParams } from "@remix-run/react";

import { ActionIcon, Box, Popover, Stack, Switch } from "@mantine/core";

import { IconAdjustments } from "@tabler/icons-react";

export type Filter = {
  name: string;
  label: string;
};

export default function Search({ filters }: { filters: Filter[] }) {
  const [params, setParams] = useSearchParams();
  return (
    <Box pos="absolute" p="md" style={{ top: 0, right: 0, zIndex: 101 }}>
      <Popover width={200} position="bottom" withArrow shadow="md">
        <Popover.Target>
          <ActionIcon variant="subtle" aria-label="Settings">
            <IconAdjustments
              style={{ width: "85%", height: "85%" }}
              stroke={1.5}
            />
          </ActionIcon>
        </Popover.Target>
        <Popover.Dropdown>
          <Stack>
            {filters.map((filter) => (
              <Switch
                key={filter.name}
                label={filter.label}
                checked={params.get(filter.name) === "true"}
                onChange={(event) =>
                  setParams({
                    ...params,
                    [filter.name]: event.currentTarget.checked,
                  })
                }
              />
            ))}
          </Stack>
        </Popover.Dropdown>
      </Popover>
    </Box>
  );
}
