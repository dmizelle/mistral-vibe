#!/bin/bash
# Vibe Code Review GitHub Action - Main Entrypoint
# Implements automated code review with persistent session context via teleport

set -euo pipefail

# =============================================================================
# Configuration & Environment
# =============================================================================

# Export GITHUB_TOKEN for gh CLI
export GITHUB_TOKEN=${GITHUB_TOKEN:-}

# Ensure required tools are available
command -v gh >/dev/null 2>&1 || { echo "[ERROR] gh CLI not found"; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "[ERROR] uv not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not found"; exit 1; }

# =============================================================================
# Constants
# =============================================================================

readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly SESSION_MARKER="<!-- VIBE_SESSION:"
readonly SESSION_MARKER_END="-->"
readonly MAX_SESSION_METADATA_SIZE=50000
readonly MAX_PROMPT_LENGTH=30000

# =============================================================================
# Logging
# =============================================================================

log_info() {
  echo "[INFO] $*"
}

log_error() {
  echo "[ERROR] $*" >&2
}

log_debug() {
  if [ "${DEBUG:-false}" = "true" ]; then
    echo "[DEBUG] $*"
  fi
}

# =============================================================================
# Input Validation
# =============================================================================

validate_inputs() {
  # Validate REPOSITORY
  if [ -z "${REPO:-}" ]; then
    log_error "REPOSITORY not set"
    exit 1
  fi

  # Validate PR_NUMBER (must be a number)
  if [ -z "${PR_NUMBER:-}" ]; then
    log_info "No PR number found, skipping (event: ${EVENT_NAME:-unknown})"
    exit 0
  fi
  if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    log_error "Invalid PR number: $PR_NUMBER"
    exit 1
  fi

  # Validate REVIEW_MODE
  case "${REVIEW_MODE:-normal}" in
    quick|normal|thorough) ;;
    *) 
      log_error "Invalid review_mode: ${REVIEW_MODE:-} (must be quick, normal, or thorough)"
      exit 1
      ;;
  esac

  # Validate AUTO_APPROVE
  case "${AUTO_APPROVE:-true}" in
    true|false|True|False|1|0) ;;
    *) 
      log_error "Invalid auto_approve: ${AUTO_APPROVE:-} (must be true or false)"
      exit 1
      ;;
  esac

  # Validate WORKDIR exists
  REPO_ROOT=${GITHUB_WORKSPACE:-$(pwd)}
  if [ "${WORKDIR:-.}" = "." ]; then
    FULL_WORKDIR="$REPO_ROOT"
  else
    FULL_WORKDIR="$REPO_ROOT/${WORKDIR:-}"
  fi
  
  if [ ! -d "$FULL_WORKDIR" ]; then
    log_error "Workdir does not exist: $FULL_WORKDIR"
    exit 1
  fi

  log_debug "Validated inputs: REPO=$REPO, PR_NUMBER=$PR_NUMBER, WORKDIR=$WORKDIR, REVIEW_MODE=$REVIEW_MODE"
}

# =============================================================================
# GitHub API Helper with Retries
# =============================================================================

# Make a GitHub API call with retries
# Args: method, url, [jq_filter]
gh_api() {
  local method="${1:-GET}"
  local url="$2"
  local jq_filter="${3:-}"
  local retries=${GITHUB_API_RETRIES:-3}
  local delay=2
  local attempt

  for attempt in $(seq 1 $retries); do
    if [ -n "$jq_filter" ]; then
      local result
      result=$(gh api "$url" --jq "$jq_filter" 2>&1) && echo "$result" && return 0
    else
      gh api "$url" 2>&1 && return 0
    fi
    
    if [ $attempt -lt $retries ]; then
      sleep $delay
      delay=$((delay * 2))
    fi
  done
  
  log_error "GitHub API failed after $retries attempts: $url"
  return 1
}

# =============================================================================
# Hidden Comment Management
# =============================================================================

# Get session metadata from hidden comment
# Returns JSON string
get_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  
  local comment
  comment=$(gh_api GET "repos/$repo/issues/$pr_number/comments" \
    '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .body' 2>/dev/null || true)
  
  if [ -n "$comment" ]; then
    # Extract and decode the base64 JSON
    local encoded
    encoded=$(echo "$comment" | sed "s/.*$SESSION_MARKER //;s/ $SESSION_MARKER_END.*//" || true)
    if [ -n "$encoded" ]; then
      echo "$encoded" | base64 -d 2>/dev/null || echo '{"version": "1.0", "sessions": []}'
      return
    fi
  fi
  
  # Return empty metadata
  echo "{\"version\": \"1.0\", \"pr_number\": $pr_number, \"repository\": \"$repo\", \"sessions\": [], \"comment_tracking\": {\"comments\": []}}"
}

# Save session metadata to hidden comment
# Args: repo, pr_number, metadata_json
save_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  local metadata="$3"
  
  # Check size
  local encoded
  encoded=$(echo "$metadata" | base64 -w 0 2>/dev/null || true)
  
  if [ -z "$encoded" ]; then
    log_error "Failed to encode metadata"
    return 1
  fi
  
  # Truncate if too large
  if [ ${#encoded} -gt $MAX_SESSION_METADATA_SIZE ]; then
    log_error "Session metadata too large (${#encoded} chars), trimming history"
    # Remove old sessions but keep the most recent 5
    metadata=$(echo "$metadata" | jq '.sessions = (.sessions | if length > 5 then .[length-5:] else . end)' 2>/dev/null || echo "$metadata")
    encoded=$(echo "$metadata" | base64 -w 0 2>/dev/null || true)
  fi
  
  local body="$SESSION_MARKER $encoded $SESSION_MARKER_END"
  
  # Find existing hidden comment
  local existing_id
  existing_id=$(gh_api GET "repos/$repo/issues/$pr_number/comments" \
    '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .id' 2>/dev/null || true)
  
  if [ -n "$existing_id" ]; then
    # Update existing comment
    log_debug "Updating existing session metadata comment $existing_id"
    gh_api PATCH "repos/$repo/issues/comments/$existing_id" -f body="$body" >/dev/null 2>&1 || {
      log_error "Failed to update session metadata comment"
      return 1
    }
  else
    # Create new comment
    log_debug "Creating new session metadata comment"
    gh_api POST "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null 2>&1 || {
      log_error "Failed to create session metadata comment"
      return 1
    }
  fi
  
  return 0
}

# =============================================================================
# Conversation History Management
# =============================================================================

# Get full conversation history from metadata
# Returns formatted string for inclusion in prompts
get_conversation_history() {
  local metadata="$1"
  
  if [ -z "$metadata" ]; then
    echo ""
    return
  fi
  
  # Extract messages and format them
  local history
  history=$(echo "$metadata" | jq -r '
    .sessions[] | 
    .messages[] | 
    select(.role == "user" or .role == "assistant") |
    "[" + .role + "] " + (.timestamp | sub("\\."; "") | sub("T"; " ") | sub("Z$"; "")) + ": " + .content
  ' 2>/dev/null || true)
  
  if [ -n "$history" ]; then
    echo "Previous conversation:"
    echo "$history"
  else
    echo ""
  fi
}

# =============================================================================
# Teleport Session Management
# =============================================================================

# Create a new teleport session
# Args: prompt, workdir
# Returns: session URL or empty string on failure
create_teleport_session() {
  local prompt="$1"
  local workdir="$2"
  
  log_info "Creating teleport session..."
  log_debug "Workdir: $workdir"
  
  # Validate prompt length
  if [ ${#prompt} -gt $MAX_PROMPT_LENGTH ]; then
    log_error "Prompt too long (${#prompt} chars > $MAX_PROMPT_LENGTH max)"
    return 1
  fi
  
  # Write prompt to temp file to avoid quoting issues
  local prompt_file
  prompt_file=$(mktemp) || { log_error "Failed to create temp file"; return 1; }
  trap "rm -f '$prompt_file'" EXIT
  printf '%s\n' "$prompt" > "$prompt_file"
  
  # Run teleport with auto-approve
  local teleport_output
  local exit_code
  
  if [ "$AUTO_APPROVE" = "true" ]; then
    teleport_output=$(cd "$workdir" && uv run --directory "$SCRIPT_DIR" vibe --teleport --agent auto-approve < "$prompt_file" 2>&1) || exit_code=$?
  else
    teleport_output=$(cd "$workdir" && uv run --directory "$SCRIPT_DIR" vibe --teleport < "$prompt_file" 2>&1) || exit_code=$?
  fi
  
  rm -f "$prompt_file"
  
  log_debug "Teleport output:\n$teleport_output"
  
  # URL is printed to stdout by vibe when teleport completes
  # It should be a clean URL on its own line
  local url
  url=$(echo "$teleport_output" | grep -E '^https://[^/]+/session/[a-zA-Z0-9_-]+$' | tail -1 || true)
  
  # If not found, try less strict pattern
  if [ -z "$url" ]; then
    url=$(echo "$teleport_output" | grep -oE 'https://[^/]+/session/[a-zA-Z0-9_-]+' | tail -1 || true)
  fi
  
  if [ -n "$url" ]; then
    log_info "Session created: $url"
    echo "$url"
    return 0
  else
    log_error "Failed to extract session URL from teleport output"
    log_error "Teleport output was:\n$teleport_output"
    return 1
  fi
}

# =============================================================================
# Slash Command Parsing
# =============================================================================

# Parse slash command from comment body
# Returns command string or empty if not a vibe command
parse_command() {
  local body="$1"
  
  # Remove leading/trailing whitespace
  body=$(echo "$body" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  
  # Check for /vibe command
  if [[ "$body" =~ ^/vibe[[:space:]]+(.*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  
  # Check for @mention with bot
  if [[ "$body" =~ @(mistral-vibe|vibe)\[bot\][[:space:]]+(.*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  
  if [[ "$body" =~ @(mistral-vibe|vibe)[[:space:]]+(.*) ]]; then
    echo "${BASH_REMATCH[2]}"
    return 0
  fi
  
  echo ""
  return 1
}

# Check if this is a vibe command
is_vibe_command() {
  local body="$1"
  parse_command "$body" >/dev/null 2>&1
}

# =============================================================================
# Comment Posting
# =============================================================================

# Sanitize file path - must be relative and safe
sanitize_file_path() {
  local file="$1"
  
  # Remove leading slashes
  file=${file#/}
  
  # Check for path traversal
  if [[ "$file" =~ \.\. ]]; then
    log_error "Invalid file path (contains ..): $file"
    return 1
  fi
  
  echo "$file"
}

# Sanitize line number
sanitize_line_number() {
  local line="$1"
  
  if ! [[ "$line" =~ ^[0-9]+$ ]]; then
    log_error "Invalid line number: $line"
    return 1
  fi
  
  echo "$line"
}

# Post a summary comment to the PR
# Args: repo, pr_number, markdown_content
post_summary_comment() {
  local repo="$1"
  local pr_number="$2"
  local content="$3"
  
  # Truncate content to GitHub's max comment size (65536)
  if [ ${#content} -gt 65000 ]; then
    content="${content:0:65000}... (truncated)"
  fi
  
  gh_api POST "repos/$repo/issues/$pr_number/comments" -f body="$content" >/dev/null 2>&1 || {
    log_error "Failed to post summary comment"
    return 1
  }
  
  return 0
}

# Post an inline review comment
# Args: repo, pr_number, file, line, side, body
post_inline_comment() {
  local repo="$1"
  local pr_number="$2"
  local file="$3"
  local line="$4"
  local side="${5:-RIGHT}"
  local body="$6"
  
  # Sanitize inputs
  file=$(sanitize_file_path "$file") || return 1
  line=$(sanitize_line_number "$line") || return 1
  
  # Truncate body
  if [ ${#body} -gt 65000 ]; then
    body="${body:0:65000}... (truncated)"
  fi
  
  gh_api POST "repos/$repo/pulls/$pr_number/comments" \
    -f path="$file" \
    -f line="$line" \
    -f side="$side" \
    -f body="$body" >/dev/null 2>&1 || {
    log_error "Failed to post inline comment for $file:$line"
    return 1
  }
  
  return 0
}

# =============================================================================
# Review Prompt Generation
# =============================================================================

# Build the review prompt for automated reviews
# Args: pr_number, diff, repo
# Returns: prompt string
build_review_prompt() {
  local pr_number="$1"
  local diff="$2"
  local repo="$3"
  
  # Truncate diff if too long
  local diff_length=${#diff}
  if [ $diff_length -gt 20000 ]; then
    diff="${diff:0:20000}... (diff truncated - full diff available in PR)"
  fi
  
  cat <<EOF
You are Mistral Vibe performing an AUTOMATED code review on GitHub PR #$pr_number in repository $repo.

## Your Tasks

1. Analyze all code changes in this PR
2. Identify issues and categorize them by priority (high/medium/low)
3. Provide specific, actionable feedback with file paths and line numbers
4. Use GitHub suggestion syntax for code fixes
5. Post comments using the gh CLI commands provided below
6. Format your summary comment EXACTLY as specified

## Output Requirements

### Summary Comment (post to PR issue)
Respond with ONLY this format for the summary (no other text before or after):

\`\`\`markdown
## Mistral Vibe Code Review

**Status**: [✅ Approved / ⚠️ Request Changes / 🔍 Needs Review]

**Description**: [1-2 sentence summary]

### Issues Found

#### 🔴 High Priority (Must Fix Before Merge)
- [ ] [description with file:line] - [details]

#### 🟡 Medium Priority (Should Fix)
- [ ] [description with file:line] - [details]

#### 🟢 Low Priority (Nice to Have)
- [ ] [description with file:line] - [details]

### Strengths
- ✅ [positive observation]

**Session**: [Session URL will be provided separately]
\`\`\`

### Inline Comments
For specific code issues, post inline PR review comments using the gh CLI.
Use suggestion syntax for code fixes:
\`\`\`suggestion
fixed code here
\`\`\`

## GitHub API Commands

Use these exact commands to post comments:

\`\`\`bash
# For summary comment on PR issue
gh api repos/$repo/issues/$pr_number/comments -f body="STRUCTURED_MARKDOWN"

# For inline PR review comment
gh api repos/$repo/pulls/$pr_number/comments \\
  -f body="COMMENT_TEXT" \\
  -f path="FILE_PATH" \\
  -f line=LINE_NUMBER \\
  -f side="RIGHT"

# For suggestion (creates one-click apply button)
gh api repos/$repo/pulls/$pr_number/comments \\
  -f body="\`\`\`suggestion\nNEW_CODE\n\`\`\`" \\
  -f path="FILE_PATH" \\
  -f line=LINE_NUMBER \\
  -f side="RIGHT"
\`\`\`

## Code Changes to Review

$diff

## Review Guidelines

Focus on:
- Code quality and style (PEP 8 for Python)
- Potential bugs and edge cases
- Performance issues
- Security vulnerabilities (SQL injection, XSS, etc.)
- Test coverage and quality
- Code documentation and comments
- Type hints and validation
- Error handling
- API design and REST conventions

Be specific with file paths and line numbers.
Use suggestion syntax for all code fixes.
Categorize issues appropriately (high = must fix before merge).
Check for common issues: missing error handling, hardcoded values, magic numbers, duplicate code, etc.

## Review Mode
Mode: $REVIEW_MODE
- quick: Focus on critical issues only
- normal: Balanced review
- thorough: Comprehensive analysis with minor suggestions

Begin your review now.
EOF
}

# =============================================================================
# Session and Command Execution
# =============================================================================

# Create session with context (new or continuation)
# Args: repo, pr_number, command, workdir
# Returns: session URL
create_session_with_context() {
  local repo="$1"
  local pr_number="$2"
  local command="$3"
  local workdir="$4"
  
  local metadata
  metadata=$(get_session_metadata "$repo" "$pr_number")
  
  local has_session
  has_session=$(echo "$metadata" | jq '.sessions | length > 0' 2>/dev/null || echo "false")
  
  local prompt
  
  # Get diff
  local diff
  diff=$(gh_api GET "repos/$repo/pulls/$pr_number" --jq '.diff' 2>/dev/null || echo "")
  
  if [ "$has_session" = "true" ]; then
    # Continue existing session - include history
    local history
    history=$(get_conversation_history "$metadata")
    
    prompt="$history

New command: $command

Context:
- Repository: $repo
- PR Number: #$pr_number
- Working Directory: $workdir
- You are Mistral Vibe, an AI coding assistant performing code review."
  else
    # New session
    case "$command" in
      review|review\ *)
        prompt=$(build_review_prompt "$pr_number" "$diff" "$repo")
        ;;
      fix|fix\ *)
        prompt="Fix the issues in this PR. Repository: $repo, PR #$pr_number.

Diff:
$diff

Use the gh CLI to post inline comments with fixes using suggestion syntax."
        ;;
      "add tests"*|test|tests)
        prompt="Add comprehensive tests for the changes in this PR. Repository: $repo, PR #$pr_number.

Diff:
$diff

Generate test files and post them using the gh CLI."
        ;;
      explain|explain\ *)
        prompt="Explain the code changes in this PR. Repository: $repo, PR #$pr_number.

Diff:
$diff

Provide clear explanations of what the code does."
        ;;
      *)
        # Generic command - include diff
        prompt="$command

Context: Repository: $repo, PR #$pr_number

Diff:
$diff"
        ;;
    esac
  fi
  
  # Create teleport session
  local url
  url=$(create_teleport_session "$prompt" "$workdir") || return 1
  
  # Save session metadata
  local session_id
  session_id=$(basename "$url")
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  local new_metadata
  new_metadata=$(echo "$metadata" | jq \
    --arg url "$url" \
    --arg sid "$session_id" \
    --arg ts "$timestamp" \
    --arg cmd "$command" \
    --arg trigger "$EVENT_NAME" \
    '.sessions += [{"session_id": $sid, "session_url": $url, "created_at": $ts, "trigger": $trigger, "command": $cmd, "messages": []}] | .current_session_id = $sid' 2>/dev/null || echo "$metadata")
  
  save_session_metadata "$repo" "$pr_number" "$new_metadata" || {
    log_error "Failed to save session metadata"
    # Don't fail the whole operation, but log it
  }
  
  echo "$url"
  return 0
}

# =============================================================================
# PR vs Issue Detection
# =============================================================================

# Check if this is a PR (not an issue)
is_pull_request() {
  # For issue_comment events, check if it's a PR comment
  if [ "$EVENT_NAME" = "issue_comment" ]; then
    # GitHub provides pull_request object for PR comments
    if [ -n "${GITHUB_EVENT_PULL_REQUEST_NUMBER:-}" ]; then
      return 0
    fi
    # Check via API
    local is_pr
    is_pr=$(gh_api GET "repos/$REPO/issues/$PR_NUMBER" --jq '.pull_request | type == "object"' 2>/dev/null || echo "false")
    if [ "$is_pr" = "true" ]; then
      return 0
    fi
    return 1
  fi
  
  # pull_request and synchronize events are always PRs
  if [ "$EVENT_NAME" = "pull_request" ] || [ "$EVENT_NAME" = "synchronize" ]; then
    return 0
  fi
  
  return 1
}

# =============================================================================
# Main Logic
# =============================================================================

main() {
  log_info "Starting Vibe Code Review Action"
  log_debug "Repository: $REPO, PR: $PR_NUMBER, Event: $EVENT_NAME"
  
  # Validate all inputs first
  validate_inputs
  
  # Check if this is a PR (skip if it's just an issue)
  if ! is_pull_request; then
    log_info "Skipping: not a pull request (event: $EVENT_NAME, number: $PR_NUMBER)"
    exit 0
  fi
  
  # Determine trigger type and command
  local command=""
  local is_vibe_cmd=false
  
  case "$EVENT_NAME" in
    pull_request)
      # PR created, synchronized, or reopened
      command="review"
      ;;
    issue_comment)
      # Comment on PR
      if is_vibe_command "${COMMENT_BODY:-}"; then
        is_vibe_cmd=true
        command=$(parse_command "${COMMENT_BODY:-}")
        
        # Check author to prevent loops
        if [[ "${COMMENT_USER:-}" =~ github-actions|mistral-vibe|vibe ]]; then
          log_info "Skipping: command from bot user: ${COMMENT_USER:-}"
          exit 0
        fi
        
        # If command is empty, default to review
        if [ -z "$command" ]; then
          command="review"
        fi
      else
        # Not a vibe command, skip
        log_debug "Not a vibe command, skipping"
        exit 0
      fi
      ;;
    *)
      log_info "Unsupported event type: $EVENT_NAME"
      exit 0
      ;;
  esac
  
  log_info "Executing command: $command on PR #$PR_NUMBER"
  
  # Execute the command and get session URL
  local session_url
  session_url=$(create_session_with_context "$REPO" "$PR_NUMBER" "$command" "$FULL_WORKDIR") || {
    log_error "Failed to create session"
    exit 1
  }
  
  # Export for GitHub Actions output
  export SESSION_URL="$session_url"
  echo "session_url=$session_url" >> "$GITHUB_OUTPUT"
  
  # Post initial comment to PR with session link
  local comment_body="🤖 **Vibe Code Review Started**

A Vibe Code session has been created to review this PR.

🔗 [Open Session]($session_url)

The Vibe assistant will review the code and post detailed comments shortly.

---
*Command: \`$command\`* | *Trigger: $EVENT_NAME*"
  
  post_summary_comment "$REPO" "$PR_NUMBER" "$comment_body" || {
    log_error "Failed to post initial comment"
    # Don't fail the action, just log
  }
  
  log_info "Success! Session URL: $session_url"
  log_info "Note: Code review will be posted to the PR by the Vibe assistant running in the session"
}

# Run main
main
