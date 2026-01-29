# Ubuntu Dev Bootstrap

Interactive installer for **Ubuntu 24.04 LTS** that sets up a complete development environment with common system tooling, language runtimes, and a modern PostgreSQL/PostGIS/pgvector database stack. The installer is safe to run on a fresh Ubuntu 24.04 system and bootstraps required tools (including curl) automatically.

**Repository:** https://github.com/ewanbeckett/ubuntu-dev-bootstrap  
**Installer:** `installer.sh`  
**License:** MIT

---

## Supported OS

- **Ubuntu 24.04 LTS only**
- amd64 and arm64 (where supported by upstream tooling)

---

## Quick Start

## Option 1: Start install directly from terminal:

```bash
wget -qO- https://raw.githubusercontent.com/ewanbeckett/ubuntu-dev-bootstrap/main/installer.sh | bash
```

## Option 2: Download first and inspect before running (recommended for anything that uses sudo):

```bash
wget https://raw.githubusercontent.com/ewanbeckett/ubuntu-dev-bootstrap/main/installer.sh
chmod +x installer.sh
./installer.sh
```

## Option 3: Clone (if git is already installed):

```bash
git clone https://github.com/ewanbeckett/ubuntu-dev-bootstrap.git
cd ubuntu-dev-bootstrap
chmod +x installer.sh
./installer.sh
```

Core system packages are installed automatically at startup. After that, the installer is menu-driven and only selected components are installed.

---

## Non-Interactive Usage

In non-interactive mode, only the mandatory core packages are installed unless `DEFAULT_SELECT` is provided.

Install everything (after mandatory core packages):

```bash
NONINTERACTIVE=1 DEFAULT_SELECT=all ./installer.sh
```

Install selected components (by number):

```bash
NONINTERACTIVE=1 DEFAULT_SELECT="3,5,9" ./installer.sh
```

Selectable component numbers:

1. Zsh + Oh My Zsh
2. Ruby via asdf
3. Python via asdf
4. Erlang + Elixir + Phoenix via asdf
5. Node.js via NodeSource
6. Go to /usr/local/go
7. Rust via rustup
8. htmlq via cargo
9. Full DB stack (Postgres 17 + PostGIS + pgvector)
10. VS Code (Snap)
11. Obsidian (Snap)
12. Ollama
13. Pull Ollama model
14. Agent tooling bundle

Override versions:

```bash
NODE_MAJOR=24 \
GO_VERSION=1.25.6 \
RUBY_VERSION=4.0.1 \
PYTHON_VERSION=3.12.9 \
ERLANG_VERSION=28.3 \
ELIXIR_VERSION=1.19.5-otp-28 \
PGVECTOR_VERSION=0.8.1 \
NONINTERACTIVE=1 DEFAULT_SELECT="3,5,8,13" \
./installer.sh
```

---

## Mandatory Core Packages

The installer always installs a base set of apt packages before any other steps.  
These include common CLI tools, media utilities, build dependencies, language build prerequisites, and security tooling.

Database packages and language runtimes are **not duplicated** here and are installed only by their respective steps.

---

## Selectable Components

- Zsh + Oh My Zsh (non-destructive)
- Ruby via asdf (Bundler + Rails)
- Python via asdf
- Erlang + Elixir + Phoenix via asdf
- Node.js via NodeSource (version selectable)
- Go (installed to `/usr/local/go`, version selectable)
- **Rust via rustup**
- htmlq via cargo
- Full database stack:
  - PostgreSQL 17
  - PostGIS
  - pgvector (built from source)
  - pgvector extension created automatically
- VS Code (Snap `--classic`)
- Obsidian (Snap)
- Ollama + optional model pull
- Agent tooling bundle:
  - htmlq, Bun, uv
  - Python tooling (venv + agent libs)
  - Node AI CLIs (moltbot, molthub, gemini-cli, etc.)
  - Playwright deps + browsers
  - Docker
  - tidewave, wacli, gogcli

Note: selecting the agent tooling bundle will also install Python via asdf if it is not already selected.

Note: some Python tools (e.g., `crewai`, `aider-chat`) are intentionally excluded due to current resolver conflicts in a single venv. They may be re-added when their dependency graphs become compatible.

Note: the installer can optionally configure `git` user.name/user.email during the interactive flow.

---

## Defaults

Defaults are shown during installation and can be overridden.

| Tool | Default |
|-----|---------|
| Node.js | 24.x |
| Go | 1.25.6 |
| Ruby | 4.0.1 |
| Python | 3.12.9 |
| Erlang | 28.3 |
| Elixir | 1.19.5-otp-28 |
| Rust | latest stable (rustup) |
| pgvector | 0.8.1 |
| Ollama model | llama3 |

---

## Shell Configuration

The installer does not overwrite existing shell configuration files.

It creates managed environment files:

- `~/.config/ai-forge/env.sh`
- `~/.config/ai-forge/env.zsh`

These are sourced from existing shell profiles if present.

---

## Development

### ShellCheck (static analysis)

ShellCheck is a linter for shell scripts. It helps catch common mistakes and unsafe patterns.

Install:

```bash
sudo apt-get install -y shellcheck
```

Run against `installer.sh`:

```bash
chmod +x scripts/shellcheck.sh
./scripts/shellcheck.sh
```

### Python agent tooling constraints

The agent tooling bundle uses a pinned constraints file to avoid dependency conflicts.

Override or disable the constraints:

```bash
PY_AGENT_CONSTRAINTS=/path/to/constraints.txt ./installer.sh
PY_AGENT_CONSTRAINTS="" ./installer.sh
```

---

## Notes

- PostgreSQL extensions are created on a best-effort basis; the database service must be running.
- Some apt packages may vary slightly by Ubuntu release; non-critical failures do not abort the installer.
- Re-running the installer is supported.
- Best-effort steps may fail without aborting the run (Node global CLIs, Playwright install/deps, Ollama model pull, Python agent packages, pgvector build).

---

## License

MIT
