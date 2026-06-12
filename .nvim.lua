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
		-- Android phone — Play Store phone screenshots. android_medium
		-- (Pixel, 1080x1920 = exactly 9:16, within Play's 2:1 max-side
		-- rule). Boot first with `pnpm sim:android` (apps/plot); pinned to
		-- port 5554 so the serial is stable.
		name = "Android",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "emulator-5554",
	},
	{
		-- Android tablet — Play Store tablet screenshots. Galaxy Tab S8
		-- Ultra (1848x2960). Boot first with `pnpm sim:tablet`; pinned to
		-- port 5556 so it can run alongside the phone sim.
		name = "Android Tablet",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "emulator-5556",
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
