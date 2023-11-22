import { useCallback, useState } from "react";

import {
  Button,
  Combobox,
  Group,
  Progress,
  Table,
  Text,
  Tooltip,
  useCombobox,
} from "@mantine/core";

import { IconFolderOpen } from "@tabler/icons-react";

import type { DbCategories, Event } from "@plotday/db";

import { useEventCategorizer } from "app/routes/api.event.category";

export const Categorizer = ({
  event,
  categories,
}: {
  event: Event;
  categories: DbCategories;
}) => {
  const categorize = useEventCategorizer(event);
  const [search, setSearch] = useState("");
  const [selectedItem, setSelectedItem] = useState<string | null>(null);
  const combobox = useCombobox({
    onDropdownClose: () => {
      combobox.resetSelectedOption();
      combobox.focusTarget();
      setSearch("");
    },

    onDropdownOpen: () => {
      combobox.focusSearchInput();
    },
  });

  const options = categories
    .filter((item) =>
      item.name.toLowerCase().includes(search.toLowerCase().trim())
    )
    .map((item) => (
      <Combobox.Option value={item.id.toString()} key={item.id}>
        {item.name}
      </Combobox.Option>
    ));
  return (
    <Combobox
      store={combobox}
      width={250}
      position="bottom-start"
      withArrow
      onOptionSubmit={(val) => {
        setSelectedItem(val);
        categorize(Number(val));
        combobox.closeDropdown();
      }}
    >
      <Combobox.Target withAriaAttributes={false}>
        <Button onClick={() => combobox.toggleDropdown()} variant="subtle">
          <IconFolderOpen />
        </Button>
      </Combobox.Target>

      <Combobox.Dropdown>
        <Combobox.Search
          value={search}
          onChange={(event) => setSearch(event.currentTarget.value)}
          placeholder="Search categories"
        />
        <Combobox.Options>
          {options.length > 0 ? (
            options
          ) : (
            <Combobox.Empty>Nothing found</Combobox.Empty>
          )}
        </Combobox.Options>
      </Combobox.Dropdown>
    </Combobox>
  );
};

export default Categorizer;
