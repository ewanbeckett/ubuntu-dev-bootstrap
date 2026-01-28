# Ubuntu Dev Bootstrap

Interactive Ubuntu installer for setting up a modern development environment with sensible defaults and optional tooling.

**Repository:** https://github.com/ewanbeckett/ubuntu-dev-bootstrap  
**Installer:** `installer.sh`

## Supported OS
- Ubuntu 24.04
- amd64 and arm64 (where upstream tools support it)

## Quick Start

```bash
git clone https://github.com/ewanbeckett/ubuntu-dev-bootstrap.git
cd ubuntu-dev-bootstrap
chmod +x installer.sh
./installer.sh
```

The installer presents a menu. Only selected components are installed.

## Non-Interactive Usage

Install everything with defaults:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT=all ./installer.sh
```

Install selected items only:

```bash
NONINTERACTIVE=1 DEFAULT_SELECT="1,2,7,14" ./installer.sh
```

Override language versions:

```bash
NODE_MAJOR=22 GO_VERSION=1.22.7 RUBY_STRATEGY=asdf RUBY_VERSION=3.3.6 \
NONINTERACTIVE=1 DEFAULT_SELECT="7,8,13" \
./installer.sh
```

## Included Components (Selectable)

- Base system packages
- CLI quality-of-life tools
- Automation utilities
- Git extras (git-lfs, GitHub CLI)
- Zsh + Oh My Zsh (non-destructive)
- Docker + Compose
- Node.js (version selectable)
- Go (version selectable)
- Rust, Bun, uv
- Python virtual environment with dev tooling
- Ruby (apt or asdf)
- VS Code (Snap)
- Obsidian (Snap)
- Ollama (local LLM runtime)
- Ansible
- Terraform

## Defaults

| Tool | Default |
|-----|---------|
| Node.js | 20.x |
| Go | 1.22.7 |
| Ruby | Ubuntu apt |
| Ruby (asdf) | 3.3.6 |
| Terraform | HashiCorp apt repo |
| Ollama model | llama3.1:8b |

All defaults can be overridden during installation.

## Shell Configuration

The installer does **not** overwrite existing shell configuration files.

It adds managed environment files:
- `~/.config/ai-forge/env.sh`
- `~/.config/ai-forge/env.zsh`

These are sourced from existing shell profiles if present.

## License

MIT
