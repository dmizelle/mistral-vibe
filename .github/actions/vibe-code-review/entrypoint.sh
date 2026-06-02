#!/bin/bash
# Main Logic
# =============================================================================

main() {
  log_info "Starting Vibe Code Review Action"
  log_debug "Repository: $REPO, PR: $PR_NUMBER, Event: $EVENT_NAME, Mode: ${MODE:-review}"
  
  # Validate inputs
  validate_inputs
=======
# =============================================================================
# Main Logic
# =============================================================================

main() {
  log_info "Starting Vibe Code Review Action"
  log_debug "Repository: $REPO, PR: $PR_NUMBER, Event: $EVENT_NAME, Mode: ${MODE:-review}"
  log_debug "All environment variables: $(env | sort)"
  log_debug "GITHUB_ACTION_PATH: $GITHUB_ACTION_PATH"
  log_debug "GITHUB_WORKSPACE: $GITHUB_WORKSPACE"
  log_debug "Current directory: $(pwd)"
  
  # Validate inputs
  validate_inputsVibe Code Review GitHub Action - Main Entrypoint
# Implements automated code review with Mistral Vibe
#
# Architecture:
# - For automated reviews: Uses programmatic mode to get assistant response,
#   then parses and posts comments directly via gh CLI
# - For interactive sessions: Creates teleport session and posts link
# - Session context stored in hidden PR comments for persistence

set -euo pipefail

# =============================================================================
# Configuration & Environment
# =============================================================================

# Export GITHUB_TOKEN for gh CLI
export GITHUB_TOKEN=${GITHUB_TOKEN:-}

# Set REPO from REPOSITORY or GITHUB_REPOSITORY
export REPO=${REPOSITORY:-${GITHUB_REPOSITORY:-}}

# Ensure required tools are available
command -v gh >/dev/null 2>&1 || { echo "[ERROR] gh CLI not found. Ensure actions/github-cli/setup-gh-cli ran successfully."; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "[ERROR] uv not found. Ensure astral-sh/setup-uv ran successfully."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[ERROR] jq not found."; exit 1; }

# =============================================================================
# Constants
# =============================================================================

readonly SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
readonly SESSION_MARKER="<!-- VIBE_SESSION:"
readonly SESSION_MARKER_END="-->"
readonly MAX_SESSION_METADATA_SIZE=50000
readonly MAX_PROMPT_LENGTH=28000  # Leave room for system messages
readonly MAX_DIFF_LENGTH=20000
readonly GITHUB_MAX_COMMENT_SIZE=65000

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
  # Validate REPO (set from REPOSITORY env var)
  if [ -z "${REPO:-}" ]; then
    log_error "REPO not set. Environment variable REPOSITORY or GITHUB_REPOSITORY must be set."
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

  # Validate and set WORKDIR
  local repo_root=${GITHUB_WORKSPACE:-$(pwd)}
  if [ "${WORKDIR:-.}" = "." ]; then
    FULL_WORKDIR="$repo_root"
  else
    FULL_WORKDIR="$repo_root/${WORKDIR:-}"
  fi
  
  if [ ! -d "$FULL_WORKDIR" ]; then
    log_error "Workdir does not exist: $FULL_WORKDIR"
    exit 1
  fi

  # Validate MODE
  case "${MODE:-review}" in
    review|interactive|fix|test) ;;
    *) 
      log_error "Invalid mode: ${MODE:-} (must be review, interactive, fix, or test)"
      exit 1
      ;;
  esac

  log_debug "Validated inputs: REPO=$REPO, PR_NUMBER=$PR_NUMBER, WORKDIR=$WORKDIR, MODE=$MODE, REVIEW_MODE=$REVIEW_MODE"
}

# =============================================================================
# GitHub API Helper with Retries
# =============================================================================

# Make a GitHub API call with retries
# Args: method, endpoint, [jq_filter], [additional_args...]
gh_api() {
  local method="${1:-GET}"
  local endpoint="$2"
  local jq_filter="${3:-}"
  shift 3
  local retries=${GITHUB_API_RETRIES:-3}
  local delay=2
  local attempt

  for attempt in $(seq 1 $retries); do
    if [ -n "$jq_filter" ]; then
      local result
      if [ $# -gt 0 ]; then
        result=$(gh api "$endpoint" --jq "$jq_filter" "$@" 2>&1) && echo "$result" && return 0
      else
        result=$(gh api "$endpoint" --jq "$jq_filter" 2>&1) && echo "$result" && return 0
      fi
    else
      if [ $# -gt 0 ]; then
        gh api "$endpoint" "$@" 2>&1 && return 0
      else
        gh api "$endpoint" 2>&1 && return 0
      fi
    fi
    
    log_error "GitHub API attempt $attempt/$retries failed for $endpoint"
    
    if [ $attempt -lt $retries ]; then
      sleep $delay
      delay=$((delay * 2))
    fi
  done
  
  log_error "GitHub API failed after $retries attempts: $endpoint"
  return 1
}

# =============================================================================
# Hidden Comment Management
# =============================================================================

# Get session metadata from hidden comment
# Returns JSON string (empty if no session exists)
get_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  
  if [ -z "$repo" ] || [ -z "$pr_number" ]; then
    echo '{"version": "1.0", "pr_number": null, "repository": null, "sessions": [], "review_history": [], "comment_tracking": {"comments": []}}'
    return
  fi
  
  local comment
  comment=$(gh_api GET "repos/$repo/issues/$pr_number/comments" \
    '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .body' 2>/dev/null || true)
  
  if [ -n "$comment" ]; then
    # Extract and decode the base64 JSON
    local encoded
    encoded=$(echo "$comment" | sed "s/.*$SESSION_MARKER //;s/ $SESSION_MARKER_END.*//" || true)
    if [ -n "$encoded" ]; then
      # Use base64 -d with proper error handling
      if echo "$encoded" | base64 -d 2>/dev/null; then
        echo "$encoded" | base64 -d
      else
        echo '{"version": "1.0", "sessions": []}'
      fi
      return
    fi
  fi
  
  # Return empty metadata
  echo "{\"version\": \"1.0\", \"pr_number\": $pr_number, \"repository\": \"$repo\", \"sessions\": [], \"review_history\": [], \"comment_tracking\": {\"comments\": []}}"
}

# Save session metadata to hidden comment
# Args: repo, pr_number, metadata_json
save_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  local metadata="$3"
  
  if [ -z "$repo" ] || [ -z "$pr_number" ]; then
    log_error "Cannot save session metadata: missing repo or PR number"
    return 1
  fi
  
  # Encode metadata
  local encoded
  if ! encoded=$(echo "$metadata" | base64 -w 0 2>/dev/null); then
    log_error "Failed to encode metadata"
    return 1
  fi
  
  # Truncate if too large
  if [ ${#encoded} -gt $MAX_SESSION_METADATA_SIZE ]; then
    log_error "Session metadata too large (${#encoded} chars > $MAX_SESSION_METADATA_SIZE), trimming history"
    # Remove old sessions but keep the most recent 5
    metadata=$(echo "$metadata" | jq '.sessions = (.sessions | if length > 5 then .[length-5:] else . end) + .review_history = (.review_history | if length > 10 then .[length-10:] else . end)' 2>/dev/null || echo "$metadata")
    if ! encoded=$(echo "$metadata" | base64 -w 0 2>/dev/null); then
      log_error "Failed to re-encode trimmed metadata"
      return 1
    fi
  fi
  
  local body="$SESSION_MARKER $encoded $SESSION_MARKER_END"
  
  # Find existing hidden comment
  local existing_id
  existing_id=$(gh_api GET "repos/$repo/issues/$pr_number/comments" \
    '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .id' 2>/dev/null || true)
  
  if [ -n "$existing_id" ]; then
    # Update existing comment
    log_debug "Updating existing session metadata comment $existing_id"
    if ! gh_api PATCH "repos/$repo/issues/comments/$existing_id" -f body="$body" >/dev/null 2>&1; then
      log_error "Failed to update session metadata comment $existing_id"
      return 1
    fi
  else
    # Create new comment
    log_debug "Creating new session metadata comment"
    if ! gh_api POST "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null 2>&1; then
      log_error "Failed to create session metadata comment"
      return 1
    fi
  fi
  
  return 0
}

# Get full review history from metadata
# Returns formatted string for inclusion in prompts
get_review_history() {
  local metadata="$1"
  
  if [ -z "$metadata" ]; then
    echo ""
    return
  fi
  
  # Extract review history and format
  local history
  history=$(echo "$metadata" | jq -r '
    .review_history[] | 
    "["
    + (.timestamp | sub("\\."; "") | sub("T"; " ") | sub("Z$"; ""))
    + "] "
    + .role
    + ": "
    + .content
  ' 2>/dev/null || true)
  
  if [ -n "$history" ]; then
    echo "Previous review history:"
    echo "$history"
    echo ""
  else
    echo ""
  fi
}

# =============================================================================
# Vibe Programmatic Mode
# =============================================================================

# Run vibe in programmatic mode (no teleport) and return the assistant's response
# Args: prompt, workdir
# Returns: assistant response or empty string on failure
run_vibe_programmatic() {
  local prompt="$1"
  local workdir="$2"
  
  log_info "Running vibe in programmatic mode..."
  log_debug "Workdir: $workdir"
  
  # Validate prompt length
  if [ ${#prompt} -gt $MAX_PROMPT_LENGTH ]; then
    log_error "Prompt too long (${#prompt} chars > $MAX_PROMPT_LENGTH max)"
    return 1
  fi
  
  # Write prompt to temp file to avoid quoting issues
  local prompt_file
  prompt_file=$(mktemp) || { log_error "Failed to create temp file"; return 1; }
  
  # Use a subshell to ensure cleanup
  (
    printf '%s\n' "$prompt" > "$prompt_file"
    
    # Run vibe with code-review agent in programmatic mode
    local exit_code=0
    local output
    output=$(cd "$workdir" && uv run --directory "$SCRIPT_DIR" vibe \
      --agent code-reviewer \
      --no-teleport \
      < "$prompt_file" 2>&1) || exit_code=$?
    
    rm -f "$prompt_file"
    
    if [ $exit_code -ne 0 ]; then
      log_error "Vibe failed with exit code $exit_code"
      log_debug "Vibe output:\n$output"
      exit 1
    fi
    
    # Extract assistant response (last non-empty line that isn't a status message)
    # Vibe outputs: status messages to stderr, response to stdout
    # In programmatic mode, the response is printed to stdout
    local response
    response=$(echo "$output" | grep -vE '^\[|%|Preparing|Pushing|Syncing|Teleporting|Connected|Waiting' | tail -1 || true)
    
    if [ -n "$response" ]; then
      echo "$response"
      return 0
    else
      log_error "No response from vibe"
      log_debug "Full output:\n$output"
      return 1
    fi
  )
  
  return $?
}

# Run vibe in teleport mode (interactive session)
# Args: prompt, workdir
# Returns: session URL or empty string on failure
create_teleport_session() {
  local prompt="$1"
  local workdir="$2"
  
  log_info "Creating teleport session..."
  log_debug "Workdir: $workdir"
  log_debug "SCRIPT_DIR: $SCRIPT_DIR"
  log_debug "Prompt: $prompt"
  
  # Validate prompt length
  if [ ${#prompt} -gt $MAX_PROMPT_LENGTH ]; then
    log_error "Prompt too long (${#prompt} chars > $MAX_PROMPT_LENGTH max)"
    return 1
  fi
  
  # Write prompt to temp file
  local prompt_file
  prompt_file=$(mktemp) || { log_error "Failed to create temp file"; return 1; }
  
  log_debug "Created temp file: $prompt_file"
  log_debug "Writing prompt to temp file"
  printf '%s\n' "$prompt" > "$prompt_file"
  log_debug "Prompt written to temp file, contents: $(head -c 200 "$prompt_file")"
  
  local exit_code=0
  local output
  log_debug "Running: cd "$workdir" && uv run --directory "$SCRIPT_DIR" vibe --teleport < "$prompt_file" 2>&1"
  output=$(cd "$workdir" && uv run --directory "$SCRIPT_DIR" vibe \
    --teleport \
    < "$prompt_file" 2>&1) || exit_code=$?
  
  log_debug "Vibe teleport output: $output"
  log_debug "Vibe teleport exit code: $exit_code"
  
  rm -f "$prompt_file"
  
  if [ $exit_code -ne 0 ]; then
    log_error "Teleport failed with exit code $exit_code"
    log_debug "Teleport output:\n$output"
    return 1
  fi
  
  # Extract URL from output - URL is printed on its own line in programmatic mode
  local url
  url=$(echo "$output" | grep -E '^https://[^/]+/session/[a-zA-Z0-9_-]+$' | tail -1 || true)
  
  # If not found, try more lenient pattern
  if [ -z "$url" ]; then
    url=$(echo "$output" | grep -oE 'https://[^/]+/session/[a-zA-Z0-9_-]+' | tail -1 || true)
  fi
  
  if [ -n "$url" ]; then
    log_info "Session created: $url"
    echo "$url"
    return 0
  else
    log_error "Failed to extract session URL from teleport output"
    log_debug "Teleport output:\n$output"
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

# Determine the mode from command
# Args: command string
# Returns: mode (review, interactive, fix, test)
determine_mode() {
  local command="$1"
  
  case "$command" in
    interactive|session|"start session")
      echo "interactive"
      ;;
    fix|fix\ *|"fix the issues"|"suggest fixes")
      echo "fix"
      ;;
    test|tests|"add tests"*|"write tests"*)
      echo "test"
      ;;
    *)
      echo "review"
      ;;
  esac
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

# Post a comment to the PR issue
# Args: repo, pr_number, body
post_issue_comment() {
  local repo="$1"
  local pr_number="$2"
  local body="$3"
  
  # Truncate content to GitHub's max comment size
  if [ ${#body} -gt $GITHUB_MAX_COMMENT_SIZE ]; then
    body="${body:0:$GITHUB_MAX_COMMENT_SIZE}... (truncated)"
  fi
  
  if ! gh_api POST "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null 2>&1; then
    log_error "Failed to post issue comment"
    return 1
  fi
  
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
  
  if ! gh_api POST "repos/$repo/pulls/$pr_number/comments" \
    -f path="$file" \
    -f line="$line" \
    -f side="$side" \
    -f body="$body" >/dev/null 2>&1; then
    log_error "Failed to post inline comment for $file:$line"
    return 1
  fi
  
  return 0
}

# Post a suggestion comment (creates one-click apply button in GitHub)
# Args: repo, pr_number, file, line, code
post_suggestion() {
  local repo="$1"
  local pr_number="$2"
  local file="$3"
  local line="$4"
  local code="$5"
  
  local body
  body="\`\`\`suggestion\n$code\n\`\`\`"
  
  post_inline_comment "$repo" "$pr_number" "$file" "$line" "RIGHT" "$body"
}

# Post session link comment
# Args: repo, pr_number, session_url, command
post_session_link() {
  local repo="$1"
  local pr_number="$2"
  local session_url="$3"
  local command="${4:-review}"
  
  local body
  body="### 🤖 Mistral Vibe Session

A Vibe Code Web session has been created for this PR.

**Command**: \`/vibe $command\`

[Open Vibe Code Session]($session_url)

You can interact with the assistant in this session. For automated review comments to be posted, use the \`/vibe review\` command."
  
  post_issue_comment "$repo" "$pr_number" "$body"
}

# =============================================================================
# Review Prompt Generation
# =============================================================================

# Build the review prompt for programmatic mode
# The assistant should return a JSON structure that we can parse
build_review_prompt() {
  local pr_number="$1"
  local diff="$2"
  local repo="$3"
  local command="$4"
  
  # Build context from metadata
  local metadata="$5"
  local history=""
  if [ -n "$metadata" ]; then
    history=$(get_review_history "$metadata")
  fi
  
  # Truncate diff if too large
  if [ ${#diff} -gt $MAX_DIFF_LENGTH ]; then
    diff="${diff:0:$MAX_DIFF_LENGTH}... (diff truncated - full diff available in PR)"
  fi
  
  cat <<EOF
You are Mistral Vibe performing an AUTOMATED code review on GitHub PR #$pr_number in repository $repo.

## Your Tasks

You MUST respond with a VALID JSON object ONLY. Do not add any text before or after the JSON.

### Required JSON Schema

{
  "status": "approved" | "request_changes" | "needs_review",
  "summary": "Brief summary of the PR (1-2 sentences)",
  "issues": {
    "high": [
      {
        "description": "Brief description",
        "file": "src/file.py",
        "line": 42,
        "details": "Detailed explanation",
        "suggestion": "optional code suggestion (without backticks)"
      }
    ],
    "medium": [...],
    "low": [...]
  },
  "strengths": ["list", "of", "positive observations"],
  "suggestions_code": [
    {
      "file": "src/file.py",
      "line": 42,
      "code": "fixed_code_here"
    }
  ]
}

## Review Command

Command: $command

## Previous Review History

$history

## Code Changes to Review

$diff

## Review Guidelines

- Focus on code quality, bugs, security, performance, and test coverage
- Be specific with file paths and line numbers
- For code fixes, provide the corrected code in the suggestion field
- Use suggestion_code array for GitHub suggestion comments
- Categorize issues by severity (high = must fix before merge)

## Review Mode

Mode: ${REVIEW_MODE:-normal}
- quick: Focus on critical issues only (high priority)
- normal: Balanced review (high and medium)
- thorough: Comprehensive review (all priorities)

Respond with JSON ONLY.
EOF
}

# Parse the JSON response from vibe and post comments
# Args: repo, pr_number, json_response, workdir, metadata
parse_and_post_review() {
  local repo="$1"
  local pr_number="$2"
  local json_response="$3"
  local workdir="$4"
  local metadata="$5"
  
  log_info "Parsing review response..."
  log_debug "JSON response:\n$json_response"
  
  # Validate JSON
  if ! echo "$json_response" | jq empty 2>/dev/null; then
    log_error "Invalid JSON response from vibe"
    log_error "Response was: $json_response"
    return 1
  fi
  
  # Extract fields
  local status
  status=$(echo "$json_response" | jq -r '.status // "needs_review"' 2>/dev/null || echo "needs_review")
  
  local summary
  summary=$(echo "$json_response" | jq -r '.summary // "No summary provided"' 2>/dev/null || echo "No summary provided")
  
  # Post summary comment
  local summary_comment
  summary_comment="## Mistral Vibe Code Review

**Status**: "
  
  case "$status" in
    approved) summary_comment+="✅ Approved" ;;
    request_changes) summary_comment+="⚠️ Request Changes" ;;
    *) summary_comment+="🔍 Needs Review" ;;
  esac
  
  summary_comment+="\n\n**Description**: $summary\n\n"
  
  # Add issues by priority
  local has_issues=false
  
  for priority in high medium low; do
    local priority_emoji
    local priority_title
    case "$priority" in
      high) priority_emoji="🔴"; priority_title="High Priority (Must Fix Before Merge)" ;;
      medium) priority_emoji="🟡"; priority_title="Medium Priority (Should Fix)" ;;
      low) priority_emoji="🟢"; priority_title="Low Priority (Nice to Have)" ;;
    esac
    
    local issues
    issues=$(echo "$json_response" | jq -r ".issues.$priority // [] | length")
    
    if [ "$issues" -gt 0 ]; then
      has_issues=true
      summary_comment+="### ${priority_emoji} $priority_title\n\n"
      
      local i=0
      while [ $i -lt $issues ]; do
        local desc
        desc=$(echo "$json_response" | jq -r ".issues.$priority[$i].description // \"\"" 2>/dev/null || echo "")
        local file
        file=$(echo "$json_response" | jq -r ".issues.$priority[$i].file // \"\"" 2>/dev/null || echo "")
        local line
        line=$(echo "$json_response" | jq -r ".issues.$priority[$i].line // 0" 2>/dev/null || echo "0")
        local details
        details=$(echo "$json_response" | jq -r ".issues.$priority[$i].details // \"\"" 2>/dev/null || echo "")
        
        if [ -n "$desc" ] && [ -n "$file" ] && [ "$line" -gt 0 ] 2>/dev/null; then
          summary_comment+="- [ ] \`$file:$line\` - $desc"
          if [ -n "$details" ]; then
            summary_comment+=" - $details"
          fi
          summary_comment+="\n"
        fi
        
        i=$((i + 1))
      done
      
      summary_comment+="\n"
    fi
  done
  
  # Add strengths
  local strengths
  strengths=$(echo "$json_response" | jq -r '.strengths // [] | length')
  
  if [ "$strengths" -gt 0 ]; then
    summary_comment+="### Strengths\n\n"
    
    local i=0
    while [ $i -lt $strengths ]; do
      local strength
      strength=$(echo "$json_response" | jq -r ".strengths[$i] // \"\"" 2>/dev/null || echo "")
      if [ -n "$strength" ]; then
        summary_comment+="- ✅ $strength\n"
      fi
      i=$((i + 1))
    done
    
    summary_comment+="\n"
  fi
  
  # Post inline suggestions
  local suggestions
  suggestions=$(echo "$json_response" | jq -r '.suggestions_code // [] | length' 2>/dev/null || echo "0")
  
  if [ "$suggestions" -gt 0 ]; then
    local i=0
    while [ $i -lt $suggestions ]; do
      local file
      file=$(echo "$json_response" | jq -r ".suggestions_code[$i].file // \"\"" 2>/dev/null || echo "")
      local line
      line=$(echo "$json_response" | jq -r ".suggestions_code[$i].line // 0" 2>/dev/null || echo "0")
      local code
      code=$(echo "$json_response" | jq -r ".suggestions_code[$i].code // \"\"" 2>/dev/null || echo "")
      
      if [ -n "$file" ] && [ "$line" -gt 0 ] 2>/dev/null && [ -n "$code" ]; then
        log_debug "Posting suggestion for $file:$line"
        post_suggestion "$repo" "$pr_number" "$file" "$line" "$code" || log_error "Failed to post suggestion for $file:$line"
      fi
      
      i=$((i + 1))
    done
  fi
  
  # Post summary comment
  if ! post_issue_comment "$repo" "$pr_number" "$summary_comment"; then
    log_error "Failed to post summary comment"
    return 1
  fi
  
  # Save review to history
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  # Create a compact history entry (truncate if needed)
  local history_entry
  history_entry=$(echo "$json_response" | jq \
    --arg ts "$timestamp" \
    --arg cmd "$command" \
    '{role: "assistant", content: (.summary + " | " + .status + " | " + (.issues.high | length | tostring) + " high, " + (.issues.medium | length | tostring) + " medium, " + (.issues.low | length | tostring) + " low issues"), timestamp: $ts, command: $cmd}' 2>/dev/null || echo "")
  
  if [ -n "$history_entry" ]; then
    local new_metadata
    new_metadata=$(echo "$metadata" | jq \
      --argjson entry "$history_entry" \
      '.review_history += [$entry]' 2>/dev/null || echo "$metadata")
    
    save_session_metadata "$repo" "$pr_number" "$new_metadata"
  fi
  
  log_info "Review posted successfully"
  return 0
}

# =============================================================================
# Diff Fetching
# =============================================================================

# Get PR diff
# Args: repo, pr_number
# Returns: diff text
get_pr_diff() {
  local repo="$1"
  local pr_number="$2"
  
  # Try to get unified diff
  local diff
  diff=$(gh_api GET "repos/$repo/pulls/$pr_number" --jq '.diff' 2>/dev/null || true)
  
  if [ -z "$diff" ]; then
    # Try alternative: get patch URL and fetch
    local patch_url
    patch_url=$(gh_api GET "repos/$repo/pulls/$pr_number" --jq '.patch_url' 2>/dev/null || true)
    if [ -n "$patch_url" ]; then
      diff=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$patch_url" 2>/dev/null || true)
    fi
  fi
  
  echo "$diff"
}

# =============================================================================
# Bot Loop Prevention
# =============================================================================

# Check if the trigger author is a bot
is_bot_author() {
  local user="${COMMENT_USER:-}"
  
  if [ -z "$user" ]; then
    # For PR events, check the PR author
    local pr_author
    pr_author=$(gh_api GET "repos/$REPO/pulls/$PR_NUMBER" --jq '.user.login' 2>/dev/null || true)
    user="$pr_author"
  fi
  
  if [ -z "$user" ]; then
    return 1
  fi
  
  # Check against known bot patterns
  case "$user" in
    github-actions*|mistral-vibe*|vibe*|dependabot*|renovate*|actions-user)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# =============================================================================
# Main Command Execution
# =============================================================================

# Execute the main review flow
# Args: repo, pr_number, command, workdir, is_interactive
execute_review() {
  local repo="$1"
  local pr_number="$2"
  local command="$3"
  local workdir="$4"
  local mode="$5"
  
  log_info "Executing $mode mode for PR #$pr_number, command: $command"
  
  # Get current metadata
  local metadata
  metadata=$(get_session_metadata "$repo" "$pr_number")
  
  # Get PR diff
  local diff
  diff=$(get_pr_diff "$repo" "$pr_number")
  
  if [ "$mode" = "interactive" ]; then
    # Create teleport session for manual interaction
    local prompt
    prompt="Command: $command

Context:
- Repository: $repo
- PR Number: #$pr_number
- Working Directory: $workdir

Code Diff:
$diff

You are in an interactive session. The user will interact with you directly in the web UI."
    
    log_debug "About to create teleport session with prompt length: ${#prompt}"
    log_debug "Workdir: $workdir"
    log_debug "Changing to workdir: $workdir"
    
    local session_url
    if ! session_url=$(create_teleport_session "$prompt" "$workdir"); then
      log_error "Failed to create teleport session"
      log_debug "create_teleport_session exit code: $?"
      exit 1
    fi
    
    # Post session link
    post_session_link "$repo" "$pr_number" "$session_url" "$command"
    
    # Save session info
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local session_id
    session_id=$(basename "$session_url")
    
    local new_metadata
    new_metadata=$(echo "$metadata" | jq \
      --arg url "$session_url" \
      --arg sid "$session_id" \
      --arg ts "$timestamp" \
      --arg cmd "$command" \
      '.sessions += [{"session_id": $sid, "session_url": $url, "created_at": $ts, "trigger": "issue_comment", "command": $cmd}] | .current_session_id = $sid' 2>/dev/null || echo "$metadata")
    
    save_session_metadata "$repo" "$pr_number" "$new_metadata"
    
    # Output session URL
    echo "session_url=$session_url" >> "$GITHUB_OUTPUT"
    
  else
    # Programmatic mode: run vibe, get response, post comments
    local prompt
    prompt=$(build_review_prompt "$pr_number" "$diff" "$repo" "$command" "$metadata")
    
    local response
    if ! response=$(run_vibe_programmatic "$prompt" "$workdir"); then
      log_error "Vibe programmatic mode failed"
      exit 1
    fi
    
    # Parse and post the review
    if ! parse_and_post_review "$repo" "$pr_number" "$response" "$workdir" "$metadata"; then
      log_error "Failed to post review comments"
      exit 1
    fi
    
    # Output that review was posted
    echo "review_posted=true" >> "$GITHUB_OUTPUT"
    
  fi
  
  return 0
}

# =============================================================================
# Main Logic
# =============================================================================

main() {
  log_info "Starting Vibe Code Review Action"
  log_debug "Repository: $REPO, PR: $PR_NUMBER, Event: $EVENT_NAME, Mode: ${MODE:-review}"
  
  # Validate inputs
  validate_inputs
  
  # Check for bot author to prevent loops
  if is_bot_author; then
    log_info "Skipping: command from bot user"
    exit 0
  fi
  
  # Determine trigger type and command
  local command=""
  local mode=""
  local is_vibe_cmd=false
  
  case "$EVENT_NAME" in
    pull_request)
      # PR created, synchronized, or reopened
      # Use MODE input as default (interactive or review)
      command="review"
      mode="${MODE:-interactive}"
      ;;
    issue_comment)
      # Comment on PR or issue
      if is_vibe_command "$COMMENT_BODY"; then
        is_vibe_cmd=true
        command=$(parse_command "$COMMENT_BODY")
        mode=$(determine_mode "$command")
        
        # If command is empty, use MODE input as default
        if [ -z "$command" ]; then
          command="review"
          mode="${MODE:-interactive}"
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
  
  log_info "Executing command: $command, Mode: $mode"
  
  # Execute the review
  if ! execute_review "$REPO" "$PR_NUMBER" "$command" "$FULL_WORKDIR" "$mode"; then
    log_error "Failed to execute review"
    exit 1
  fi
  
  log_info "Vibe Code Review completed successfully"
}

# Run main
main
