require("flutter-tools").setup_project({
	{
		name = "macOS",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "macos",
		additional_args = { "--dart-define-from-file=env.json" },
	},
	{
		name = "Android",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "emulator-5554",
		additional_args = { "--dart-define-from-file=env.json" },
	},
	{
		name = "Web",
		target = "lib/main.dart",
		cwd = "apps/plot",
		device = "chrome",
		web_port = "8788",
		additional_args = { "--wasm", "--dart-define-from-file=env.json" },
	},
})
