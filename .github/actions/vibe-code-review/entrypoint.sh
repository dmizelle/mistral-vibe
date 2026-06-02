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
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found"; exit 1; }
command -v uv >/dev/null 2>&1 || { echo "uv not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

# =============================================================================
# Session Metadata Schema (JSON stored in hidden PR comments)
# =============================================================================
# {
#   "version": "1.0",
#   "pr_number": 123,
#   "repository": "owner/repo",
#   "sessions": [
#     {
#       "session_id": "nuage-abc123",
#       "session_url": "https://chat.mistral.ai/session/abc123",
#       "created_at": "2024-01-01T00:00:00Z",
#       "trigger": "pull_request",
#       "command": "review",
#       "messages": [
#         {"role": "user", "content": "Review this PR", "timestamp": "..."},
#         {"role": "assistant", "content": "Found issues...", "timestamp": "..."}
#       ]
#     }
#   ],
#   "current_session_id": "nuage-abc123",
#   "comment_tracking": {
#     "comments": [
#       {"id": 123456, "file": "src/api.py", "line": 42, "priority": "high", 
#        "issue": "Missing error handling", "resolved": false, "type": "inline"}
#     ]
#   }
# }
# =============================================================================

# =============================================================================
# Utility Functions
# =============================================================================

# Get the action's own directory
ACTION_DIR=$(dirname "$(readlink -f "$0")")

# Get the repository root (where the PR code lives)
REPO_ROOT=$(pwd)

# Get GitHub context variables
REPO=${REPOSITORY:-${GITHUB_REPOSITORY:-}}
PR_NUMBER=${PR_NUMBER:-}
EVENT_NAME=${EVENT_NAME:-${GITHUB_EVENT_NAME:-}}
COMMENT_BODY=${COMMENT_BODY:-}
COMMENT_ID=${COMMENT_ID:-}
COMMENT_USER=${COMMENT_USER:-}
AUTO_APPROVE=${AUTO_APPROVE:-true}
REVIEW_MODE=${REVIEW_MODE:-normal}
WORKDIR=${WORKDIR:-.}

# Full workdir path
FULL_WORKDIR=$(realpath "$REPO_ROOT/$WORKDIR" 2>/dev/null || echo "$REPO_ROOT/$WORKDIR")

# Log messages
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
# Hidden Comment Management
# =============================================================================

# Get session metadata from hidden comment
# Returns JSON string (may be empty if no session exists)
get_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  
  if [ -z "$repo" ] || [ -z "$pr_number" ]; then
    echo '{"version": "1.0", "pr_number": null, "repository": null, "sessions": [], "comment_tracking": {"comments": []}}'
    return
  fi
  
  local comment
  comment=$(gh api repos/"$repo"/issues/"$pr_number"/comments \
    --jq '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .body' 2>/dev/null || true)
  
  if [ -n "$comment" ]; then
    # Extract and decode the base64 JSON
    local encoded
    encoded=$(echo "$comment" | sed 's/.*<!-- VIBE_SESSION: //;s/ -->.*//' || true)
    if [ -n "$encoded" ]; then
      echo "$encoded" | base64 -d 2>/dev/null || echo '{"version": "1.0", "sessions": []}'
      return
    fi
  fi
  
  # Return empty metadata
  echo '{"version": "1.0", "pr_number": '"$pr_number'", "repository": "'"$repo"'", "sessions": [], "comment_tracking": {"comments": []}}'
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
  encoded=$(echo "$metadata" | base64 -w 0 2>/dev/null || true)
  
  if [ -z "$encoded" ]; then
    log_error "Failed to encode metadata"
    return 1
  fi
  
  # Find existing hidden comment
  local existing_id
  existing_id=$(gh api repos/"$repo"/issues/"$pr_number"/comments \
    --jq '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .id' 2>/dev/null || true)
  
  local body="<!-- VIBE_SESSION: $encoded -->"
  
  if [ -n "$existing_id" ]; then
    # Update existing comment
    log_debug "Updating existing session metadata comment $existing_id"
    gh api repos/"$repo"/issues/comments/"$existing_id" \
      -X PATCH \
      -f body="$body" >/dev/null 2>&1 || {
      log_error "Failed to update session metadata comment"
      return 1
    }
  else
    # Create new comment
    log_debug "Creating new session metadata comment"
    gh api repos/"$repo"/issues/"$pr_number"/comments \
      -f body="$body" >/dev/null 2>&1 || {
      log_error "Failed to create session metadata comment"
      return 1
    }
  fi
  
  return 0
}

# Delete session metadata comment
# Args: repo, pr_number
delete_session_metadata() {
  local repo="$1"
  local pr_number="$2"
  
  local existing_id
  existing_id=$(gh api repos/"$repo"/issues/"$pr_number"/comments \
    --jq '.[] | select(.body | test("<!-- VIBE_SESSION:")) | .id' 2>/dev/null || true)
  
  if [ -n "$existing_id" ]; then
    gh api repos/"$repo"/issues/comments/"$existing_id" \
      -X DELETE >/dev/null 2>&1 || {
      log_error "Failed to delete session metadata comment"
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
    "["
    + .role
    + "] "
    + (.timestamp | sub("\\."; "") | sub("T"; " ") | sub("Z$"; ""))
    + ": "
    + .content
  ' 2>/dev/null || true)
  
  if [ -n "$history" ]; then
    echo "Previous conversation:"
    echo "$history"
  else
    echo ""
  fi
}

# Update metadata with new message
# Args: metadata, role, content
# Returns updated metadata JSON
update_session_messages() {
  local metadata="$1"
  local role="$2"
  local content="$3"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  
  # Add message to current session
  echo "$metadata" | jq \
    --arg role "$role" \
    --arg content "$content" \
    --arg ts "$timestamp" \
    '.sessions |= map(if .session_id == .current_session_id then .messages += [{"role": $role, "content": $content, "timestamp": $ts}] else . end)' 2>/dev/null || echo "$metadata"
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
  
  # Build teleport command
  local teleport_cmd=(
    uv run --directory "$ACTION_DIR" vibe
    --teleport
  )
  
  # Add auto-approve if enabled
  if [ "$AUTO_APPROVE" = "true" ]; then
    teleport_cmd+=(" --agent auto-approve ")
  fi
  
  # Add workdir if specified
  if [ -n "$workdir" ] && [ "$workdir" != "." ]; then
    teleport_cmd+=(" --workdir "$workdir")
  fi
  
  # Add prompt
  teleport_cmd+=(" -p """$prompt"""")
  
  log_debug "Running: ${teleport_cmd[*]}"
  
  # Execute and capture output
  local teleport_output
  teleport_output=$(cd "$workdir" && "${teleport_cmd[@]}" 2>&1 || true)
  
  log_debug "Teleport output:\n$teleport_output"
  
  # Extract URL from output
  # Format: TeleportCompleteEvent(url='https://...')
  local url
  url=$(echo "$teleport_output" | grep -o "url='[^']*'" | sed "s/url='//;s/'//" | head -1 || true)
  
  if [ -n "$url" ]; then
    log_info "Session created: $url"
    echo "$url"
    return 0
  else
    # Try alternative patterns
    url=$(echo "$teleport_output" | grep -oi "https://[^\[\]\s]*/session/[^\[\]\s]*" | head -1 || true)
    if [ -n "$url" ]; then
      log_info "Session created (alternative pattern): $url"
      echo "$url"
      return 0
    fi
    
    log_error "Failed to extract session URL from teleport output"
    echo ""
    return 1
  fi
}

# =============================================================================
# Session Continuation
# =============================================================================

# Continue an existing session with new command
# Args: pr_number, command, workdir, repo
# Returns: session URL or empty string on failure
continue_session() {
  local pr_number="$1"
  local command="$2"
  local workdir="$3"
  local repo="$4"
  
  log_info "Continuing session for PR #$pr_number with command: $command"
  
  # Get current metadata
  local metadata
  metadata=$(get_session_metadata "$repo" "$pr_number")
  
  # Get conversation history
  local history
  history=$(get_conversation_history "$metadata")
  
  # Build prompt with history
  local prompt
  prompt=$(cat <<EOF
$history

New command: $command

Context:
- Repository: $repo
- PR Number: #$pr_number
- Working Directory: $workdir
- You are Mistral Vibe, an AI coding assistant.
- You are performing code review and can use the gh CLI to post comments.
EOF
  )
  
  # Create new teleport session with history
  local url
  url=$(create_teleport_session "$prompt" "$workdir")
  
  if [ -n "$url" ]; then
    # Update metadata
    local session_id
    session_id=$(echo "$url" | grep -oE '[^/]+$' || echo "new-session-$(date +%s)")
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    local new_metadata
    new_metadata=$(echo "$metadata" | jq \
      --arg url "$url" \
      --arg sid "$session_id" \
      --arg ts "$timestamp" \
      --arg cmd "$command" \
      '.sessions += [{"session_id": $sid, "session_url": $url, "created_at": $ts, "trigger": "issue_comment", "command": $cmd, "messages": []}] | .current_session_id = $sid' 2>/dev/null || echo "$metadata")
    
    save_session_metadata "$repo" "$pr_number" "$new_metadata"
    
    echo "$url"
    return 0
  else
    echo ""
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
  
  # Check for /vibe command
  if [[ "$body" =~ ^/vibe\s+(.*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  
  # Check for @mention
  if [[ "$body" =~ @(mistral-vibe|vibe)\[bot\]\s+(.*) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  
  if [[ "$body" =~ @(mistral-vibe|vibe)\s+(.*) ]]; then
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

# Post a summary comment to the PR
# Args: repo, pr_number, markdown_content, parent_comment_id (optional)
post_summary_comment() {
  local repo="$1"
  local pr_number="$2"
  local content="$3"
  local parent_id="${4:-}"
  
  # Add session link if available
  if [ -n "$SESSION_URL" ]; then
    content="$content

---

### 🤖 Mistral Vibe Session
A Vibe Code session has been created for this PR. You can interact with it here:

[Open Vibe Code Session]($SESSION_URL)"
  fi
  
  if [ -n "$parent_id" ]; then
    # Update existing comment
    gh api repos/"$repo"/issues/comments/"$parent_id" \
      -X PATCH \
      -f body="$content" >/dev/null 2>&1 || {
      log_error "Failed to update comment $parent_id"
      return 1
    }
  else
    # Create new comment
    gh api repos/"$repo"/issues/"$pr_number"/comments \
      -f body="$content" >/dev/null 2>&1 || {
      log_error "Failed to post comment"
      return 1
    }
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
  
  gh api repos/"$repo"/pulls/"$pr_number"/comments \
    -f path="$file" \
    -f line="$line" \
    -f side="$side" \
    -f body="$body" >/dev/null 2>&1 || {
    log_error "Failed to post inline comment for $file:$line"
    return 1
  }
  
  return 0
}

# Post a suggestion comment
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

# =============================================================================
# Review Prompt Generation
# =============================================================================

# Build the review prompt for automated reviews
build_review_prompt() {
  local pr_number="$1"
  local diff="$2"
  local repo="$3"
  
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
gh api repos/$repo/issues/$pr_number/comments \\
  -f body="STRUCTURED_MARKDOWN"

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
# Command Execution
# =============================================================================

# Execute a vibe command and return the session URL
# Args: repo, pr_number, command, workdir
execute_command() {
  local repo="$1"
  local pr_number="$2"
  local command="$3"
  local workdir="$4"
  
  local metadata
  metadata=$(get_session_metadata "$repo" "$pr_number")
  local has_session
  has_session=$(echo "$metadata" | jq -r '.sessions | length > 0' 2>/dev/null || echo "false")
  
  local url=""
  
  if [ "$has_session" = "true" ]; then
    # Continue existing session
    url=$(continue_session "$pr_number" "$command" "$workdir" "$repo")
  else
    # Create new session
    local diff
    diff=$(gh api repos/"$repo"/pulls/"$pr_number" --jq '.diff' 2>/dev/null || echo "")
    
    # Build prompt based on command
    local prompt
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
    
    url=$(create_teleport_session "$prompt" "$workdir")
    
    if [ -n "$url" ]; then
      # Save initial session metadata
      local session_id
      session_id=$(echo "$url" | grep -oE '[^/]+$' || echo "nuage-$(date +%s)")
      local timestamp
      timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      
      local new_metadata
      new_metadata=$(echo "$metadata" | jq \
        --arg url "$url" \
        --arg sid "$session_id" \
        --arg ts "$timestamp" \
        --arg cmd "$command" \
        '.sessions += [{"session_id": $sid, "session_url": $url, "created_at": $ts, "trigger": "pull_request", "command": $cmd, "messages": []}] | .current_session_id = $sid' 2>/dev/null || echo "$metadata")
      
      save_session_metadata "$repo" "$pr_number" "$new_metadata"
    fi
  fi
  
  echo "$url"
}

# =============================================================================
# Main Logic
# =============================================================================

main() {
  log_info "Starting Vibe Code Review Action"
  log_debug "Repository: $REPO, PR: $PR_NUMBER, Event: $EVENT_NAME"
  
  # Validate required parameters
  if [ -z "$REPO" ]; then
    log_error "REPOSITORY not set"
    exit 1
  fi
  
  if [ -z "$PR_NUMBER" ]; then
    # Not all events have PR numbers - for now, exit gracefully
    log_info "No PR number found, skipping (event: $EVENT_NAME)"
    exit 0
  fi
  
  # Determine trigger type and command
  local command=""
  local is_vibe_cmd=false
  local should_skip=false
  
  case "$EVENT_NAME" in
    pull_request)
      # PR created, synchronized, or reopened
      command="review"
      ;;
    issue_comment)
      # Comment on PR or issue
      if is_vibe_command "$COMMENT_BODY"; then
        is_vibe_cmd=true
        command=$(parse_command "$COMMENT_BODY")
        
        # Check author to prevent loops
        if [[ "$COMMENT_USER" =~ github-actions|mistral-vibe|vibe ]]; then
          log_info "Skipping: command from bot user: $COMMENT_USER"
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
  
  log_info "Executing command: $command"
  
  # Execute the command and get session URL
  local session_url
  session_url=$(execute_command "$REPO" "$PR_NUMBER" "$command" "$FULL_WORKDIR")
  
  if [ -n "$session_url" ]; then
    # Export for output
    export SESSION_URL="$session_url"
    
    # Output for GitHub Actions
    echo "session_url=$session_url" >> $GITHUB_OUTPUT
    
    log_info "Success! Session URL: $session_url"
  else
    log_error "Failed to create session"
    exit 1
  fi
}

# Run main
main
