#!/usr/bin/env bash
# interactive-menu-installer.sh
# Ubuntu interactive “pick your stack” installer for vibe-coding + automation.
#
# Highlights:
# - Menu-driven multi-select install.
# - Snap ONLY for VS Code + Obsidian (Ubuntu App Store style).
# - Asks (nicely) whether to use default language versions or override:
#     - Node.js major (NodeSource)
#     - Go version (upstream tarball)
#     - Ruby version strategy (apt default OR ruby-build via asdf)  <-- optional path
#     - Terraform version (apt from Hashi repo OR pinned binary)    <-- we do repo default by default
# - Doesn’t clobber dotfiles: writes managed env into ~/.config/ai-forge/env.{sh,zsh}
#
# Usage:
#   chmod +x interactive-menu-installer.sh
#   ./interactive-menu-installer.sh
#
# Non-interactive:
#   NONINTERACTIVE=1 DEFAULT_SELECT="all" ./interactive-menu-installer.sh
#   NONINTERACTIVE=1 DEFAULT_SELECT="1,2,8" ./interactive-menu-installer.sh
#
# Version overrides in non-interactive mode:
#   NODE_MAJOR=22 GO_VERSION=1.22.7 TF_INSTALL_METHOD=repo ./interactive-menu-installer.sh

set -euo pipefail
IFS=$'\n\t'

############################
# Defaults (override via env)
############################
: "${NONINTERACTIVE:=0}"                   # 1 = don't prompt
: "${DEFAULT_SELECT:=}"                    # e.g. "all" or "1,2,8"

: "${DEFAULT_NODE_MAJOR:=20}"
: "${NODE_MAJOR:=$DEFAULT_NODE_MAJOR}"

: "${DEFAULT_GO_VERSION:=1.22.7}"
: "${GO_VERSION:=$DEFAULT_GO_VERSION}"

# Ruby strategy:
#   apt   -> ruby-full from Ubuntu repo (version depends on Ubuntu)
#   asdf  -> install asdf + ruby plugin and a specific version
: "${DEFAULT_RUBY_STRATEGY:=apt}"
: "${RUBY_STRATEGY:=$DEFAULT_RUBY_STRATEGY}"
: "${DEFAULT_RUBY_VERSION:=3.3.6}"         # used only if RUBY_STRATEGY=asdf
: "${RUBY_VERSION:=$DEFAULT_RUBY_VERSION}"

# Terraform install method:
#   repo  -> HashiCorp apt repo (latest available in repo)
#   snap  -> snap install terraform (if you prefer snaps)
: "${DEFAULT_TF_INSTALL_METHOD:=repo}"
: "${TF_INSTALL_METHOD:=$DEFAULT_TF_INSTALL_METHOD}"

: "${PY_VENV_DIR:=$HOME/.venvs/agents}"
: "${DEFAULT_OLLAMA_PULL_MODEL:=llama3.1:8b}"
: "${OLLAMA_PULL_MODEL:=$DEFAULT_OLLAMA_PULL_MODEL}"  # empty to skip default pull

############################
# Logging
############################
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

############################
# Helpers
############################
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
    read -r -p "${prompt} [default: ${def}] " ans </dev/tty || ans=""
    [[ -z "$ans" ]] && ans="$def"
  else
    read -r -p "${prompt} " ans </dev/tty || ans=""
  fi
  echo "$ans"
}

ask_yesno() {
  # ask_yesno "Question" "yes|no"
  local q="$1"
  local def="${2:-yes}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$def" == "yes" ]] && return 0 || return 1
  fi
  local yn="[y/N]"
  [[ "$def" == "yes" ]] && yn="[Y/n]"
  while true; do
    read -r -p "${q} ${yn} " a </dev/tty || a=""
    a="${a,,}"
    [[ -z "$a" ]] && a="$def"
    case "$a" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

normalize_selection() {
  local s="${1//,/ }"
  s="${s//;/ }"
  s="${s//  / }"
  echo "$s"
}

has_choice() {
  local choices="$1"
  local n="$2"
  [[ " $choices " == *" $n "* ]] && return 0 || return 1
}

banner_versions() {
  cat <<EOF

---------------- Default Versions ----------------
Node.js major (NodeSource):   ${DEFAULT_NODE_MAJOR}
Go (upstream):               ${DEFAULT_GO_VERSION}
Ruby strategy:               ${DEFAULT_RUBY_STRATEGY}  (apt default OR asdf pinned)
Ruby pinned version (asdf):  ${DEFAULT_RUBY_VERSION}
Terraform install method:    ${DEFAULT_TF_INSTALL_METHOD}  (repo or snap)
Ollama default model pull:   ${DEFAULT_OLLAMA_PULL_MODEL}
--------------------------------------------------

EOF
}

configure_versions_interactively() {
  # Only ask about versions for selected language/tool items.
  local selection="$1"

  banner_versions

  if has_choice "$selection" 6; then
    if ask_yesno "Node.js: use default major ${DEFAULT_NODE_MAJOR}?" "yes"; then
      NODE_MAJOR="$DEFAULT_NODE_MAJOR"
    else
      NODE_MAJOR="$(ask_line "Enter Node.js major (e.g. 18, 20, 22)" "$NODE_MAJOR")"
      [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || die "NODE_MAJOR must be a number"
    fi
    log "Node.js major set to: ${NODE_MAJOR}"
  fi

  if has_choice "$selection" 7; then
    if ask_yesno "Go: use default version ${DEFAULT_GO_VERSION}?" "yes"; then
      GO_VERSION="$DEFAULT_GO_VERSION"
    else
      GO_VERSION="$(ask_line "Enter Go version (e.g. 1.22.7)" "$GO_VERSION")"
      [[ "$GO_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "GO_VERSION format looks wrong (expected like 1.22.7)"
    fi
    log "Go version set to: ${GO_VERSION}"
  fi

  if has_choice "$selection" 12; then
    if ask_yesno "Ruby: use Ubuntu apt default (simplest)?" "yes"; then
      RUBY_STRATEGY="apt"
    else
      RUBY_STRATEGY="asdf"
      RUBY_VERSION="$(ask_line "Enter Ruby version to install via asdf" "$DEFAULT_RUBY_VERSION")"
    fi
    log "Ruby strategy: ${RUBY_STRATEGY}${RUBY_STRATEGY:+ }${RUBY_STRATEGY:+"$( [[ "$RUBY_STRATEGY" == "asdf" ]] && echo "(version ${RUBY_VERSION})" || true )"}"
  fi

  if has_choice "$selection" 18; then
    if ask_yesno "Terraform: use HashiCorp apt repo (recommended)?" "yes"; then
      TF_INSTALL_METHOD="repo"
    else
      TF_INSTALL_METHOD="snap"
    fi
    log "Terraform method: ${TF_INSTALL_METHOD}"
  fi

  if has_choice "$selection" 16; then
    if ask_yesno "Ollama model pull: use default (${DEFAULT_OLLAMA_PULL_MODEL})?" "yes"; then
      OLLAMA_PULL_MODEL="$DEFAULT_OLLAMA_PULL_MODEL"
    else
      OLLAMA_PULL_MODEL="$(ask_line "Enter Ollama model tag (empty to skip)" "$OLLAMA_PULL_MODEL")"
    fi
    log "Ollama pull model: ${OLLAMA_PULL_MODEL:-<skip>}"
  fi
}

############################
# Install steps
############################
install_base() {
  apt_install \
    ca-certificates curl wget gnupg lsb-release software-properties-common \
    git unzip zip tar xz-utils build-essential \
    jq \
    python3 python3-venv python3-pip \
    ripgrep fd-find htop tmux
}

install_quality_of_life_cli() {
  # Terminal candy + sanity tools
  apt_install \
    fzf bat eza tree direnv tldr \
    neovim \
    shellcheck shfmt \
    entr \
    postgresql-client

  # bat is sometimes "batcat" on Ubuntu
  if ! need_cmd bat && need_cmd batcat; then
    mkdir -p "$HOME/.local/bin"
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  fi
}

install_automation_tooling() {
  # Common automation “glue” tools
  apt_install \
    make \
    jq \
    yq \
    parallel \
    moreutils \
    graphviz

  # just (task runner)
  if ! need_cmd just; then
    apt_install just || true
  fi

  # watchexec (watcher tool; can be in apt on many Ubuntus)
  if ! need_cmd watchexec; then
    apt_install watchexec || true
  fi
}

install_git_extras() {
  apt_install git-lfs
  if need_cmd git; then git lfs install >/dev/null 2>&1 || true; fi

  # GitHub CLI
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
    chsh -s "$(command -v zsh)" || warn "Could not change default shell. You can run: chsh -s $(command -v zsh)"
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
  else
    ensure_keyrings_dir
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    apt_update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if getent group docker >/dev/null; then
    sudo usermod -aG docker "$USER" || true
  fi
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
  local arch
  arch="$(arch_go)"
  log "Installing Go ${GO_VERSION} for ${arch}"
  local tmp
  tmp="$(mktemp -d)"
  local tarball="go${GO_VERSION}.linux-${arch}.tar.gz"
  curl -fsSL "https://go.dev/dl/${tarball}" -o "${tmp}/${tarball}"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${tmp}/${tarball}"
  rm -rf "$tmp"

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
  git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.14.1
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.bashrc"
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.zshrc"
  append_once '. "$HOME/.asdf/asdf.sh"' "$HOME/.profile"
}

install_ruby() {
  if [[ "$RUBY_STRATEGY" == "apt" ]]; then
    if need_cmd ruby; then
      log "Ruby already installed: $(ruby -v)"
    else
      apt_install ruby-full
    fi
    return 0
  fi

  # asdf path (more control, more moving parts)
  install_asdf
  # shellcheck disable=SC1090
  . "$HOME/.asdf/asdf.sh" || true

  # deps for ruby-build
  apt_install \
    autoconf bison libssl-dev libyaml-dev libreadline6-dev zlib1g-dev \
    libncurses5-dev libffi-dev libgdbm6 libgdbm-dev libdb-dev

  if ! asdf plugin list 2>/dev/null | grep -qx ruby; then
    asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git
  fi

  if ! asdf list ruby 2>/dev/null | grep -q "$RUBY_VERSION"; then
    log "Installing Ruby ${RUBY_VERSION} via asdf (this can take a bit)"
    asdf install ruby "$RUBY_VERSION"
  else
    log "Ruby ${RUBY_VERSION} already installed in asdf"
  fi

  asdf global ruby "$RUBY_VERSION"
  log "Ruby set globally to $(ruby -v 2>/dev/null || echo "ruby (will be available in new shell)")"
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

  local started=0
  local pid=""
  if ! pgrep -x ollama >/dev/null 2>&1; then
    ollama serve >/dev/null 2>&1 &
    pid=$!
    started=1
    sleep 2
  fi

  ollama pull "${OLLAMA_PULL_MODEL}" || warn "Model pull failed; retry later: ollama pull ${OLLAMA_PULL_MODEL}"

  if [[ "$started" == "1" ]]; then
    kill "$pid" 2>/dev/null || true
  fi
}

install_ansible() {
  apt_install ansible
}

install_terraform() {
  if [[ "$TF_INSTALL_METHOD" == "snap" ]]; then
    ensure_snapd
    snap_install terraform
    return 0
  fi

  # HashiCorp apt repo (recommended)
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

############################
# Menu
############################
print_menu() {
  cat <<EOF

================= AI Forge Installer =================
Pick what to install (multi-select). Examples:
  1 2 6
  1,2,6
  all
  none

  1) Base packages (curl/git/jq/python/build tools)
  2) QoL CLI tools (fzf, bat, eza, direnv, tldr, shellcheck, shfmt, entr, nvim)
  3) Automation tooling (just, watchexec, parallel, yq, moreutils, graphviz)
  4) Git extras (git-lfs, GitHub CLI 'gh')
  5) Zsh stack (zsh + Oh My Zsh + managed env sourcing)
  6) Docker (Engine + compose plugin)
  7) Node.js (NodeSource)  — default major: ${DEFAULT_NODE_MAJOR}
  8) Go (upstream tarball) — default: ${DEFAULT_GO_VERSION}
  9) Rust (rustup)
 10) Bun
 11) uv (Python package manager)
 12) Python venv + dev tools (ruff/black/mypy/pre-commit/ipython + APIs)
 13) Ruby — default strategy: ${DEFAULT_RUBY_STRATEGY} (asdf default version: ${DEFAULT_RUBY_VERSION})
 14) VS Code (Snap --classic)
 15) Obsidian (Snap)
 16) Ollama (local LLM runner)
 17) Pull Ollama model — default: ${DEFAULT_OLLAMA_PULL_MODEL}
 18) Ansible
 19) Terraform — default install method: ${DEFAULT_TF_INSTALL_METHOD} (repo or snap)

======================================================

EOF
}

main() {
  is_ubuntu || die "This script targets Ubuntu."
  sudo_keepalive

  log "Starting…"
  setup_managed_env

  print_menu

  local selection=""
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    selection="${DEFAULT_SELECT}"
  else
    selection="$(ask_line "Enter selection:" "$DEFAULT_SELECT")"
  fi

  selection="$(normalize_selection "$selection")"
  [[ -n "$selection" ]] || { warn "No selection entered. Exiting."; exit 0; }
  [[ "$selection" != "none" ]] || { log "Nothing selected."; exit 0; }

  if [[ "$selection" == "all" ]]; then
    selection="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19"
  fi

  # Ask about versions only for relevant selections
  if [[ "$NONINTERACTIVE" != "1" ]]; then
    configure_versions_interactively "$selection"
  else
    # non-interactive: just echo chosen defaults/overrides for visibility
    banner_versions
    log "Non-interactive mode selections: $selection"
    log "Using NODE_MAJOR=${NODE_MAJOR}, GO_VERSION=${GO_VERSION}, RUBY_STRATEGY=${RUBY_STRATEGY}, RUBY_VERSION=${RUBY_VERSION}, TF_INSTALL_METHOD=${TF_INSTALL_METHOD}, OLLAMA_PULL_MODEL=${OLLAMA_PULL_MODEL:-<skip>}"
  fi

  # If any apt-heavy installs selected, update once
  if has_choice "$selection" 1 || has_choice "$selection" 2 || has_choice "$selection" 3 || has_choice "$selection" 4 || has_choice "$selection" 5 \
     || has_choice "$selection" 6 || has_choice "$selection" 7 || has_choice "$selection" 9 || has_choice "$selection" 11 || has_choice "$selection" 12 \
     || has_choice "$selection" 13 || has_choice "$selection" 18 || has_choice "$selection" 19; then
    apt_update
  fi

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
  has_choice "$selection" 13 && install_ruby
  has_choice "$selection" 14 && install_vscode_snap
  has_choice "$selection" 15 && install_obsidian_snap
  has_choice "$selection" 16 && install_ollama
  has_choice "$selection" 17 && pull_ollama_model
  has_choice "$selection" 18 && install_ansible
  has_choice "$selection" 19 && install_terraform

  echo
  log "Complete."

  echo
  warn "Notes:"
  warn "- If Docker was installed and you were added to the docker group: log out and back in."
  warn "- If your login shell was changed to zsh: it applies next login."
  warn "- Managed env files:"
  warn "    - $HOME/.config/ai-forge/env.sh   (bash/sh)"
  warn "    - $HOME/.config/ai-forge/env.zsh  (zsh)"
  echo
}

main "$@"
