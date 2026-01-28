# Ubuntu Dev Bootstrap

Interactive installer for setting up a complete Ubuntu development environment with databases, language runtimes, and tooling commonly used for backend, BEAM, and automation work.

**Repository:** https://github.com/ewanbeckett/ubuntu-dev-bootstrap  
**Installer:** `installer.sh`  
**License:** MIT

---

## Supported OS

- Ubuntu 24.04
- amd64 and arm64 (where supported by upstream tooling)

---

## Quick Start

```bash
git clone https://github.com/ewanbeckett/ubuntu-dev-bootstrap.git
cd ubuntu-dev-bootstrap
chmod +x installer.sh
./installer.sh
```

The installer is menu-driven. Only the components you select are installed.

---

## Non-Interactive Usage

Install everything with defaults:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT=all ./installer.sh
```

Install selected components:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT="1,4,7" ./installer.sh
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

---

## Selectable Components

1. **Core packages**  
   System tools, media utilities, build dependencies, fonts, and full database prerequisites.

2. **Zsh + Oh My Zsh**  
   Installed non-destructively. Existing shell config is preserved.

3. **Ruby (asdf)**  
   Ruby with Bundler and Rails.

4. **Erlang + Elixir + Phoenix (asdf)**  
   Full BEAM stack with Phoenix installer.

5. **Node.js (NodeSource)**  
   Version-selectable Node with Corepack enabled.

6. **Go (upstream tarball)**  
   Version-selectable Go installed to `/usr/local/go`.

7. **Full database stack**  
   - PostgreSQL 17  
   - PostGIS  
   - pgvector (built from source)  
   - pgvector extension created automatically

8. **VS Code**  
   Installed via Snap (`--classic`), matching Ubuntu App Center behavior.

9. **Obsidian**  
   Installed via Snap.

10. **Ollama**  
    Local LLM runtime.

11. **Ollama model pull**  
    Optional model download (default: `llama3`).

---

## Core Packages Installed

When selecting **Core packages**, the installer installs (best-effort):

- Git, GitHub CLI, curl, wget, build tools
- Zsh and Powerline fonts
- Media and rendering tools (ffmpeg, mpv, ImageMagick, Ghostscript)
- HTML/JSON tools (`jq`, `htmlq`)
- Security and cert tools (`mkcert`, `libnss3-tools`)
- SQLite and development headers
- PostgreSQL 17, PostGIS, and server headers
- Erlang/Elixir build dependencies (wxWidgets, OpenJDK, ncurses, SSL, XML, YAML)

VS Code is intentionally installed separately via Snap.

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
| pgvector | 0.8.1 |
| Ollama model | llama3 |

---

## Shell Configuration

The installer does **not** overwrite existing shell configuration files.

It adds managed environment files:

- `~/.config/ai-forge/env.sh`
- `~/.config/ai-forge/env.zsh`

These are sourced from existing shell profiles if present.

---

## Notes

- PostgreSQL extensions are created on a best-effort basis; the database service must be running.
- Some packages may vary by Ubuntu release; the installer continues when non-critical packages are unavailable.
- Re-running the installer is supported.

---

## License

MIT
