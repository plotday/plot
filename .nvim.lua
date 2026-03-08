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
