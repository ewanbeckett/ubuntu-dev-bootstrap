# Ubuntu Dev Bootstrap

Interactive installer for Ubuntu **24.04 LTS** that sets up a development environment with language runtimes, Phoenix tooling, and a PostgreSQL/PostGIS/pgvector stack.

**Repository:** https://github.com/ewanbeckett/ubuntu-dev-bootstrap  
**Installer:** `installer.sh`  
**License:** MIT

## Supported OS

- Ubuntu **24.04 LTS** (this repo targets 24.04 specifically)
- amd64 and arm64 (where supported by upstream tooling)

## Quick Start

```bash
git clone https://github.com/ewanbeckett/ubuntu-dev-bootstrap.git
cd ubuntu-dev-bootstrap
chmod +x installer.sh
./installer.sh
```

Core apt packages are installed automatically at startup. After that, the installer is menu-driven and only selected components are installed.

## Non-Interactive Usage

Install everything (after the mandatory core step):

```bash
NONINTERACTIVE=1 DEFAULT_SELECT=all ./installer.sh
```

Install selected components:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT="4,7,8" ./installer.sh
```

Override versions:

```bash
NODE_MAJOR=22 \
GO_VERSION=1.25.6 \
RUBY_VERSION=4.0.1 \
ERLANG_VERSION=28.3 \
ELIXIR_VERSION=1.19.5-otp-28 \
PGVECTOR_VERSION=0.8.1 \
NONINTERACTIVE=1 DEFAULT_SELECT="3,4,7" \
./installer.sh
```

## Selectable Components

- Zsh + Oh My Zsh (non-destructive)
- Ruby via asdf (Bundler + Rails)
- Erlang + Elixir + Phoenix via asdf
- Node.js via NodeSource (version selectable)
- Go (installed to `/usr/local/go`, version selectable)
- Full DB stack: PostgreSQL 17 + PostGIS + pgvector + extension
- VS Code (Snap `--classic`)
- Obsidian (Snap)
- Ollama + optional model pull

## Defaults

Defaults are shown during installation and can be overridden.

| Tool | Default |
|-----|---------|
| Node.js | 22.x |
| Go | 1.25.6 |
| Ruby | 4.0.1 |
| Erlang | 28.3 |
| Elixir | 1.19.5-otp-28 |
| pgvector | 0.8.1 |
| Ollama model | llama3 |

## Shell Configuration

The installer does not overwrite existing shell config files. It creates managed environment files:

- `~/.config/ai-forge/env.sh`
- `~/.config/ai-forge/env.zsh`

These are sourced from existing shell profiles if present.

## License

MIT
