# CLAUDE.md

## Project Overview

A single-file Bash script (`check-actions-sha-pinning.sh`) that recursively checks GitHub Actions for SHA pinning, including transitive dependencies.

## Key Constraints

- **Bash 3.2+ compatibility required** — macOS ships with bash 3.2. Do not use `declare -A` (associative arrays), `readarray`/`mapfile`, `&>>`, `|&`, or other bash 4+ features.
- The shebang is `#!/usr/bin/env bash`.

## Development

- Syntax check: `bash -n check-actions-sha-pinning.sh`
- Lint: `shellcheck check-actions-sha-pinning.sh`
- Run: `./check-actions-sha-pinning.sh [OPTIONS] [DIRECTORY]`
