require("flutter-tools").setup_project({
	{
		name = "macOS",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "macos",
	},
	{
		name = "Web",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "chrome",
		web_port = "8788",
		additional_args = { "--wasm" },
	},
})
