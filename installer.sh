#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################
# STAGE 0 BOOTSTRAP (no curl assumptions)
############################################
# Fresh Ubuntu 24.04 does NOT guarantee curl/wget/gnupg/lsb-release.
# Bootstrap the absolute minimum using only apt + sudo.

if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to run this installer."
  exit 1
fi

sudo -v

sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  gnupg \
  lsb-release

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Defaults (override via env or prompts)
############################################
: "${NONINTERACTIVE:=0}"

: "${DEFAULT_NODE_MAJOR:=24}"
: "${NODE_MAJOR:=${NODE_MAJOR:-$DEFAULT_NODE_MAJOR}}"

: "${DEFAULT_GO_VERSION:=1.25.6}"
: "${GO_VERSION:=${GO_VERSION:-$DEFAULT_GO_VERSION}}"

: "${DEFAULT_RUBY_VERSION:=4.0.1}"
: "${RUBY_VERSION:=${RUBY_VERSION:-$DEFAULT_RUBY_VERSION}}"

: "${DEFAULT_PYTHON_VERSION:=3.12.9}"
: "${PYTHON_VERSION:=${PYTHON_VERSION:-$DEFAULT_PYTHON_VERSION}}"

: "${DEFAULT_ERLANG_VERSION:=28.3}"
: "${ERLANG_VERSION:=${ERLANG_VERSION:-$DEFAULT_ERLANG_VERSION}}"

: "${DEFAULT_ELIXIR_VERSION:=1.19.5-otp-28}"
: "${ELIXIR_VERSION:=${ELIXIR_VERSION:-$DEFAULT_ELIXIR_VERSION}}"

: "${DEFAULT_PGVECTOR_VERSION:=0.8.1}"
: "${PGVECTOR_VERSION:=${PGVECTOR_VERSION:-$DEFAULT_PGVECTOR_VERSION}}"

: "${DEFAULT_OLLAMA_PULL_MODEL:=llama3}"
: "${OLLAMA_PULL_MODEL:=${OLLAMA_PULL_MODEL:-$DEFAULT_OLLAMA_PULL_MODEL}}"  # empty to skip

: "${PY_VENV_DIR:=$HOME/.venvs/agents}"
: "${PY_AGENT_CONSTRAINTS:=${SCRIPT_DIR}/constraints.txt}"
: "${GIT_NAME:=${GIT_NAME:-}}"
: "${GIT_EMAIL:=${GIT_EMAIL:-}}"

############################################
# Logging
############################################
log()  { printf "\033[1;34m[+] %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m[!] %s\033[0m\n" "$*"; }
die()  { printf "\033[1;31m[x] %s\033[0m\n" "$*"; exit 1; }

BEST_EFFORT_FAILURES=()

record_best_effort_failure() {
  local msg="$1"
  BEST_EFFORT_FAILURES+=("$msg")
}

on_err() {
  local ec=$?
  local ln=$1
  warn "Failed at line ${ln} (exit ${ec})."
  warn "Re-run is OK; this script is designed to be re-runnable."
  exit "$ec"
}
trap 'on_err $LINENO' ERR

############################################
# OS enforcement
############################################
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || die "This installer targets Ubuntu 24.04 LTS only."

############################################
# APT update/install strategy
############################################
# We already ran apt-get update in Stage 0.
APT_UPDATED=1
APT_REPO_DIRTY=0

apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 || "$APT_REPO_DIRTY" -eq 1 ]]; then
    log "Updating apt indices"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    APT_UPDATED=1
    APT_REPO_DIRTY=0
  fi
}

mark_repo_dirty() {
  APT_REPO_DIRTY=1
}

apt_install() {
  apt_update_once
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

apt_install_best_effort() {
  apt_update_once
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

need_cmd() { command -v "$1" >/dev/null 2>&1; }

sudo_keepalive() {
  sudo -v
  while true; do sudo -n true 2>/dev/null || true; sleep 60; done &
  SUDO_KA_PID=$!
  trap 'kill "${SUDO_KA_PID:-0}" 2>/dev/null || true' EXIT
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


arch_asdf() {
  local a
  a="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  case "$a" in
    amd64|x86_64) echo "amd64" ;;
    arm64|aarch64) echo "arm64" ;;
    *) die "Unsupported architecture for asdf binary install: $a" ;;
  esac
}

pgvector_control_version() {
  if ! need_cmd pg_config; then
    return 0
  fi
  local sharedir file
  sharedir="$(pg_config --sharedir 2>/dev/null || true)"
  file="${sharedir}/extension/vector.control"
  if [[ -f "$file" ]]; then
    awk -F"'" '/^default_version/ {print $2; exit}' "$file"
  fi
}

pgvector_db_version() {
  if ! need_cmd psql; then
    return 0
  fi
  sudo -u postgres psql -tAc "SELECT extversion FROM pg_extension WHERE extname='vector'" 2>/dev/null \
    | tr -d '[:space:]'
}


############################################
# Prompts
############################################
ask_line() {
  local prompt="$1"
  local def="${2:-}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo "$def"
    return 0
  fi
  local ans=""
  if [[ -r /dev/tty ]]; then
    if ! read -r -p "${prompt} [default: ${def}] " ans </dev/tty; then
      echo "$def"
      return 0
    fi
  else
    echo "$def"
    return 0
  fi
  echo "${ans:-$def}"
}

ask_yn() {
  # Default YES unless explicitly answered n/N
  local prompt="$1"
  local def="${2:-Y}"  # Y or N
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$def" == "Y" ]] && echo "Y" || echo "N"
    return 0
  fi

  local suffix=""
  if [[ "$def" == "Y" ]]; then
    suffix=" [Y/n] "
  else
    suffix=" [y/N] "
  fi

  local ans=""
  if [[ -r /dev/tty ]]; then
    if ! read -r -p "${prompt}${suffix}" ans </dev/tty; then
      echo "$def"
      return 0
    fi
  else
    echo "$def"
    return 0
  fi
  ans="${ans:-$def}"
  case "$ans" in
    Y|y) echo "Y" ;;
    N|n) echo "N" ;;
    *)   echo "$def" ;;
  esac
}

############################################
# Repo setup helpers (PGDG + GH CLI)
############################################
ensure_github_cli_repo() {
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
  mark_repo_dirty
}

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
  mark_repo_dirty
}

ensure_nodesource_repo() {
  if [[ -f /etc/apt/sources.list.d/nodesource.list ]]; then
    if grep -q "node_${NODE_MAJOR}.x" /etc/apt/sources.list.d/nodesource.list; then
      return 0
    fi
    log "Updating NodeSource apt repository to Node ${NODE_MAJOR}.x"
    sudo rm -f /etc/apt/sources.list.d/nodesource.list
  fi
  ensure_keyrings_dir
  log "Adding NodeSource apt repository (Node ${NODE_MAJOR}.x)"
  curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
    | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    | sudo tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  mark_repo_dirty
}

############################################
# Environment management
############################################
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

  # shellcheck disable=SC2016
  append_once '[[ -f "$HOME/.config/ai-forge/env.zsh" ]] && source "$HOME/.config/ai-forge/env.zsh"' "$HOME/.zshrc"
  # shellcheck disable=SC2016
  append_once '[ -f "$HOME/.config/ai-forge/env.sh" ] && . "$HOME/.config/ai-forge/env.sh"' "$HOME/.bashrc"
  # shellcheck disable=SC2016
  append_once '[ -f "$HOME/.config/ai-forge/env.sh" ] && . "$HOME/.config/ai-forge/env.sh"' "$HOME/.profile"
}

############################################
# Mandatory core packages (no duplication)
############################################
install_core_packages_mandatory() {
  log "📦 Installing core tools and language build dependencies (mandatory)..."

  # Silence detached HEAD advice (common during automated installs)
  git config --global advice.detachedHead false

  ensure_github_cli_repo

  # Stage 0 already installed: ca-certificates curl wget gnupg lsb-release
  apt_install_best_effort \
    git gh build-essential dirmngr gawk zsh fonts-powerline \
    pkg-config libpixman-1-dev libcairo2-dev libpango1.0-dev libjpeg-dev \
    libgif-dev librsvg2-dev ffmpeg unzip jq mpv libnss3-tools \
    imagemagick ghostscript mkcert fzf ripgrep bat inotify-tools \
    sqlite3 libsqlite3-dev \
    autoconf m4 libwxgtk3.2-dev libwxgtk-webview3.2-dev libgl1-mesa-dev \
    libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop \
    libxml2-utils libncurses-dev openjdk-11-jdk \
    libssl-dev zlib1g-dev libbz2-dev libreadline-dev libxmlsec1-dev \
    libffi-dev liblzma-dev libyaml-dev

  if ! need_cmd bat && need_cmd batcat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi
}

configure_git_identity() {
  if ! need_cmd git; then
    return 0
  fi

  local existing_name existing_email
  existing_name="$(git config --global user.name 2>/dev/null || true)"
  existing_email="$(git config --global user.email 2>/dev/null || true)"

  if [[ -n "$existing_name" || -n "$existing_email" ]]; then
    log "Git identity already set (user.name/user.email); skipping."
    return 0
  fi

  local name email
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    name="${GIT_NAME:-}"
    email="${GIT_EMAIL:-}"
  else
    name="$(ask_line "Git user.name (leave blank to skip)" "${GIT_NAME:-}")"
    email="$(ask_line "Git user.email (leave blank to skip)" "${GIT_EMAIL:-}")"
  fi

  if [[ -z "${name:-}" || -z "${email:-}" ]]; then
    warn "Git identity not set (missing name/email)."
    return 0
  fi

  git config --global user.name "$name"
  git config --global user.email "$email"
  log "Git identity configured."
}
############################################
# Optional install steps
############################################
ensure_snapd() {
  if need_cmd snap; then return 0; fi
  log "Installing snapd (required for Snap installs)"
  apt_install snapd
  sudo systemctl enable --now snapd.socket >/dev/null 2>&1 || true
}

snap_install_classic() {
  local name="$1"
  if snap list "$name" >/dev/null 2>&1; then
    log "Snap already installed: $name"
  else
    log "Installing Snap: $name (classic)"
    sudo snap install "$name" --classic || { warn "Snap install failed: $name"; return 0; }
  fi
}

snap_install() {
  local name="$1"
  if snap list "$name" >/dev/null 2>&1; then
    log "Snap already installed: $name"
  else
    log "Installing Snap: $name"
    sudo snap install "$name" || { warn "Snap install failed: $name"; return 0; }
  fi
}

install_zsh_stack() {
  setup_managed_env

  if [[ "${SHELL:-}" != "$(command -v zsh)" ]]; then
    log "Setting default shell to zsh (may prompt for password)"
    sudo chsh -s "$(command -v zsh)" "${USER}" || warn "Could not change default shell. You can run: sudo chsh -s $(command -v zsh) ${USER}"
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
  # Ensure asdf >= 0.16 (Go rewrite) is installed as a binary on PATH.
  # Keep ASDF_DATA_DIR at ~/.asdf for plugins/installs/shims.
  local asdf_bin="$HOME/.local/bin/asdf"
  local asdf_ver="v0.18.0"
  local arch
  local tmp

  mkdir -p "$HOME/.local/bin"
  export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"

  if [[ -x "$asdf_bin" ]]; then
    return 0
  fi

  log "Installing asdf ${asdf_ver} (precompiled binary)"
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  case "$arch" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) die "Unsupported architecture for asdf binary: $arch" ;;
  esac

  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/asdf-vm/asdf/releases/download/${asdf_ver}/asdf-${asdf_ver}-linux-${arch}.tar.gz" -o "$tmp/asdf.tgz"
  tar -xzf "$tmp/asdf.tgz" -C "$tmp"
  install -m 0755 "$tmp/asdf" "$asdf_bin"
  rm -rf "$tmp"

  # Ensure shells load the managed env (already sets ~/.local/bin on PATH).
  setup_managed_env
}

asdf_source() {
  # Ensure the asdf binary we installed is used, and shims are available.
  export ASDF_DATA_DIR="${ASDF_DATA_DIR:-$HOME/.asdf}"
  export PATH="$HOME/.local/bin:$ASDF_DATA_DIR/shims:$PATH"
  hash -r 2>/dev/null || true

  # Basic sanity check
  if ! command -v asdf >/dev/null 2>&1; then
    die "asdf not found on PATH after install"
  fi

  local v
  v="$(asdf --version 2>/dev/null || true)"
  if [[ "$v" != v0.* && "$v" != "asdf version v0."* ]]; then
    warn "Unexpected asdf version output: $v"
  fi
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
    local v major
    v="$(node -v 2>/dev/null || true)"
    major="$(printf "%s" "$v" | sed -E 's/^v([0-9]+).*/\1/')"
    if [[ -n "$major" && "$major" == "$NODE_MAJOR" ]]; then
      log "Node already installed: ${v}"
      return 0
    fi
    warn "Node ${v} installed, but Node ${NODE_MAJOR}.x requested; upgrading."
  fi

  ensure_nodesource_repo
  apt_install nodejs

  mkdir -p "$HOME/.local/bin"
  if need_cmd corepack; then
    corepack enable --install-directory "$HOME/.local/bin" || true
    corepack prepare pnpm@latest --activate >/dev/null 2>&1 || true
  fi
}

install_go() {
  local arch tmp tarball
  if [[ -x /usr/local/go/bin/go ]]; then
    local have_ver
    have_ver="$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' | sed 's/^go//')"
    if [[ "$have_ver" == "$GO_VERSION" ]]; then
      log "Go already installed: ${have_ver}"
      return 0
    fi
  fi
  arch="$(arch_go)"
  log "Installing Go ${GO_VERSION} for ${arch}"
  tmp="$(mktemp -d)"
  tarball="go${GO_VERSION}.linux-${arch}.tar.gz"

  curl -fsSL "https://go.dev/dl/${tarball}" -o "${tmp}/${tarball}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${tmp}/${tarball}"
  rm -rf "$tmp"

  setup_managed_env
  # shellcheck disable=SC2016
  append_once 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.config/ai-forge/env.zsh"
  # shellcheck disable=SC2016
  append_once 'export PATH="/usr/local/go/bin:$PATH"' "$HOME/.config/ai-forge/env.sh"
}

install_rust() {
  if need_cmd rustup; then
    log "Rust already installed: $(rustc --version 2>/dev/null || true)"
  else
    log "Installing Rust via rustup"
    curl -fsSL https://sh.rustup.rs | sh -s -- -y
  fi

  # Make cargo available in the current session
  if [[ -f "$HOME/.cargo/env" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
  fi
}

install_htmlq() {
  if need_cmd htmlq; then
    log "htmlq already installed: $(htmlq --version 2>/dev/null || true)"
    return 0
  fi

  if ! need_cmd cargo; then
    die "htmlq requires Rust (cargo). Please install Rust (rustup) first."
  fi

  log "Installing htmlq via cargo"
  if cargo install htmlq --locked; then
    :
  else
    warn "htmlq install failed."
    record_best_effort_failure "htmlq install failed"
  fi
}



install_pgvector_from_source() {
  local have_ver
  have_ver="$(pgvector_control_version || true)"
  if [[ -n "$have_ver" && "$have_ver" == "$PGVECTOR_VERSION" ]]; then
    log "pgvector ${PGVECTOR_VERSION} already installed (extension files)"
    return 0
  fi
  # Ensure build deps for pgvector (best effort).
  apt_install_best_effort postgresql-server-dev-17 build-essential
  log "Installing pgvector v${PGVECTOR_VERSION} from source"
  cd /tmp
  rm -rf pgvector
  if ! git clone --branch "v${PGVECTOR_VERSION}" https://github.com/pgvector/pgvector.git; then
    warn "pgvector clone failed; skipping."
    record_best_effort_failure "pgvector clone failed"
    cd ~
    return 0
  fi
  cd pgvector
  if ! make; then
    warn "pgvector build failed; skipping."
    record_best_effort_failure "pgvector build failed"
    cd ~
    return 0
  fi
  if ! sudo make install; then
    warn "pgvector install failed; skipping."
    record_best_effort_failure "pgvector install failed"
  fi
  cd ~
}

create_vector_extension() {
  if ! need_cmd psql; then
    warn "psql not found; Postgres may not be installed."
    return 0
  fi
  local db_ver
  db_ver="$(pgvector_db_version || true)"
  if [[ -n "$db_ver" ]]; then
    if [[ "$db_ver" == "$PGVECTOR_VERSION" ]]; then
      log "pgvector extension already present in DB (version ${db_ver})"
      return 0
    fi
    log "Updating pgvector extension from ${db_ver} to ${PGVECTOR_VERSION} (best effort)"
    if sudo -u postgres psql -c "ALTER EXTENSION vector UPDATE TO '${PGVECTOR_VERSION}';"; then
      :
    else
      warn "pgvector extension update failed; verify extension files and retry."
      record_best_effort_failure "pgvector extension update failed"
    fi
    return 0
  fi
  log "Creating pgvector extension (best effort)"
  if sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;"; then
    :
  else
    warn "pgvector extension create failed."
    record_best_effort_failure "pgvector extension create failed"
  fi
}

install_db_stack_full() {
  ensure_pgdg_repo
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
  if need_cmd ollama; then
    if ollama list 2>/dev/null \
      | awk -v m="${OLLAMA_PULL_MODEL}" '{ if ($1==m || index($1, m ":")==1) {found=1} } END { exit !found }'; then
      log "Ollama model already present: ${OLLAMA_PULL_MODEL}"
      return 0
    fi
  fi
  local started=0 pid=""
  if ! pgrep -x ollama >/dev/null 2>&1; then
    ollama serve >/dev/null 2>&1 & pid=$!
    started=1
    sleep 2
  fi
  if ollama pull "${OLLAMA_PULL_MODEL}"; then
    :
  else
    warn "Model pull failed; retry later: ollama pull ${OLLAMA_PULL_MODEL}"
    record_best_effort_failure "ollama pull failed: ${OLLAMA_PULL_MODEL}"
  fi
  if [[ "$started" == "1" ]]; then kill "$pid" 2>/dev/null || true; fi
}

install_vscode_snap() {
  ensure_snapd
  snap_install_classic code
}

install_obsidian_snap() {
  ensure_snapd
  snap_install_classic obsidian
}

############################################
# Main flow: confirm versions -> yes/no -> install
############################################
print_defaults() {
  cat <<EOF
Ubuntu Dev Bootstrap - installer.sh (Ubuntu 24.04 LTS)

Defaults (override via env or prompted):
  Node major:     ${NODE_MAJOR}
  Go version:     ${GO_VERSION}
  Ruby version:   ${RUBY_VERSION}
  Python version: ${PYTHON_VERSION}
  Erlang version: ${ERLANG_VERSION}
  Elixir version: ${ELIXIR_VERSION}
  pgvector ver:   ${PGVECTOR_VERSION}
  Ollama model:   ${OLLAMA_PULL_MODEL}

Core packages:
  - Installed automatically before optional components.

EOF
}


############################################
# Agent tooling (optional, grouped)
############################################

latest_python_stable() {
  # Picks the latest stable CPython from asdf list-all output, ignoring prereleases.
  # Example lines include: 3.12.7, 3.13.0, etc. We exclude anything with letters.
  asdf list all python 2>/dev/null \
    | awk '/^[0-9]+\.[0-9]+\.[0-9]+$/{print}' \
    | tail -n 1
}

install_uv() {
  if need_cmd uv; then
    log "uv already installed: $(uv --version 2>/dev/null || true)"
    return 0
  fi
  log "Installing uv (Astral)"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # uv installs to ~/.local/bin by default
  export PATH="$HOME/.local/bin:$PATH"
}

install_bun() {
  if need_cmd bun; then
    log "bun already installed: $(bun --version 2>/dev/null || true)"
    return 0
  fi
  log "Installing bun"
  curl -fsSL https://bun.sh/install | bash
  export PATH="$HOME/.bun/bin:$PATH"
}

install_python_asdf() {
  install_asdf
  asdf_source

  apt_install tcl-dev tk-dev

  asdf plugin add python >/dev/null 2>&1 || true

  local py_ver
  if [[ -n "${PYTHON_VERSION:-}" ]]; then
    py_ver="${PYTHON_VERSION}"
  else
    py_ver="$(latest_python_stable || true)"
  fi
  if [[ -z "${py_ver}" ]]; then
    warn "Could not determine latest Python version from asdf. Skipping Python install."
    return 0
  fi

  if ! asdf list python 2>/dev/null | grep -q "${py_ver}"; then
    log "Installing Python ${py_ver} via asdf"
    asdf install python "${py_ver}"
  else
    log "Python ${py_ver} already installed via asdf"
  fi

  # Set as user default (writes to ~/.tool-versions)
  asdf set -u python "${py_ver}"
  asdf reshim python
}

install_python_agent_libs() {
  install_uv

  if ! need_cmd python; then
    warn "python not found; skipping Python agent tooling."
    return 0
  fi

  local constraints_arg=()
  if [[ -n "${PY_AGENT_CONSTRAINTS:-}" && -f "${PY_AGENT_CONSTRAINTS}" ]]; then
    constraints_arg=(-c "$PY_AGENT_CONSTRAINTS")
  else
    warn "Python constraints file not found; installing without constraints."
  fi

  mkdir -p "$(dirname "$PY_VENV_DIR")"
  if [[ -d "$PY_VENV_DIR" ]]; then
    local venv_py_ver=""
    if [[ -x "$PY_VENV_DIR/bin/python" ]]; then
      venv_py_ver="$("$PY_VENV_DIR/bin/python" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true)"
    fi
    if [[ -n "${PYTHON_VERSION:-}" && "$venv_py_ver" != "$PYTHON_VERSION" ]]; then
      warn "Agent venv uses Python ${venv_py_ver:-unknown}, expected ${PYTHON_VERSION}; recreating."
      rm -rf "$PY_VENV_DIR"
    fi
  fi

  if [[ ! -d "$PY_VENV_DIR" ]]; then
    log "Creating agent venv: $PY_VENV_DIR"
    uv venv "$PY_VENV_DIR"
  else
    log "Agent venv already exists: $PY_VENV_DIR"
  fi

  log "Installing Python agent tooling into venv (uv pip, best effort)"
  local pkgs=(
    langchain-openai
    llama-index
    autogen
    playwright
    beautifulsoup4
    duckduckgo-search
  )
  local p
  for p in "${pkgs[@]}"; do
    if uv pip install --python "$PY_VENV_DIR/bin/python" "${constraints_arg[@]}" "$p"; then
      :
    else
      warn "Python package install failed: $p"
      record_best_effort_failure "python package install failed: $p"
    fi
  done
}

install_node_agent_tooling() {
  # Assumes node is installed. Installs CLIs used for agent workflows.
  if ! need_cmd npm; then
    warn "npm not found; skipping Node agent tooling."
    return 0
  fi

  # For native deps (e.g., PAM bindings used by some CLIs)
  apt_install libpam0g-dev

  log "Installing global Node agent CLIs (best effort)"
  # Use npm -g for compatibility; corepack/pnpm remains available.
  local pkgs=(
    moltbot@latest
    molthub@latest
    @google/gemini-cli@latest
    @steipete/bird@latest
    markdansi
    sweetlink
    mcporter
    tokentally
    sweet-cookie
    axios
    cheerio
    lodash
    express
    nodemon
    shiki
  )
  local p
  for p in "${pkgs[@]}"; do
    if sudo npm install -g "$p"; then
      :
    else
      warn "npm global install failed: $p"
      record_best_effort_failure "npm global install failed: $p"
    fi
  done

  # Playwright OS deps + browser install (best effort)
  log "Installing Playwright browsers + deps (best effort)"
  if npx -y playwright install --with-deps; then
    :
  else
    warn "Playwright install/deps step failed."
    record_best_effort_failure "playwright install/deps failed"
  fi
}

install_docker() {
  if need_cmd docker; then
    log "Docker already installed: $(docker --version 2>/dev/null || true)"
    return 0
  fi
  log "Installing Docker (get.docker.com convenience script)"
  curl -fsSL https://get.docker.com | sh || { warn "Docker install failed."; return 0; }
  sudo usermod -aG docker "${USER}" || true
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
}


install_tidewave() {
  # Installs tidewave CLI to ~/.local/bin (best effort)
  if need_cmd tidewave; then
    log "tidewave already installed"
    return 0
  fi
  log "Installing tidewave CLI (best effort)"
  mkdir -p "$HOME/.local/bin"

  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) warn "Unknown architecture for tidewave CLI: $(uname -m). Skipping."; return 0 ;;
  esac

  local url
  # Tidewave docs show musl builds; adjust if upstream changes.
  url="https://github.com/tidewave-ai/tidewave_app/releases/latest/download/tidewave-cli-${arch}-unknown-linux-musl"

  if curl -fsSL "$url" -o "$HOME/.local/bin/tidewave"; then
    chmod +x "$HOME/.local/bin/tidewave"
    log "Installed tidewave to ~/.local/bin/tidewave"
  else
    warn "Failed to download tidewave CLI from GitHub releases. Skipping."
  fi
}



install_wacli() {
  if need_cmd wacli; then
    log "wacli already installed"
    return 0
  fi
  export PATH="/usr/local/go/bin:$PATH"
  if ! need_cmd go; then
    warn "go not found; skipping wacli."
    return 0
  fi
  log "Installing wacli via go install (best effort)"
  GOBIN="$HOME/.local/bin" go install github.com/steipete/wacli/cmd/wacli@latest || warn "wacli install failed."
}

install_gogcli() {
  # The command is "gog" (from gogcli project)
  if need_cmd gog; then
    log "gog already installed"
    return 0
  fi
  export PATH="/usr/local/go/bin:$PATH"
  if ! need_cmd go; then
    warn "go not found; skipping gog."
    return 0
  fi
  log "Installing gog (gogcli) via go install (best effort)"
  GOBIN="$HOME/.local/bin" go install github.com/steipete/gogcli/cmd/gog@latest || warn "gog install failed."
}


install_agent_tooling_bundle() {
  log "🧰 Installing agent tooling bundle..."

  # Ensure prerequisites: Node and Rust are expected for this bundle.
  # Node is needed for moltbot + CLIs; Rust is needed for cargo-installed tools like.
  install_node
  install_go
  install_rust

  install_htmlq

  install_bun
  install_python_agent_libs
  install_node_agent_tooling
  install_wacli
  install_gogcli
  install_docker
  install_tidewave

  log "Agent tooling bundle complete."
}


main() {
  sudo_keepalive
  setup_managed_env

  install_core_packages_mandatory

  print_defaults

  if [[ "$NONINTERACTIVE" != "1" ]]; then
    NODE_MAJOR="$(ask_line "Node major to install" "$NODE_MAJOR")"
    GO_VERSION="$(ask_line "Go version to install" "$GO_VERSION")"
    RUBY_VERSION="$(ask_line "Ruby version (asdf) to install" "$RUBY_VERSION")"
    PYTHON_VERSION="$(ask_line "Python version (asdf) to install" "$PYTHON_VERSION")"
    ERLANG_VERSION="$(ask_line "Erlang version (asdf) to install" "$ERLANG_VERSION")"
    ELIXIR_VERSION="$(ask_line "Elixir version (asdf) to install" "$ELIXIR_VERSION")"
    PGVECTOR_VERSION="$(ask_line "pgvector version to build" "$PGVECTOR_VERSION")"
    OLLAMA_PULL_MODEL="$(ask_line "Ollama model to pull (empty to skip)" "$OLLAMA_PULL_MODEL")"
  fi

  local DO_ZSH DO_RUBY DO_PYTHON DO_BEAM DO_NODE DO_GO DO_DB DO_VSCODE DO_OBSIDIAN DO_OLLAMA DO_PULL_MODEL DO_RUST DO_HTMLQ DO_AGENT_TOOLING

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    DO_ZSH="N"
    DO_RUBY="N"
    DO_PYTHON="N"
    DO_BEAM="N"
    DO_NODE="N"
    DO_GO="N"
    DO_RUST="N"
    DO_HTMLQ="N"
    DO_DB="N"
    DO_VSCODE="N"
    DO_OBSIDIAN="N"
    DO_OLLAMA="N"
    DO_PULL_MODEL="N"
    DO_AGENT_TOOLING="N"

    if [[ "${DEFAULT_SELECT:-}" == "all" ]]; then
      DO_ZSH="Y"
      DO_RUBY="Y"
      DO_PYTHON="Y"
      DO_BEAM="Y"
      DO_NODE="Y"
      DO_GO="Y"
      DO_RUST="Y"
      DO_HTMLQ="Y"
      DO_DB="Y"
      DO_VSCODE="Y"
      DO_OBSIDIAN="Y"
      DO_OLLAMA="Y"
      DO_PULL_MODEL="Y"
      DO_AGENT_TOOLING="Y"
    elif [[ -n "${DEFAULT_SELECT:-}" ]]; then
      IFS=',' read -r -a _sel <<<"${DEFAULT_SELECT}"
      for n in "${_sel[@]}"; do
        case "${n// /}" in
          1) DO_ZSH="Y" ;;
          2) DO_RUBY="Y" ;;
          3) DO_PYTHON="Y" ;;
          4) DO_BEAM="Y" ;;
          5) DO_NODE="Y" ;;
          6) DO_GO="Y" ;;
          7) DO_RUST="Y" ;;
          8) DO_HTMLQ="Y" ;;
          9) DO_DB="Y" ;;
          10) DO_VSCODE="Y" ;;
          11) DO_OBSIDIAN="Y" ;;
          12) DO_OLLAMA="Y" ;;
          13) DO_PULL_MODEL="Y" ;;
          14) DO_AGENT_TOOLING="Y" ;;
          *) warn "Unknown DEFAULT_SELECT entry: ${n}" ;;
        esac
      done
    else
      warn "NONINTERACTIVE=1 but DEFAULT_SELECT is not set; skipping optional installs."
    fi
  else
    DO_ZSH="$(ask_yn "Install Zsh + Oh My Zsh (non-destructive)?" "Y")"
    DO_RUBY="$(ask_yn "Install Ruby via asdf (Bundler + Rails)?" "Y")"
    DO_PYTHON="$(ask_yn "Install Python via asdf?" "Y")"
    DO_BEAM="$(ask_yn "Install Erlang + Elixir + Phoenix via asdf?" "Y")"
    DO_NODE="$(ask_yn "Install Node.js via NodeSource?" "Y")"
    DO_GO="$(ask_yn "Install Go to /usr/local/go?" "Y")"
    DO_RUST="$(ask_yn "Install Rust via rustup?" "Y")"
    DO_HTMLQ="$(ask_yn "Install htmlq (via cargo; requires Rust)?" "Y")"
    DO_DB="$(ask_yn "Install full DB stack (Postgres 17 + PostGIS + pgvector)?" "Y")"
    DO_VSCODE="$(ask_yn "Install VS Code via Snap (--classic)?" "Y")"
    DO_OBSIDIAN="$(ask_yn "Install Obsidian via Snap?" "Y")"
    DO_OLLAMA="$(ask_yn "Install Ollama?" "Y")"
    DO_PULL_MODEL="$(ask_yn "Pull Ollama model (${OLLAMA_PULL_MODEL:-<none>})?" "Y")"
    DO_AGENT_TOOLING="$(ask_yn "Install agent tooling bundle (Python/uv libs, Node AI CLIs incl. moltbot, Bun, Playwright deps, Docker, htmlq)?" "Y")"
    DO_GIT_IDENTITY="$(ask_yn "Configure git user.name/user.email?" "Y")"
  fi

  if [[ "$DO_HTMLQ" == "Y" ]]; then
    DO_RUST="Y"
  fi

  if [[ "$DO_AGENT_TOOLING" == "Y" ]]; then
    DO_PYTHON="Y"
  fi

  if [[ "$DO_OLLAMA" != "Y" ]]; then
    DO_PULL_MODEL="N"
  fi

  [[ "$DO_ZSH" == "Y" ]] && install_zsh_stack
  [[ "$DO_RUBY" == "Y" ]] && install_ruby_asdf
  [[ "$DO_PYTHON" == "Y" ]] && install_python_asdf
  [[ "$DO_BEAM" == "Y" ]] && install_beam_and_phoenix
  [[ "$DO_NODE" == "Y" ]] && install_node
  [[ "$DO_GO" == "Y" ]] && install_go
  [[ "$DO_RUST" == "Y" ]] && install_rust
  [[ "$DO_HTMLQ" == "Y" ]] && install_htmlq
  [[ "$DO_DB" == "Y" ]] && install_db_stack_full
  [[ "$DO_VSCODE" == "Y" ]] && install_vscode_snap
  [[ "$DO_OBSIDIAN" == "Y" ]] && install_obsidian_snap
  [[ "$DO_OLLAMA" == "Y" ]] && install_ollama
  [[ "$DO_PULL_MODEL" == "Y" ]] && pull_ollama_model

  [[ "$DO_AGENT_TOOLING" == "Y" ]] && install_agent_tooling_bundle
  [[ "${DO_GIT_IDENTITY:-N}" == "Y" ]] && configure_git_identity

  log "Complete."
  if (( ${#BEST_EFFORT_FAILURES[@]} > 0 )); then
    warn "Best-effort step summary (some items failed):"
    local item
    for item in "${BEST_EFFORT_FAILURES[@]}"; do
      warn "- ${item}"
    done
  fi
  warn "Notes:"
  warn "- If your login shell was changed to zsh: it applies next login."
  warn "- Managed env files:"
  warn "  - $HOME/.config/ai-forge/env.sh (bash/sh)"
  warn "  - $HOME/.config/ai-forge/env.zsh (zsh)"
}

main "$@"
