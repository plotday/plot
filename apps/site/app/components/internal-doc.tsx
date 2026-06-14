import {
  Button,
  Container,
  CopyButton,
  Group,
  TypographyStylesProvider,
} from "@mantine/core";
import { IconCheck, IconCopy } from "@tabler/icons-react";

import type { InternalDocContent } from "../lib/internal-docs.server";

// Renders an internal doc page: a top-right "Copy as Markdown" button (copies
// the raw .md source) above the rendered HTML. Shared by the features, updates,
// and voice routes.
export default function InternalDoc({ html, markdown }: InternalDocContent) {
  return (
    <Container mt="lg" size="md">
      <Group justify="flex-end" mb="sm">
        <CopyButton value={markdown} timeout={1500}>
          {({ copied, copy }) => (
            <Button
              variant="light"
              size="xs"
              leftSection={
                copied ? <IconCheck size={16} /> : <IconCopy size={16} />
              }
              onClick={copy}
            >
              {copied ? "Copied" : "Copy as Markdown"}
            </Button>
          )}
        </CopyButton>
      </Group>
      <TypographyStylesProvider>
        <div className="internal-doc" dangerouslySetInnerHTML={{ __html: html }} />
      </TypographyStylesProvider>
    </Container>
  );
}
