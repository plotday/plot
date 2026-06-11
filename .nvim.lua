require("flutter-tools").setup_project({
	{
		name = "macOS",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "macos",
	},
	{
		name = "iOS",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "iphone",
	},
	{
		-- iPad Pro 13-inch (M4) — App Store screenshot size (2064x2752).
		-- Boot it first with `pnpm sim:ipad` (apps/plot). Keyed by UDID
		-- because two sims share the "iPad Pro 13-inch (M4)" name.
		name = "iPad",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "9EC93BEB-903E-4B86-934C-2AFB4CFA4C26",
	},
	{
		name = "Android",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "emulator-5554",
	},
	{
		name = "Chrome",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "chrome",
		web_port = "8788",
		additional_args = { "--wasm" },
	},
	{
		name = "Web Server",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "web-server",
		web_port = "8788",
	},
})
