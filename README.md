# Ubuntu Dev Bootstrap

Interactive installer for **Ubuntu 24.04 LTS** that sets up a complete development environment with common system tooling, language runtimes, and a modern PostgreSQL/PostGIS/pgvector database stack.

**Repository:** https://github.com/ewanbeckett/ubuntu-dev-bootstrap  
**Installer:** `installer.sh`  
**License:** MIT

---

## Supported OS

- **Ubuntu 24.04 LTS only**
- amd64 and arm64 (where supported by upstream tooling)

---

## Quick Start

```bash
git clone https://github.com/ewanbeckett/ubuntu-dev-bootstrap.git
cd ubuntu-dev-bootstrap
chmod +x installer.sh
./installer.sh
```

Core system packages are installed automatically at startup. After that, the installer is menu-driven and only selected components are installed.

---

## Non-Interactive Usage

Install everything (after mandatory core packages):

```bash
NONINTERACTIVE=1 DEFAULT_SELECT=all ./installer.sh
```

Install selected components:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT="4,7,12" ./installer.sh
```

Override versions:

```bash
NODE_MAJOR=22 \
GO_VERSION=1.25.6 \
RUBY_VERSION=4.0.1 \
ERLANG_VERSION=28.3 \
ELIXIR_VERSION=1.19.5-otp-28 \
PGVECTOR_VERSION=0.8.1 \
NONINTERACTIVE=1 DEFAULT_SELECT="3,4,7,12" \
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
- Erlang + Elixir + Phoenix via asdf
- Node.js via NodeSource (version selectable)
- Go (installed to `/usr/local/go`, version selectable)
- **Rust via rustup**
- Full database stack:
  - PostgreSQL 17
  - PostGIS
  - pgvector (built from source)
  - pgvector extension created automatically
- VS Code (Snap `--classic`)
- Obsidian (Snap)
- Ollama + optional model pull

---

## Defaults

Defaults are shown during installation and can be overridden.

| Tool | Default |
|-----|---------|
| Node.js | 22.x |
| Go | 1.25.6 |
| Ruby | 4.0.1 |
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

## Notes

- PostgreSQL extensions are created on a best-effort basis; the database service must be running.
- Some apt packages may vary slightly by Ubuntu release; non-critical failures do not abort the installer.
- Re-running the installer is supported.

---

## License

MIT
