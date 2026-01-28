#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################
# Defaults (override via env or prompts)
############################################
: "${NONINTERACTIVE:=0}"
: "${DEFAULT_SELECT:=}"

# Match original gist-style defaults (adjust as you prefer)
: "${DEFAULT_NODE_MAJOR:=22}"
: "${NODE_MAJOR:=$DEFAULT_NODE_MAJOR}"

: "${DEFAULT_GO_VERSION:=1.25.6}"
: "${GO_VERSION:=$DEFAULT_GO_VERSION}"

: "${DEFAULT_RUBY_VERSION:=4.0.1}"
: "${RUBY_VERSION:=$DEFAULT_RUBY_VERSION}"

: "${DEFAULT_ERLANG_VERSION:=28.3}"
: "${ERLANG_VERSION:=$DEFAULT_ERLANG_VERSION}"

: "${DEFAULT_ELIXIR_VERSION:=1.19.5-otp-28}"
: "${ELIXIR_VERSION:=$DEFAULT_ELIXIR_VERSION}"

: "${DEFAULT_PGVECTOR_VERSION:=0.8.1}"
: "${PGVECTOR_VERSION:=$DEFAULT_PGVECTOR_VERSION}"

: "${DEFAULT_OLLAMA_PULL_MODEL:=llama3}"
: "${OLLAMA_PULL_MODEL:=$DEFAULT_OLLAMA_PULL_MODEL}"  # empty to skip

: "${PY_VENV_DIR:=$HOME/.venvs/agents}"

############################################
# Logging
############################################
log()  { printf "\033[1;34m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }

on_err() {
  local ec=$?
  local ln=$1
  warn "Failed at line ${ln} (exit ${ec})."
  warn "Re-run is OK; this script is designed to be re-runnable."
  exit "$ec"
}
trap 'on_err $LINENO' ERR

############################################
# Helpers
############################################
need_cmd() { command -v "$1" >/dev/null 2>&1; }

sudo_keepalive() {
  need_cmd sudo || die "sudo is required"
  sudo -v
  while true; do sudo -n true 2>/dev/null || true; sleep 60; done &
  SUDO_KA_PID=$!
  trap 'kill "${SUDO_KA_PID:-0}" 2>/dev/null || true' EXIT
}

is_ubuntu() {
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]
}

is_ubuntu_24() {
  # Enforce Ubuntu 24.04 LTS specifically, per repo scope
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${VERSION_ID:-}" == "24.04" ]]
}

apt_update() {
  log "Updating apt indices"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
}

apt_install() {
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_install_best_effort() {
  # Tries to install all packages. If apt fails due to one unknown package,
  # it retries individually to install as many as possible.
  local pkgs=("$@")
  log "Installing packages (best effort): ${pkgs[*]}"
  if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"; then
    return 0
  fi
  warn "Bulk install failed; retrying packages individually to install as many as possible."
  local p
  for p in "${pkgs[@]}"; do
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p"; then
      :
    else
      warn "Could not install package: $p"
    fi
  done
}

ensure_keyrings_dir() {
  sudo mkdir -p /etc/apt/keyrings
  sudo chmod 0755 /etc/apt/keyrings
}

append_once() {
  local line="$1"
  local file="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -Fqx "$line" "$file" 2>/dev/null || printf "\n%s\n" "$line" >>"$file"
}

arch_go() {
  local a
  a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "Unsupported architecture for Go install: $a" ;;
  esac
}

ensure_snapd() {
  if need_cmd snap; then return 0; fi
  log "Installing snapd (required for Snap installs)"
  apt_install snapd
  sudo systemctl enable --now snapd.socket >/dev/null 2>&1 || true
}

snap_install() {
  local name="$1"
  if snap list "$name" >/dev/null 2>&1; then
    log "Snap already installed: $name"
  else
    log "Installing Snap: $name"
    sudo snap install "$name"
  fi
}

snap_install_classic() {
  local name="$1"
  if snap list "$name" >/dev/null 2>&1; then
    log "Snap already installed: $name"
  else
    log "Installing Snap: $name (classic)"
    sudo snap install "$name" --classic
  fi
}

setup_managed_env() {
  local zenv="$HOME/.config/ai-forge/env.zsh"
  local shenv="$HOME/.config/ai-forge/env.sh"
  mkdir -p "$HOME/.config/ai-forge"
  touch "$zenv" "$shenv"

  cat >"$zenv" <<'EOF'
# ai-forge env (managed by installer)
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
export AI_FORGE_VENV="${AI_FORGE_VENV:-$HOME/.venvs/agents}"
EOF

  cat >"$shenv" <<'EOF'
# ai-forge env (managed by installer)
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.bun/bin:$PATH"
export AI_FORGE_VENV="${AI_FORGE_VENV:-$HOME/.venvs/agents}"
EOF

  append_once '[[ -f "$HOME/.config/ai-forge/env.zsh" ]] && source "$HOME/.config/ai-forge/env.zsh"' "$HOME/.zshrc"
  append_once '[ -f "$HOME/.config/ai-forge/env.sh" ] && . "$HOME/.config/ai-forge/env.sh"' "$HOME/.bashrc"
  append_once '[ -f "$HOME/.config/ai-forge/env.sh" ] && . "$HOME/.config/ai-forge/env.sh"' "$HOME/.profile"
}

ask_line() {
  local prompt="$1"
  local def="${2:-}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "$def"
    return 0
  fi
  local ans=""
  if [[ -n "$def" ]]; then
    read -r -p "${prompt} [default: ${def}] " ans
    echo "${ans:-$def}"
  else
    read -r -p "${prompt} " ans
    echo "$ans"
  fi
}

normalize_selection() {
  local s="${1:-}"
  s="${s// /}"
  if [[ "$s" == "all" ]]; then
    echo "2,3,4,5,6,7,8,9,10,11"
  else
    echo "$s"
  fi
}

has_choice() {
  local list="$1" item="$2"
  [[ ",${list}," == *",${item},"* ]]
}

############################################
# Repo setup helpers (PGDG + GH CLI)
############################################
ensure_pgdg_repo() {
  if [[ -f /etc/apt/sources.list.d/pgdg.list ]]; then
    return 0
  fi
  log "Adding PGDG apt repository (PostgreSQL 17)"
  sudo install -d /usr/share/postgresql-common/pgdg
  sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  local codename
  codename="$(lsb_release -cs)"
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${codename}-pgdg main" \
    | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
}

ensure_github_cli_repo() {
  # Ubuntu 24.04 includes gh in the default repos, but keeping this is harmless and ensures current gh.
  if [[ -f /etc/apt/sources.list.d/github-cli.list ]]; then
    return 0
  fi
  ensure_keyrings_dir
  log "Adding GitHub CLI apt repository"
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /etc/apt/keyrings/githubcli.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
}

############################################
# Core installer steps
############################################
install_core_packages_mandatory() {
  # Per your direction:
  # - Core apt packages are NOT optional and run before everything else.
  # - Do not duplicate anything installed in other sections.
  # Therefore: do NOT install Postgres/PostGIS/pg packages here (those are in DB stack).
  # VS Code is installed via Snap (menu item) to follow Ubuntu App Center behavior.

  log "📦 Installing core tools and language build dependencies (mandatory)..."

  ensure_github_cli_repo
  apt_update

  apt_install_best_effort \
    git gh curl wget build-essential dirmngr gawk zsh fonts-powerline \
    pkg-config libpixman-1-dev libcairo2-dev libpango1.0-dev libjpeg-dev \
    libgif-dev librsvg2-dev ffmpeg unzip jq htmlq mpv libnss3-tools \
    imagemagick ghostscript mkcert fzf ripgrep bat inotify-tools \
    sqlite3 libsqlite3-dev \
    autoconf m4 libwxgtk3.2-dev libwxgtk-webview3.2-dev libgl1-mesa-dev \
    libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop \
    libxml2-utils libncurses-dev openjdk-11-jdk \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libxmlsec1-dev \
    libffi-dev liblzma-dev libyaml-dev

  # On Ubuntu, bat binary may be batcat
  if ! need_cmd bat && need_cmd batcat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi
}

install_zsh_stack() {
  # zsh is part of mandatory core packages; do not reinstall here.
  setup_managed_env

  if [[ "${SHELL:-}" != "$(command -v zsh)" ]]; then
    log "Setting default shell to zsh (may prompt for password)"
    chsh -s "$(command -v zsh)" || warn "Could not change default shell. Run: chsh -s $(command -v zsh)"
  fi

  if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
    log "Installing Oh My Zsh (non-destructive)"
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
      "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  else
    log "Oh My Zsh already installed"
  fi
}

install_asdf() {
  if [[ -d "$HOME/.asdf" ]]; then
    return 0
  fi
  log "Installing asdf"
  git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.16.0
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.bashrc"
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.zshrc"
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.profile"
}

asdf_source() {
  # shellcheck disable=SC1090
  . "$HOME/.asdf/asdf.sh" || true
}

install_ruby_asdf() {
  install_asdf
  asdf_source

  asdf plugin add ruby >/dev/null 2>&1 || true
  if ! asdf list ruby 2>/dev/null | grep -q "$RUBY_VERSION"; then
    log "Installing Ruby ${RUBY_VERSION} via asdf"
    asdf install ruby "$RUBY_VERSION"
  fi
  asdf set -u ruby "$RUBY_VERSION"

  gem install bundler rails || true
}

install_beam_and_phoenix() {
  install_asdf
  asdf_source

  asdf plugin add erlang >/dev/null 2>&1 || true
  if ! asdf list erlang 2>/dev/null | grep -q "$ERLANG_VERSION"; then
    log "Installing Erlang ${ERLANG_VERSION} via asdf"
    asdf install erlang "$ERLANG_VERSION"
  fi
  asdf set -u erlang "$ERLANG_VERSION"

  asdf plugin add elixir >/dev/null 2>&1 || true
  if ! asdf list elixir 2>/dev/null | grep -q "$ELIXIR_VERSION"; then
    log "Installing Elixir ${ELIXIR_VERSION} via asdf"
    asdf install elixir "$ELIXIR_VERSION"
  fi
  asdf set -u elixir "$ELIXIR_VERSION"

  mix local.hex --force
  mix archive.install hex phx_new --force
}

install_node() {
  if need_cmd node; then
    log "Node already installed: $(node -v)"
    return 0
  fi

  ensure_keyrings_dir
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null

  apt_update
  apt_install nodejs

  if need_cmd corepack; then
    corepack enable || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
  fi
}

install_go() {
  local arch tmp tarball
  arch="$(arch_go)"
  log "Installing Go ${GO_VERSION} for ${arch}"
  tmp="$(mktemp -d)"
  tarball="go${GO_VERSION}.linux-${arch}.tar.gz"

  curl -fsSL "https://go.dev/dl/${tarball}" -o "${tmp}/${tarball}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${tmp}/${tarball}"
  rm -rf "$tmp"

  setup_managed_env
  append_once 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.config/ai-forge/env.zsh"
  append_once 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.config/ai-forge/env.sh"
}

install_pgvector_from_source() {
  log "Installing pgvector v${PGVECTOR_VERSION} from source"
  cd /tmp
  rm -rf pgvector
  git clone --branch "v${PGVECTOR_VERSION}" https://github.com/pgvector/pgvector.git
  cd pgvector
  make
  sudo make install
  cd ~
}

create_vector_extension() {
  if ! need_cmd psql; then
    warn "psql not found; Postgres may not be installed."
    return 0
  fi
  log "Creating pgvector extension (best effort)"
  sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;" || true
}

install_db_stack_full() {
  # Full DB stack: Postgres 17 + PostGIS + pgvector + extension
  ensure_pgdg_repo
  apt_update
  apt_install postgresql-17 postgresql-client-17 postgresql-17-postgis-3 postgresql-server-dev-17
  install_pgvector_from_source
  create_vector_extension
}

install_ollama() {
  if need_cmd ollama; then
    log "Ollama already installed"
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
}

pull_ollama_model() {
  [[ -n "${OLLAMA_PULL_MODEL}" ]] || { warn "OLLAMA_PULL_MODEL is empty; skipping pull"; return 0; }
  local started=0 pid=""
  if ! pgrep -x ollama >/dev/null 2>&1; then
    ollama serve >/dev/null 2>&1 & pid=$!
    started=1
    sleep 2
  fi
  ollama pull "${OLLAMA_PULL_MODEL}" || warn "Model pull failed; retry later: ollama pull ${OLLAMA_PULL_MODEL}"
  if [[ "$started" == "1" ]]; then kill "$pid" 2>/dev/null || true; fi
}

install_vscode_snap() {
  ensure_snapd
  snap_install_classic code
}

install_obsidian_snap() {
  ensure_snapd
  snap_install obsidian
}

############################################
# Menu
############################################
print_menu() {
  cat <<EOF
Ubuntu Dev Bootstrap - installer.sh (Ubuntu 24.04 LTS)

Defaults (override via env or prompted):
  Node major:     ${NODE_MAJOR}
  Go version:     ${GO_VERSION}
  Ruby version:   ${RUBY_VERSION}
  Erlang version: ${ERLANG_VERSION}
  Elixir version: ${ELIXIR_VERSION}
  pgvector ver:   ${PGVECTOR_VERSION}
  Ollama model:   ${OLLAMA_PULL_MODEL}

Mandatory:
  - Core apt packages are installed automatically at startup.

Select items (comma-separated) or 'all':

  2) Zsh + Oh My Zsh (non-destructive)
  3) asdf + Ruby (Rails)
  4) asdf + Erlang + Elixir + Phoenix
  5) Node.js (NodeSource)
  6) Go (upstream tarball)
  7) Full DB stack: Postgres 17 + PostGIS + pgvector + extension
  8) VS Code (Snap --classic)
  9) Obsidian (Snap)
 10) Ollama
 11) Pull Ollama model

EOF
}

main() {
  is_ubuntu || die "This installer targets Ubuntu."
  is_ubuntu_24 || die "This repository targets Ubuntu 24.04 LTS specifically (VERSION_ID=24.04)."
  sudo_keepalive
  setup_managed_env

  # Mandatory core packages (run before any other selections)
  install_core_packages_mandatory

  # Version prompts (interactive only)
  if [[ "$NONINTERACTIVE" != "1" ]]; then
    NODE_MAJOR="$(ask_line "Node major to install" "$NODE_MAJOR")"
    GO_VERSION="$(ask_line "Go version to install" "$GO_VERSION")"
    RUBY_VERSION="$(ask_line "Ruby version (asdf) to install" "$RUBY_VERSION")"
    ERLANG_VERSION="$(ask_line "Erlang version (asdf) to install" "$ERLANG_VERSION")"
    ELIXIR_VERSION="$(ask_line "Elixir version (asdf) to install" "$ELIXIR_VERSION")"
    PGVECTOR_VERSION="$(ask_line "pgvector version to build" "$PGVECTOR_VERSION")"
    OLLAMA_PULL_MODEL="$(ask_line "Ollama model to pull (empty to skip)" "$OLLAMA_PULL_MODEL")"
  fi

  local selection
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    selection="$(normalize_selection "$DEFAULT_SELECT")"
    [[ -n "$selection" ]] || die "NONINTERACTIVE=1 requires DEFAULT_SELECT (e.g. all or 2,3,7)"
  else
    print_menu
    selection="$(ask_line "Enter selection" "")"
    selection="$(normalize_selection "$selection")"
    [[ -n "$selection" ]] || die "No selection provided."
  fi

  has_choice "$selection" 2  && install_zsh_stack
  has_choice "$selection" 3  && install_ruby_asdf
  has_choice "$selection" 4  && install_beam_and_phoenix
  has_choice "$selection" 5  && install_node
  has_choice "$selection" 6  && install_go
  has_choice "$selection" 7  && install_db_stack_full
  has_choice "$selection" 8  && install_vscode_snap
  has_choice "$selection" 9  && install_obsidian_snap
  has_choice "$selection" 10 && install_ollama
  has_choice "$selection" 11 && pull_ollama_model

  log "Complete."
  warn "Notes:"
  warn "- If your login shell was changed to zsh: it applies next login."
  warn "- Managed env files:"
  warn "  - $HOME/.config/ai-forge/env.sh (bash/sh)"
  warn "  - $HOME/.config/ai-forge/env.zsh (zsh)"
}

main "$@"
