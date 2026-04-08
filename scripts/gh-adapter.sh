#!/usr/bin/env bash
# captain-codex GitHub adapter
# Encapsulates all GitHub API interactions via the gh CLI.
# Subcommands:
#   create-issue <title> <body_file> [--assign <user>] [--label <label>]...
#   create-branch <name>
#   checkout <branch>
#   push-and-pr <branch> [--issue <number>] [--title <title>]
#   push <branch>
#   post-review <pr_number> <verdict> <body_file>
#   get-review-feedback <pr_number>
#   close-issue <issue_number>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Helpers ───────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

# Retry a command once after a 2-second pause
retry_once() {
  "$@" 2>/dev/null || { sleep 2; "$@"; }
}

# ── Subcommands ───────────────────────────────────────────────────────────

cmd_create_issue() {
  local title="" body_file="" assign="" labels=()

  title="$1"; shift
  body_file="$1"; shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --assign) assign="$2"; shift 2 ;;
      --label)  labels+=("--label" "$2"); shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -f "$body_file" ]] || die "Body file not found: $body_file"

  local cmd=(gh issue create --title "$title" --body-file "$body_file" "${labels[@]}")
  [[ -n "$assign" ]] && cmd+=(--assignee "$assign")

  local url
  url=$(retry_once "${cmd[@]}") || die "Failed to create issue"

  local number
  number=$(echo "$url" | grep -oE '[0-9]+$')

  # Output as tab-separated: number \t url
  printf '%s\t%s\n' "$number" "$url"
}

cmd_create_branch() {
  local name="$1"
  local branch="captain-codex/${name}"

  # Always branch from the remote default branch to avoid dragging unrelated commits
  local default_branch
  default_branch=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null) || default_branch="main"
  git fetch origin "$default_branch" 2>/dev/null || true
  git checkout -b "$branch" "origin/${default_branch}" 2>/dev/null || {
    # Branch already exists — just check it out, preserving any existing work
    git checkout "$branch"
  }
  echo "$branch"
}

cmd_push_and_pr() {
  local branch="$1"
  shift
  local issue_number="" title=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue) issue_number="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  [[ -z "$title" ]] && {
    if [[ -n "$issue_number" ]]; then
      title="Implement #${issue_number}"
    else
      title="captain-codex implementation"
    fi
  }

  local body=""
  if [[ -n "$issue_number" ]]; then
    body="Refs #${issue_number}"
  fi

  git push -u origin "$branch" 2>/dev/null || git push origin "$branch"

  local pr_cmd=(gh pr create --title "$title" --body "$body" --head "$branch")

  local url
  url=$(retry_once "${pr_cmd[@]}") || die "Failed to create PR"

  local number
  number=$(echo "$url" | grep -oE '[0-9]+$')

  printf '%s\t%s\n' "$number" "$url"
}

cmd_push() {
  local branch="$1"
  git push origin "$branch" 2>/dev/null || { sleep 2; git push origin "$branch"; }
}

cmd_post_review() {
  local pr_number="$1" verdict="$2" body_file="$3"

  [[ -f "$body_file" ]] || die "Body file not found: $body_file"

  local event
  if [[ "$verdict" == "APPROVE" ]]; then
    event="APPROVE"
  else
    event="REQUEST_CHANGES"
  fi

  retry_once gh pr review "$pr_number" \
    --"$(echo "$event" | tr '[:upper:]' '[:lower:]' | tr '_' '-')" \
    --body-file "$body_file" || die "Failed to post review"
}

cmd_get_review_feedback() {
  local pr_number="$1"

  # Get the latest review that requested changes (top-level body)
  local review_body
  review_body=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" \
    --jq 'map(select(.state == "CHANGES_REQUESTED")) | last | .body // empty' 2>/dev/null) || review_body=""

  # Get the review ID for inline comments
  local review_id
  review_id=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews" \
    --jq 'map(select(.state == "CHANGES_REQUESTED")) | last | .id // empty' 2>/dev/null) || review_id=""

  # Fetch inline review comments if review_id is available
  local inline_comments=""
  if [[ -n "$review_id" ]]; then
    inline_comments=$(gh api "repos/{owner}/{repo}/pulls/${pr_number}/reviews/${review_id}/comments" \
      --jq '.[] | "[\(.path):\(.line // .original_line // "?")]: \(.body)"' 2>/dev/null) || inline_comments=""
  fi

  # Combine top-level body and inline comments
  if [[ -n "$review_body" ]]; then
    echo "$review_body"
  fi
  if [[ -n "$inline_comments" ]]; then
    echo ""
    echo "Inline comments:"
    echo "$inline_comments"
  fi
}

cmd_checkout() {
  local branch="$1"
  # Try local checkout first; if branch doesn't exist locally, fetch and track remote
  git checkout "$branch" 2>/dev/null || {
    git fetch origin "$branch" 2>/dev/null && \
    git checkout -b "$branch" "origin/$branch" 2>/dev/null
  } || die "Failed to check out branch: $branch"
}

cmd_close_issue() {
  local issue_number="$1"
  retry_once gh issue close "$issue_number" || die "Failed to close issue"
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "${1:-}" in
  create-issue)     shift; cmd_create_issue "$@" ;;
  create-branch)    shift; cmd_create_branch "$@" ;;
  checkout)         shift; cmd_checkout "$@" ;;
  push-and-pr)      shift; cmd_push_and_pr "$@" ;;
  push)             shift; cmd_push "$@" ;;
  post-review)      shift; cmd_post_review "$@" ;;
  get-review-feedback) shift; cmd_get_review_feedback "$@" ;;
  close-issue)      shift; cmd_close_issue "$@" ;;
  *)
    echo "Usage: gh-adapter.sh {create-issue|create-branch|checkout|push-and-pr|push|post-review|get-review-feedback|close-issue} [args...]" >&2
    exit 1
    ;;
esac
