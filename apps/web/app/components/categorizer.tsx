import { useState } from "react";

import { useParams } from "@remix-run/react";

import { Button, Combobox, useCombobox } from "@mantine/core";

import { IconFolderOpen } from "@tabler/icons-react";

import type { DbCategories, Event } from "@plotday/db";
import { urlToPath } from "@plotday/db";

import { useEventCategorizer } from "app/routes/api.event.category";

export const Categorizer = ({
  event,
  categories,
}: {
  event: Event;
  categories: DbCategories;
}) => {
  const params = useParams();
  const categorize = useEventCategorizer(event);
  const [search, setSearch] = useState("");
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
        if (val === "$create") {
          if (!params.role) {
            console.error("Categorizer used outside a params path");
            return;
          }
          categorize({ role: urlToPath(params.role), name: search });
        } else {
          categorize({ id: Number(val) });
        }

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
          {options}
          {search.trim().length > 0 && (
            <Combobox.Option value="$create">+ Create {search}</Combobox.Option>
          )}
        </Combobox.Options>
      </Combobox.Dropdown>
    </Combobox>
  );
};

export default Categorizer;
