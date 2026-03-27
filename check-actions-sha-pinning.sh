#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# GitHub Actions Transitive Dependency SHA Pinning Checker
#
# Recursively checks all GitHub Actions referenced in workflow and composite
# action files for SHA pinning, including transitive dependencies.
# ---------------------------------------------------------------------------

REPO_ROOT=""
CACHE_DIR=""
FAIL_DETAILS_FILE=""
VISITED_FILE=""
FAIL_COUNT=0
PASS_COUNT=0
WARN_COUNT=0
MAX_DEPTH=5
USE_COLOR=true

# ---------------------------------------------------------------------------
# Usage / argument parsing
# ---------------------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage: check-actions-sha-pinning.sh [OPTIONS] [DIRECTORY]

Check GitHub Actions for SHA pinning, including transitive dependencies.

Arguments:
  DIRECTORY   Repository root to scan (default: git repo root or current dir)

Options:
  -d, --max-depth N   Maximum recursion depth (default: 5)
  --no-color          Disable colored output
  -h, --help          Show this help message
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      -d|--max-depth)
        MAX_DEPTH="$2"
        shift 2
        ;;
      --no-color)
        USE_COLOR=false
        shift
        ;;
      -*)
        echo "Error: Unknown option '$1'" >&2
        usage >&2
        exit 1
        ;;
      *)
        REPO_ROOT="$1"
        shift
        ;;
    esac
  done

  # Default: git root or current directory
  if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi

  # Auto-disable color when output is not a terminal
  if [ "$USE_COLOR" = "true" ] && ! [ -t 1 ]; then
    USE_COLOR=false
  fi
}

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------

check_prerequisites() {
  local missing=false
  for cmd in gh yq base64; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' is required but not found." >&2
      missing=true
    fi
  done
  if [ "$missing" = "true" ]; then
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

print_result() {
  local status="$1" depth="$2" uses_value="$3" detail="$4"
  local indent=""
  local i=0
  while [ "$i" -lt "$depth" ]; do indent+="  "; i=$((i + 1)); done

  if [ "$USE_COLOR" = "true" ]; then
    local color="" reset="\033[0m"
    case "$status" in
      PASS) color="\033[32m" ;;
      FAIL) color="\033[31m" ;;
      WARN) color="\033[33m" ;;
    esac
    echo -e "${indent}${color}[${status}]${reset} ${uses_value} ${detail}"
  else
    echo "${indent}[${status}] ${uses_value} ${detail}"
  fi
}

is_sha_pinned() {
  [[ "$1" =~ ^[0-9a-f]{40}$ ]]
}

is_docker_digest_pinned() {
  [[ "$1" =~ @sha256:[0-9a-f]{64} ]]
}

is_visited() {
  grep -qFx "$1" "$VISITED_FILE" 2>/dev/null
}

mark_visited() {
  echo "$1" >> "$VISITED_FILE"
}

# Parse "owner/repo/subpath@ref" into global vars
parse_action_ref() {
  local uses_value="$1"
  local action_path ref_part

  action_path="${uses_value%%@*}"
  ref_part="${uses_value#*@}"

  ref_part="${ref_part%% *}"

  PARSED_OWNER="${action_path%%/*}"
  local remainder="${action_path#*/}"
  PARSED_REPO="${remainder%%/*}"
  if [[ "$remainder" == */* ]]; then
    PARSED_SUBPATH="${remainder#*/}"
  else
    PARSED_SUBPATH=""
  fi
  PARSED_REF="$ref_part"
}

fetch_action_yml() {
  local owner="$1" repo="$2" subpath="$3" ref="$4"
  local cache_key="${owner}__${repo}__${subpath//\//_}__${ref}"
  local cache_file="${CACHE_DIR}/${cache_key}"

  if [ -f "$cache_file" ]; then
    echo "$cache_file"
    return 0
  fi

  if [ -f "${cache_file}.notfound" ]; then
    return 1
  fi

  local base_path=""
  if [ -n "$subpath" ]; then
    base_path="${subpath}/"
  fi

  local ext response
  for ext in yml yaml; do
    local api_path="repos/${owner}/${repo}/contents/${base_path}action.${ext}?ref=${ref}"
    if response=$(gh api "$api_path" --jq '.content' 2>/dev/null); then
      if echo "$response" | base64 -d > "$cache_file" 2>/dev/null; then
        echo "$cache_file"
        return 0
      fi
    fi
  done

  touch "${cache_file}.notfound"
  return 1
}

get_action_type() {
  local file="$1"
  yq eval '.runs.using // ""' "$file" 2>/dev/null || echo ""
}

extract_external_uses() {
  local file="$1" is_workflow="$2"
  local uses_list=""

  if [ "$is_workflow" = "true" ]; then
    uses_list="$(yq eval '.jobs[].uses // ""' "$file" 2>/dev/null || true)"
    uses_list="${uses_list}
$(yq eval '.jobs[].steps[].uses // ""' "$file" 2>/dev/null || true)"
  else
    uses_list="$(yq eval '.runs.steps[].uses // ""' "$file" 2>/dev/null || true)"
  fi

  echo "$uses_list" | grep -vE '^$|^null$|^\./|^\.github/' | sort -u || true
}

clean_uses_value() {
  local s="${1%% #*}"
  echo "$s" | sed 's/ *$//'
}

# ---------------------------------------------------------------------------
# Core recursive check
# ---------------------------------------------------------------------------

check_action() {
  local uses_value="$1" depth="$2" parent_chain="$3"

  local uses_clean
  uses_clean="$(clean_uses_value "$uses_value")"

  if [[ "$uses_clean" == docker://* ]]; then
    if is_docker_digest_pinned "$uses_clean"; then
      print_result "PASS" "$depth" "$uses_clean" "(Docker, digest-pinned)"
      PASS_COUNT=$((PASS_COUNT + 1))
    else
      print_result "FAIL" "$depth" "$uses_clean" "(Docker tag, NOT digest-pinned)"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "${parent_chain} -> ${uses_clean}" >> "$FAIL_DETAILS_FILE"
    fi
    return
  fi

  parse_action_ref "$uses_clean"
  local owner="$PARSED_OWNER" repo="$PARSED_REPO" subpath="$PARSED_SUBPATH" ref="$PARSED_REF"
  local visit_key="${owner}/${repo}/${subpath}@${ref}"

  if is_visited "$visit_key"; then
    print_result "PASS" "$depth" "$uses_clean" "(already checked, skipped)"
    return
  fi
  mark_visited "$visit_key"

  if ! is_sha_pinned "$ref"; then
    print_result "FAIL" "$depth" "$uses_clean" "(NOT SHA-pinned)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "${parent_chain} -> ${uses_clean}" >> "$FAIL_DETAILS_FILE"
    return
  fi

  if [ "$depth" -ge "$MAX_DEPTH" ]; then
    print_result "WARN" "$depth" "$uses_clean" "(max depth ${MAX_DEPTH} reached, skipping)"
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  local action_file
  if ! action_file=$(fetch_action_yml "$owner" "$repo" "$subpath" "$ref"); then
    print_result "WARN" "$depth" "$uses_clean" "(could not fetch: private repo or not found)"
    WARN_COUNT=$((WARN_COUNT + 1))
    return
  fi

  local action_type
  action_type=$(get_action_type "$action_file")

  if [ "$action_type" != "composite" ]; then
    print_result "PASS" "$depth" "$uses_clean" "(${action_type:-unknown}, no sub-deps)"
    PASS_COUNT=$((PASS_COUNT + 1))
    return
  fi

  local sub_uses
  sub_uses=$(extract_external_uses "$action_file" "false")

  if [ -z "$sub_uses" ]; then
    print_result "PASS" "$depth" "$uses_clean" "(composite, no external sub-deps)"
    PASS_COUNT=$((PASS_COUNT + 1))
    return
  fi

  # Determine composite parent status by scanning sub-deps
  local has_fail=false
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    local sub_clean
    sub_clean="$(clean_uses_value "$sub")"
    local sub_ref="${sub_clean#*@}"
    sub_ref="${sub_ref%% *}"

    if [[ "$sub_clean" == docker://* ]]; then
      if ! is_docker_digest_pinned "$sub_clean"; then
        has_fail=true
      fi
    elif ! is_sha_pinned "$sub_ref"; then
      has_fail=true
    fi
  done <<< "$sub_uses"

  if [ "$has_fail" = "true" ]; then
    print_result "FAIL" "$depth" "$uses_clean" "(composite)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    print_result "PASS" "$depth" "$uses_clean" "(composite)"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi

  # Recurse into sub-dependencies
  local next_chain="${uses_clean}"
  if [ -n "$parent_chain" ]; then
    next_chain="${parent_chain} -> ${uses_clean}"
  fi
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    check_action "$sub" $((depth + 1)) "$next_chain" || true
  done <<< "$sub_uses"
}

# ---------------------------------------------------------------------------
# Scan a single file and check all its external action references
# ---------------------------------------------------------------------------

scan_file() {
  local file="$1" is_workflow="$2"
  local rel_path="${file#"$REPO_ROOT"/}"

  local uses_list
  uses_list=$(extract_external_uses "$file" "$is_workflow")
  if [ -z "$uses_list" ]; then
    return
  fi

  echo "Scanning: ${rel_path}"
  while IFS= read -r uses_value; do
    [ -z "$uses_value" ] && continue
    check_action "$uses_value" 1 "${rel_path}" || true
  done <<< "$uses_list"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  check_prerequisites

  CACHE_DIR="$(mktemp -d)"
  VISITED_FILE="${CACHE_DIR}/_visited"
  FAIL_DETAILS_FILE="${CACHE_DIR}/_fail_details"
  touch "$VISITED_FILE" "$FAIL_DETAILS_FILE"
  trap 'rm -rf "$CACHE_DIR"' EXIT

  echo "Checking GitHub Actions SHA pinning (including transitive dependencies)..."
  echo "Repository: ${REPO_ROOT}"
  echo "Max depth: ${MAX_DEPTH}"
  echo ""

  local file_count=0

  # Scan workflow files
  if [ -d "$REPO_ROOT/.github/workflows" ]; then
    for f in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
      [ -f "$f" ] || continue
      file_count=$((file_count + 1))
      scan_file "$f" "true"
    done
  fi

  # Scan local composite action files
  if [ -d "$REPO_ROOT/.github/actions" ]; then
    for f in "$REPO_ROOT"/.github/actions/*/action.yml "$REPO_ROOT"/.github/actions/*/action.yaml; do
      [ -f "$f" ] || continue
      file_count=$((file_count + 1))
      scan_file "$f" "false"
    done
  fi

  if [ "$file_count" -eq 0 ]; then
    echo "No workflow or action files found."
    exit 0
  fi

  # Summary
  echo "========================================"
  echo "Summary:"
  echo "  Files scanned: ${file_count}"
  echo "  Total actions checked: $((PASS_COUNT + FAIL_COUNT + WARN_COUNT))"
  echo "  Passed: ${PASS_COUNT}"
  echo "  Failed: ${FAIL_COUNT}"
  echo "  Warnings (inaccessible/depth limit): ${WARN_COUNT}"

  if [ -s "$FAIL_DETAILS_FILE" ]; then
    echo ""
    echo "  Unpinned dependencies:"
    while IFS= read -r detail; do
      echo "    ${detail}"
    done < "$FAIL_DETAILS_FILE"
  fi

  echo ""

  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
}

main "$@"
