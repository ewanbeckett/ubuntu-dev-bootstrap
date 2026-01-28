# AGENTS.md

This repository provides an interactive installer for setting up a development environment on **Ubuntu 24.04 LTS**.

This file defines expectations and boundaries for automated agents, contributors, and maintainers working with this repository.

---

## Scope of the Repository

- Target OS: **Ubuntu 24.04 LTS only**
- Primary artifact: `installer.sh`
- Supporting documentation: `README.md`, `AGENTS.md`
- License: MIT

The installer is intended to be:
- Re-runnable
- Predictable
- Explicit in what it installs
- Safe with respect to user configuration files

---

## Source of Truth

- `installer.sh` is the **source of truth** for:
  - What software is installed
  - Default versions
  - Installation order
  - Optional vs mandatory components

Documentation must reflect the current behavior of `installer.sh`.  
If documentation and script disagree, the script wins.

---

## Core Design Constraints

Agents and contributors **must not** violate the following constraints:

1. **OS specificity**
   - Do not generalize this repository to other Ubuntu versions or other operating systems.
   - Do not add compatibility logic for non–Ubuntu 24.04 systems.

2. **Mandatory core packages**
   - Core apt packages are installed unconditionally at startup.
   - Do not make core packages optional.
   - Do not duplicate core-installed packages in optional install steps.

3. **No configuration clobbering**
   - Do not overwrite user files such as:
     - `.bashrc`
     - `.zshrc`
     - `.profile`
   - Environment configuration must be done via managed files under:
     - `~/.config/ai-forge/`

4. **Explicit installation**
   - No background installs.
   - No silent behavior changes.
   - All optional tooling must be behind an explicit menu choice.

5. **Upstream-first installs**
   - Prefer official upstream installers where appropriate (e.g. `rustup`, `asdf`, NodeSource).
   - Avoid distro-packaged versions for language runtimes unless explicitly intended.

6. **Snap usage**
   - Snap is used **only** where explicitly chosen:
     - VS Code
     - Obsidian
   - Do not introduce Snap for other tools without discussion.

---

## Adding or Modifying Tooling

When adding new tools or languages:

- Decide whether they belong in:
  - Mandatory core packages
  - A new optional menu entry
  - An existing optional category
- Avoid installing the same dependency in multiple steps.
- Prefer versioned installs where upstream tooling supports it.
- Ensure the installer remains idempotent and safe to re-run.

---

## Version Management

- Default versions are defined at the top of `installer.sh`.
- Agents must not:
  - Change defaults without justification
  - Normalize or “modernize” versions implicitly
  - Drift documentation versions away from script defaults

Version prompts and environment overrides are preferred over hard changes.

---

## Error Handling Philosophy

- Fail fast on:
  - Unsupported OS
  - Missing required privileges
- Continue on best-effort basis for:
  - Non-critical apt packages
  - Optional tooling installs
- Re-running the installer should be safe after partial failure.

---

## Documentation Guidelines

Documentation should be:
- Accurate
- Succinct
- Non-promotional
- Free of anthropomorphic or “AI voice” language

Avoid:
- Marketing language
- Assumptions about user intent
- Claims about future features

---

## Contributions

Changes should:
- Preserve existing behavior unless explicitly requested
- Avoid large refactors without clear justification
- Prefer incremental, reviewable changes

If unsure whether a change fits the scope, open an issue before implementing.

---

## Automation Notes

Agents interacting with this repository should assume:
- Human review is expected for installer changes
- Backwards compatibility matters for users re-running the script
- Safety and clarity outweigh convenience shortcuts

---

## License

MIT
