import { useClerk } from "@clerk/react-router";
import { useEffect } from "react";
import { useSearchParams } from "react-router";

/**
 * Validates that a returnTo URL is safe to redirect to.
 * Only allows redirects to plot.day subdomains and relative paths.
 */
function isValidReturnTo(returnTo: string): boolean {
  if (returnTo === "/") return true;
  if (returnTo.startsWith("/") && !returnTo.startsWith("//")) return true;
  if (returnTo.startsWith("https://app.plot.day")) return true;
  if (returnTo.startsWith("https://plot.day")) return true;
  return false;
}

export default function SignOut() {
  const { signOut } = useClerk();
  const [searchParams] = useSearchParams();

  const requestedReturnTo = searchParams.get("returnTo") || "/";
  const returnTo = isValidReturnTo(requestedReturnTo) ? requestedReturnTo : "/";

  useEffect(() => {
    signOut({ redirectUrl: returnTo });
  }, [signOut, returnTo]);

  return null;
}
