# check-actions-sha-pinning

**English** | [日本語](README.ja.md)

A Bash script that recursively checks all GitHub Actions referenced in your workflow and composite action files for SHA pinning, including transitive dependencies.

## Features

- Detects actions that are not pinned to a full 40-character SHA commit hash
- Recursively inspects composite actions to verify their sub-dependencies are also SHA-pinned
- Detects Docker references that are not pinned to a `sha256:` digest
- Caches fetched `action.yml` files and deduplicates visited actions to minimize API calls
- Colored terminal output (automatically disabled when piped or redirected)
- Configurable maximum recursion depth

## Prerequisites

- **Bash 3.2+** (pre-installed on macOS and most Linux distributions)

The following CLI tools must be installed and available on your `PATH`:

| Tool | Description |
|------|-------------|
| [`gh`](https://cli.github.com/) | GitHub CLI (used to fetch remote action files via the GitHub API) |
| [`yq`](https://github.com/mikefarah/yq) | YAML processor (used to parse workflow and action files) |
| `base64` | Base64 decoder (typically pre-installed on macOS and Linux) |

You must also be authenticated with `gh` (`gh auth login`).

## Quick Start (One-liner)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tk3fftk/check-actions-sha-pinning/main/check-actions-sha-pinning.sh)
```

For better safety, pin to a trusted commit SHA instead of `main`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/tk3fftk/check-actions-sha-pinning/<COMMIT_SHA>/check-actions-sha-pinning.sh)
```

## Usage

```
check-actions-sha-pinning.sh [OPTIONS] [DIRECTORY]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `DIRECTORY` | Repository root to scan (default: git repo root or current directory) |

### Options

| Option | Description |
|--------|-------------|
| `-d, --max-depth N` | Maximum recursion depth for transitive dependency checks (default: `5`) |
| `--no-color` | Disable colored output |
| `-h, --help` | Show help message |

### Examples

```bash
# Scan the current repository
./check-actions-sha-pinning.sh

# Scan a specific repository directory with deeper recursion
./check-actions-sha-pinning.sh -d 10 /path/to/repo

# Pipe-friendly output (color auto-disabled)
./check-actions-sha-pinning.sh | tee report.txt
```

## What It Scans

- `.github/workflows/*.yml` / `.github/workflows/*.yaml` — Workflow files (both reusable workflow `uses` and step-level `uses`)
- `.github/actions/*/action.yml` / `.github/actions/*/action.yaml` — Local composite action files

Local actions (prefixed with `./` or `.github/`) are excluded from the check since they live in the same repository.

## Output

Each action reference is reported with one of the following statuses:

| Status | Meaning |
|--------|---------|
| `[PASS]` | The action is SHA-pinned (or is a non-composite action with no sub-dependencies) |
| `[FAIL]` | The action is NOT SHA-pinned, or a transitive dependency is not pinned |
| `[WARN]` | The action could not be fetched (private repo / not found) or the max recursion depth was reached |

Transitive dependencies are displayed with indentation to show the dependency tree.

A summary is printed at the end with counts for passed, failed, and warning results, along with a list of all unpinned dependency chains.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All checked actions are properly SHA-pinned |
| `1` | One or more actions are not SHA-pinned |
