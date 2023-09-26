import { isRouteErrorResponse, useRouteError } from "@remix-run/react";

import { Stack, Text, Title } from "@mantine/core";
import "@mantine/core/styles.css";

import { captureRemixErrorBoundaryError } from "app/sentry";

export function ErrorPage({ children }: { children?: React.ReactNode }) {
  const error = useRouteError();

  let title =
    process.env.NODE_ENV === "production" ? "We lost the plot" : "Error";
  let message;
  if (isRouteErrorResponse(error)) {
    title = "Page not found";
  } else {
    captureRemixErrorBoundaryError(error);
    if (error instanceof Error) {
      message = error.message;
    } else if (typeof error === "string") {
      message = error;
    } else if (
      error &&
      typeof error === "object" &&
      "message" in error &&
      typeof error.message === "string"
    ) {
      message = error.message;
    } else {
      message = "Unknown error";
    }
  }
  return (
    <Stack>
      <Title>{title}</Title>
      {process.env.NODE_ENV === "production" && (
        <Text>We've logged the issue and will fix it soon!</Text>
      )}
      {process.env.NODE_ENV !== "production" && message && (
        <Text>
          <Text span fs="italic">
            Internal error:
          </Text>{" "}
          {message}
        </Text>
      )}
      {children}
    </Stack>
  );
}
