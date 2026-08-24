# Set up the dashboard toolchain

Angular, the MCP server, and the vendor documentation files. For developers.

The dashboard is Angular 22 with Optimus UI components and TanStack Charts. Two pieces of tooling
make working on it much faster, and neither is set up by `npm ci`.

## 1. Install and run

```bash
just web-install
```

```bash
just web
```

The dev server runs on http://localhost:4200 and proxies `/api` to Vapor on port 8080, so browser
requests are same-origin and hot reload keeps working. Start the API separately with `just run`.

Proxy configuration is read only at startup. Restart after changing it.

## 2. Wire up the Angular MCP server

Angular ships an MCP server in its CLI. It gives an AI assistant real tools instead of guesses:
searching the current Angular documentation, listing workspace projects, running build and test
targets, and driving the dev server.

The command is the same everywhere:

```bash
npx -y @angular/cli mcp
```

Add `--read-only` to the args if you want to forbid it making changes.

**Claude Code** — already configured in `Dashboard/.mcp.json`:

```json
{
  "mcpServers": {
    "angular-cli": {
      "command": "npx",
      "args": ["-y", "@angular/cli", "mcp"]
    }
  }
}
```

**Codex** — already configured in `Dashboard/.codex/config.toml`:

```toml
[mcp_servers.angular-cli]
command = "npx"
args = ["-y", "@angular/cli", "mcp"]
```

**Gemini CLI** — create `Dashboard/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "angular-cli": {
      "command": "npx",
      "args": ["-y", "@angular/cli", "mcp"]
    }
  }
}
```

Other clients read the same shape from their own path: `.cursor/mcp.json`, `.vscode/mcp.json`,
`.antigravity/mcp.json`.

### What it exposes

| Tool | Does |
|---|---|
| `search_documentation` | Searches the official Angular docs |
| `get_best_practices` | Returns the current Angular best-practices guide |
| `list_projects` | Lists applications and libraries in the workspace |
| `run_target` | Runs a configured target: build, test, lint, e2e |
| `devserver.start` / `devserver.stop` | Starts and stops `ng serve` |
| `devserver.wait_for_build` | Returns logs from the most recent build |
| `onpush_zoneless_migration` | Analyses code for change-detection migration |
| `ai_tutor` | Interactive Angular tutor |

`search_documentation` is the one that earns its keep. Angular 22 changed enough that a model's
training data is often stale, and this returns current answers.

## 3. Download the llms-full.txt files

Both Angular and Optimus UI publish their documentation as a single file built for language models.
Having them locally means an assistant can read the real API rather than inventing one.

| Source | Index | Full corpus |
|---|---|---|
| Angular | https://angular.dev/llms.txt | https://angular.dev/assets/context/llms-full.txt |
| Optimus UI | https://optimus.openng.org/llms/llms.txt | https://optimus.openng.org/llms/llms-full.txt |

```bash
curl -o Dashboard/angular-llms-full.txt https://angular.dev/assets/context/llms-full.txt
```

```bash
curl -o Dashboard/optimus-llms-full.txt https://optimus.openng.org/llms/llms-full.txt
```

`Dashboard/.gitignore` already ignores `*-llms*.txt`, so these stay local. They are large and they
go stale; re-download them after a major version bump rather than committing them.

Point your assistant at whichever it needs. For a single component, Optimus UI also serves any
documentation page as Markdown by appending `.md` to its URL, which is far cheaper than the full
corpus.

## 4. Know where the conventions live

`Dashboard/AGENTS.md` holds the coding conventions. Its main body is Angular's own published
best-practices file, so refresh it from the source rather than editing it by hand:

```bash
curl -o /tmp/best-practices.md https://angular.dev/assets/context/best-practices.md
```

The project-specific section at the end is ours to maintain. That is where Optimus UI import style,
the in-memory token rule, and the accessibility gate live.

## Verify

```bash
just web-test
```

```bash
just web-build
```

The build enforces bundle budgets, so it fails on an accidental heavyweight dependency. Keep new
work AXE-clean in both themes.

#icicle-insights# #How-To# #Developer# #frontend# #tooling#
