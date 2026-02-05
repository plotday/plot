import { redirect } from "react-router";

export function loader() {
  return redirect("https://app.plot.day", 301);
}
