# claude-plugins

A small marketplace of [Claude Code](https://www.claude.com/product/claude-code) plugins maintained by Masafumi Ito. Each plugin under `plugins/` is independently installable through the standard `/plugin` workflow.

## Install

Add this marketplace once, then install whichever plugins you want:

```text
/plugin marketplace add itouuuuuuuuu/claude-plugins
/plugin install <plugin-name>@itouuuuuuuuu-plugins
```

Then restart Claude Code or run `/reload-plugins`.

## Plugins

| Plugin | Description | Docs |
|---|---|---|
| [`herdr-pane-chat`](plugins/herdr-pane-chat/) | Chat with an AI agent (Claude Code, Codex, ...) in another [herdr](https://herdr.dev) pane via herdr's native agent-status tracking (no hooks, no polling). | [README](plugins/herdr-pane-chat/README.md) |
| [`tmux-codex-chat`](plugins/tmux-codex-chat/) | Send a prompt to OpenAI Codex CLI in another tmux pane and capture the answer via Codex's `Stop` hook (no UI polling). | [README](plugins/tmux-codex-chat/README.md) |

## Repository layout

```
.
├── .claude-plugin/
│   └── marketplace.json          # multi-plugin index for Claude Code
├── plugins/
│   └── <plugin-name>/
│       ├── .claude-plugin/plugin.json
│       ├── skills/               # plugin-provided skills
│       ├── README.md             # plugin-specific docs (install, troubleshooting)
│       └── ...                   # additional assets per plugin
└── .github/workflows/ci.yml      # bash -n / jq -e / fixture tests
```

## License

[MIT](LICENSE) © Masafumi Ito
