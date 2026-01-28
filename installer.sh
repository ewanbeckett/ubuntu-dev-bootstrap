#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

############################################
# Defaults (override via env or prompts)
############################################
: "${NONINTERACTIVE:=0}"               # 1 = don't prompt
: "${DEFAULT_SELECT:=}"                # e.g. "all" or "1,2,8"

# Match original gist defaults
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

apt_update() {
  log "Updating apt indices"
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
}

apt_install() {
  log "Installing apt packages: $*"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
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

############################################
# Install steps
############################################
install_base() {
  apt_install \
    ca-certificates curl wget gnupg lsb-release software-properties-common \
    git unzip zip tar xz-utils build-essential \
    jq \
    python3 python3-venv python3-pip \
    ripgrep fd-find htop tmux
}

install_quality_of_life_cli() {
  apt_install \
    fzf bat eza tree direnv tldr \
    neovim \
    shellcheck shfmt \
    entr
  # bat is sometimes "batcat"
  if ! need_cmd bat && need_cmd batcat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi
}

install_automation_tooling() {
  apt_install \
    make yq parallel moreutils graphviz
  if ! need_cmd just; then apt_install just || true; fi
  if ! need_cmd watchexec; then apt_install watchexec || true; fi
}

install_git_extras() {
  apt_install git-lfs
  git lfs install >/dev/null 2>&1 || true

  if ! need_cmd gh; then
    ensure_keyrings_dir
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo tee /etc/apt/keyrings/githubcli.gpg >/dev/null
    sudo chmod go+r /etc/apt/keyrings/githubcli.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    apt_update
    apt_install gh
  else
    log "gh already installed"
  fi
}

install_zsh_stack() {
  apt_install zsh
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

install_docker() {
  if need_cmd docker; then
    log "Docker already installed"
    return 0
  fi

  ensure_keyrings_dir
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
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

install_rust() {
  if need_cmd rustup; then
    log "rustup already installed"
  else
    curl -fsSL https://sh.rustup.rs | sh -s -- -y
  fi
}

install_bun() {
  if need_cmd bun; then
    log "Bun already installed: $(bun --version)"
  else
    curl -fsSL https://bun.sh/install | bash
  fi
}

install_uv() {
  if need_cmd uv; then
    log "uv already installed"
  else
    curl -fsSL https://astral.sh/uv/install.sh | sh
  fi
}

install_python_venv_and_tools() {
  need_cmd uv || die "uv is required for this step (install uv first)."

  uv venv "$PY_VENV_DIR"
  setup_managed_env
  append_once 'export PATH="$AI_FORGE_VENV/bin:$PATH"' "$HOME/.config/ai-forge/env.zsh"
  append_once 'export PATH="$AI_FORGE_VENV/bin:$PATH"' "$HOME/.config/ai-forge/env.sh"

  "$PY_VENV_DIR/bin/python" -m pip install --upgrade pip >/dev/null
  "$PY_VENV_DIR/bin/python" -m pip install -U \
    ipython \
    ruff black mypy pre-commit \
    python-dotenv rich httpx pyyaml requests \
    openai anthropic \
    jinja2 \
    || true
}

install_asdf() {
  if [[ -d "$HOME/.asdf" ]]; then
    log "asdf already installed"
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

  apt_install autoconf bison libssl-dev libyaml-dev libreadline6-dev zlib1g-dev \
    libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev

  asdf plugin add ruby >/dev/null 2>&1 || true
  if ! asdf list ruby 2>/dev/null | grep -q "$RUBY_VERSION"; then
    log "Installing Ruby ${RUBY_VERSION} via asdf"
    asdf install ruby "$RUBY_VERSION"
  fi
  asdf set -u ruby "$RUBY_VERSION"
  gem install bundler rails
}

install_beam_and_phoenix() {
  install_asdf
  asdf_source

  # deps (match original intent: wxWidgets + OpenJDK + build deps + inotify-tools for Phoenix)
  apt_install \
    inotify-tools \
    autoconf m4 \
    libwxgtk3.2-dev libwxgtk-webview3.2-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libpng-dev libssh-dev unixodbc-dev \
    libncurses-dev \
    openjdk-11-jdk

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

  # Phoenix installer
  mix local.hex --force
  mix archive.install hex phx_new --force
}

install_python_asdf_latest() {
  install_asdf
  asdf_source

  asdf plugin add python >/dev/null 2>&1 || true
  local py
  py="$(asdf list all python | grep -E '^[0-9.]+$' | tail -1)"
  [[ -n "$py" ]] || die "Could not determine latest python from asdf"
  log "Installing Python ${py} via asdf"
  asdf install python "$py" || true
  asdf set -u python "$py" || true
}

install_vscode_snap() {
  ensure_snapd
  snap_install_classic code
}

install_obsidian_snap() {
  ensure_snapd
  snap_install obsidian
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

install_postgres17_repo_and_pkgs() {
  ensure_keyrings_dir
  if [[ ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    log "Adding PGDG repository (Postgres 17)"
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
    # shellcheck disable=SC1091
    UBUNTU_CODENAME="$(lsb_release -cs)"
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${UBUNTU_CODENAME}-pgdg main" \
      | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  else
    log "PGDG repo already configured"
  fi

  apt_update
  apt_install \
    postgresql-17 postgresql-client-17 \
    postgresql-17-postgis-3 postgresql-server-dev-17
}

install_pgvector_from_source() {
  apt_install git build-essential
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
    warn "psql not found; install Postgres first."
    return 0
  fi
  log "Creating pgvector extension (if Postgres is running and accessible)"
  sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS vector;" || true
}

install_agent_tools_and_playwright() {
  install_node

  log "Installing global Node tooling (agent + utilities)"
  sudo npm install -g \
    pnpm \
    clawdbot@latest molthub@latest \
    @google/gemini-cli@latest \
    @steipete/bird@latest \
    vibetunnel@latest \
    markdansi \
    sweetlink \
    mcporter \
    tokentally \
    sweet-cookie \
    || true

  # Playwright deps
  if need_cmd npx; then
    npx playwright install --with-deps || true
  fi

  # Python agent libs (keep optional-ish)
  if need_cmd uv; then
    log "Installing common Python agent libraries (via uv)"
    uv pip install --system \
      langchain-openai llama-index crewai autogen aider-chat \
      playwright beautifulsoup4 duckduckgo-search \
      || true
  fi
}

install_wacli_gogcli_tidewave() {
  install_go
  mkdir -p "$HOME/.local/bin"
  export PATH="/usr/local/go/bin:$PATH"

  log "Building wacli"
  cd /tmp
  rm -rf wacli
  git clone https://github.com/steipete/wacli.git
  cd wacli
  go build -tags sqlite_fts5 -o "$HOME/.local/bin/wacli" ./cmd/wacli

  log "Building gogcli"
  cd /tmp
  rm -rf gogcli
  git clone https://github.com/steipete/gogcli.git
  cd gogcli
  go build -o "$HOME/.local/bin/gog" ./cmd/gog

  log "Installing tidewave (latest release)"
  curl -L "https://github.com/tidewave-ai/tidewave/releases/latest/download/tidewave-x86_64-unknown-linux-gnu.tar.gz" \
    | tar -xz -C "$HOME/.local/bin" || true

  cd ~
}

enable_linger() {
  log "Enabling linger for user services"
  sudo loginctl enable-linger "$USER" || true
}

install_ansible() { apt_install ansible; }

install_terraform_repo() {
  if need_cmd terraform; then
    log "Terraform already installed: $(terraform version | head -n1 || true)"
    return 0
  fi
  ensure_keyrings_dir
  curl -fsSL https://apt.releases.hashicorp.com/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/hashicorp.gpg
  sudo chmod a+r /etc/apt/keyrings/hashicorp.gpg
  UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com ${UBUNTU_CODENAME} main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  apt_update
  apt_install terraform
}

############################################
# Menu
############################################
print_menu() {
  cat <<EOF
Ubuntu Dev Bootstrap - installer.sh

Defaults (override via env or prompted):
  Node major:     ${NODE_MAJOR}
  Go version:     ${GO_VERSION}
  Ruby version:   ${RUBY_VERSION}
  Erlang version: ${ERLANG_VERSION}
  Elixir version: ${ELIXIR_VERSION}
  pgvector ver:   ${PGVECTOR_VERSION}
  Ollama model:   ${OLLAMA_PULL_MODEL}

Select items (comma-separated) or 'all':

  1) Base packages
  2) QoL CLI tools
  3) Automation tooling
  4) Git extras (git-lfs, gh)
  5) Zsh + Oh My Zsh (non-destructive)
  6) Docker + Compose
  7) Node.js (NodeSource)
  8) Go (upstream tarball)
  9) Rust (rustup)
 10) Bun
 11) uv
 12) Python venv + dev tools
 13) asdf + Ruby (Rails)
 14) asdf + Erlang + Elixir + Phoenix
 15) asdf + Python (latest stable)
 16) VS Code (Snap)
 17) Obsidian (Snap)
 18) Postgres 17 + PostGIS (PGDG)
 19) pgvector from source
 20) Create pgvector extension in Postgres
 21) Ollama
 22) Pull Ollama model
 23) Agent tools + Playwright
 24) wacli + gogcli + tidewave
 25) Enable linger (loginctl)
 26) Ansible
 27) Terraform (Hashi repo)

EOF
}

normalize_selection() {
  local s="${1:-}"
  s="${s// /}"
  if [[ "$s" == "all" ]]; then
    echo "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27"
  else
    echo "$s"
  fi
}

has_choice() {
  local list="$1" item="$2"
  [[ ",${list}," == *",${item},"* ]]
}

main() {
  is_ubuntu || die "This installer targets Ubuntu. (/etc/os-release does not look like Ubuntu.)"
  sudo_keepalive
  setup_managed_env

  # Version prompts (only when interactive)
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
    [[ -n "$selection" ]] || die "NONINTERACTIVE=1 requires DEFAULT_SELECT (e.g. all or 1,2,3)"
  else
    print_menu
    selection="$(ask_line "Enter selection" "")"
    selection="$(normalize_selection "$selection")"
    [[ -n "$selection" ]] || die "No selection provided."
  fi

  # One apt update up-front if any apt-heavy selected
  apt_update

  has_choice "$selection" 1  && install_base
  has_choice "$selection" 2  && install_quality_of_life_cli
  has_choice "$selection" 3  && install_automation_tooling
  has_choice "$selection" 4  && install_git_extras
  has_choice "$selection" 5  && install_zsh_stack
  has_choice "$selection" 6  && install_docker
  has_choice "$selection" 7  && install_node
  has_choice "$selection" 8  && install_go
  has_choice "$selection" 9  && install_rust
  has_choice "$selection" 10 && install_bun
  has_choice "$selection" 11 && install_uv
  has_choice "$selection" 12 && install_python_venv_and_tools
  has_choice "$selection" 13 && install_ruby_asdf
  has_choice "$selection" 14 && install_beam_and_phoenix
  has_choice "$selection" 15 && install_python_asdf_latest
  has_choice "$selection" 16 && install_vscode_snap
  has_choice "$selection" 17 && install_obsidian_snap
  has_choice "$selection" 18 && install_postgres17_repo_and_pkgs
  has_choice "$selection" 19 && install_pgvector_from_source
  has_choice "$selection" 20 && create_vector_extension
  has_choice "$selection" 21 && install_ollama
  has_choice "$selection" 22 && pull_ollama_model
  has_choice "$selection" 23 && install_agent_tools_and_playwright
  has_choice "$selection" 24 && install_wacli_gogcli_tidewave
  has_choice "$selection" 25 && enable_linger
  has_choice "$selection" 26 && install_ansible
  has_choice "$selection" 27 && install_terraform_repo

  log "Complete."
  warn "Notes:"
  warn "- If Docker was installed and you were added to the docker group: log out and back in."
  warn "- If your login shell was changed to zsh: it applies next login."
  warn "- Managed env files:"
  warn "  - $HOME/.config/ai-forge/env.sh (bash/sh)"
  warn "  - $HOME/.config/ai-forge/env.zsh (zsh)"
}

main "$@"
