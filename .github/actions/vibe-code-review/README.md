# Vibe Code Review GitHub Action

Automated code review using Mistral Vibe with persistent session context across triggers.

## Features

- **Automated PR Reviews**: Automatically reviews code on PR creation and updates
- **Persistent Sessions**: One Vibe Code session per PR that maintains context across multiple triggers
- **Slash Commands**: Support for `/vibe review`, `/vibe fix`, `/vibe add tests`, `/vibe explain`, etc.
- **Structured Output**: Categorized issues (high/medium/low priority) in a clean format
- **GitHub Suggestions**: Uses GitHub's suggestion syntax for one-click code fixes
- **Session Links**: Posts Vibe Code session URLs to PR for manual interaction

## ⚠️ Important: How It Works (Async Nature)

This action **creates a Vibe Code Web session** but **does NOT directly post review comments** to your PR. Here's what happens:

1. The GitHub Action creates a **teleport session** with your PR context and command
2. The action posts an **initial comment** to the PR with a link to the session
3. **The Vibe assistant runs asynchronously** in that session and posts comments using the `gh` CLI
4. Comments appear on your PR **after the Vibe assistant completes its work**

**This means:**
- ✅ You get a session link immediately
- ⏳ Review comments appear a short time later (depends on Vibe response time)
- 🔄 Each trigger creates a **new session with full history** (due to API limitations)
- 📝 Session context is maintained via hidden PR comments

## Why New Sessions Per Trigger?

The Nuage API does not expose an endpoint for sending messages to existing sessions (`POST https://chat.mistral.ai/api/code-trpc/sessions.sendMessage?batch=1` is web-only). 

**Our workaround:** Store conversation history in a hidden PR comment (`<!-- VIBE_SESSION: {base64 JSON} -->`) and create a new teleport session with the full history + new command for each trigger.

**User experience:** It appears as a continuous conversation even though technically it's new sessions with shared context.

## Usage

### 1. Copy the Example Workflow

Copy [`.github/workflows/vibe-review.example.yml`](vibe-review.example.yml) to your repository's `.github/workflows/` directory.

### 2. Add Required Secrets

Create the following repository secret:
- **`MISTRAL_API_KEY`**: Your Mistral API key from [console.mistral.ai](https://console.mistral.ai)
  - ⚠️ **Cost**: Each teleport session uses Mistral API credits
  - 💡 Get your API key from the Mistral console

### 3. Customize (Optional)

```yaml
- name: Run Vibe Code Review
  uses: ./.github/actions/vibe-code-review  # Local action (code in your repo)
  # OR for remote usage:
  # uses: mistralai/mistral-vibe/.github/actions/vibe-code-review@v2
  with:
    # Required
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    
    # Optional
    workdir: "./src"           # Working directory relative to repo root
    review_mode: "thorough"    # quick | normal | thorough
    auto_approve: "true"       # Enable auto-approve for teleport (required for PR branches)
```

### 4. Trigger Commands

#### Automatic Triggers
- **PR opened**: Automatically triggers a full code review
- **PR synchronized** (push): Re-reviews with updated code
- **PR reopened**: Re-reviews the PR

#### Manual Triggers (via PR comments)

Use these commands in a PR comment to trigger actions:

| Command | Description |
|---------|-------------|
| `/vibe review` | Perform a full code review |
| `/vibe review again` | Re-review the PR |
| `/vibe review <file>` | Review a specific file |
| `/vibe fix` | Suggest fixes for issues |
| `/vibe fix <file>` | Fix issues in a specific file |
| `/vibe add tests` | Generate tests for the changes |
| `/vibe add tests for <file>` | Generate tests for a specific file |
| `/vibe explain` | Explain the code changes |
| `/vibe explain <topic>` | Explain a specific topic or change |
| `@mistral-vibe review` | Same as `/vibe review` |
| `@mistral-vibe fix the issues` | Same as `/vibe fix` |

**Note:** Commands from bot users (github-actions, mistral-vibe) are ignored to prevent loops.

## Output Format

### Initial Comment (Posted Immediately by Action)

```markdown
🤖 **Vibe Code Review Started**

A Vibe Code session has been created to review this PR.

🔗 [Open Session](https://chat.mistral.ai/session/abc123)

The Vibe assistant will review the code and post detailed comments shortly.

---
*Command: `review`* | *Trigger: pull_request*
```

### Review Comments (Posted Later by Vibe Assistant)

The Vibe assistant will post:

#### Summary Comment

```markdown
## Mistral Vibe Code Review

**Status**: ✅ Approved / ⚠️ Request Changes / 🔍 Needs Review

**Description**: Brief summary of findings

### Issues Found

#### 🔴 High Priority (Must Fix Before Merge)
- [ ] `src/api.py:42` - Missing error handling
- [ ] `src/db.py:87` - SQL injection vulnerability

#### 🟡 Medium Priority (Should Fix)
- [ ] `src/utils.py:101` - Inconsistent return type

#### 🟢 Low Priority (Nice to Have)
- [ ] `src/models.py:15` - Add type hints

### Strengths
- ✅ Comprehensive test coverage
- ✅ Clean code organization

[Open Session](https://chat.mistral.ai/session/abc123)
```

#### Inline Comments

For specific code issues, inline review comments with:
- **Regular comments**: For issues that need explanation
- **Suggestions**: For code fixes using GitHub's suggestion syntax:
  ```suggestion
  # Fixed code with proper error handling
  try:
      result = risky_operation()
  except SpecificError as e:
      logger.error(f"Operation failed: {e}")
      raise
  ```

## Requirements

### GitHub Token Permissions

The `GITHUB_TOKEN` must have:
- `pull-requests: write` - To post PR review comments
- `issues: write` - To post and update issue comments
- `contents: read` - To fetch PR diffs

These permissions are automatically granted when using `secrets.GITHUB_TOKEN` in a workflow with:

```yaml
permissions:
  pull-requests: write
  issues: write
  contents: read
```

### Dependencies

The action requires:
- `gh` CLI (GitHub CLI) - Automatically installed via `actions/github-cli/setup-gh-cli`
- `uv` - Automatically installed via `astral-sh/setup-uv`
- `jq` - Installed via `sudo apt-get install -y jq`
- Mistral Vibe - Installed via `uv sync`

## Configuration

### Environment Variables

| Variable | Description | Required | Default | Notes |
|----------|-------------|----------|---------|-------|
| `GITHUB_TOKEN` | GitHub API token | Yes | - | Automatically masked in logs |
| `MISTRAL_API_KEY` | Mistral API key | Yes | - | **⚠️ This costs money to use** |
| `WORKDIR` | Working directory | No | `.` | Relative to repo root |
| `REVIEW_MODE` | Review intensity | No | `normal` | quick/normal/thorough |
| `AUTO_APPROVE` | Enable auto-approve | No | `true` | Required for PR branches |
| `DEBUG` | Enable debug logging | No | `false` | Set to "true" for verbose output |

### Review Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `quick` | Focus on critical issues only | Fast feedback on small changes |
| `normal` | Balanced review | Most PRs |
| `thorough` | Comprehensive analysis | Important/large PRs |

## Examples

### Local Repository (Action Code in Your Repo)

```yaml
name: Vibe Review
on:
  pull_request:
    types: [opened, synchronize, reopened]
  issue_comment:
    types: [created]

permissions:
  pull-requests: write
  issues: write
  contents: read

jobs:
  review:
    runs-on: ubuntu-latest
    concurrency:
      group: vibe-review-${{ github.event.pull_request.number || github.event.issue.number }}
      cancel-in-progress: false
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Run Vibe Code Review
        uses: ./.github/actions/vibe-code-review
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
```

### Remote Action (From mistral-vibe Repository)

```yaml
- name: Run Vibe Code Review
  uses: mistralai/mistral-vibe/.github/actions/vibe-code-review@v2
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    workdir: "./app"
    review_mode: "thorough"
```

### With Custom Settings

```yaml
- name: Run Vibe Code Review
  uses: ./.github/actions/vibe-code-review
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    workdir: "./src"
    review_mode: "quick"
    auto_approve: "true"
```

### Only on Specific Branches

```yaml
on:
  pull_request:
    types: [opened, synchronize]
    branches: [main, develop]
```

## Session Management

### Hidden Comment Format

Session metadata is stored in a hidden PR comment with the format:

```html
<!-- VIBE_SESSION: eyJ2ZXJzaW9uIjogIjEuMCIsICJzZXNzaW9ucyI6IFtd... -->
```

The JSON contains:
- `version`: Metadata schema version
- `pr_number`: PR number
- `repository`: Repository name
- `sessions`: Array of session objects with URLs, timestamps, commands
- `current_session_id`: ID of the current session
- `comment_tracking`: Tracking info for posted comments

### Session History

Each session entry includes:
- `session_id`: Unique session identifier
- `session_url`: Full URL to the Vibe Code session
- `created_at`: ISO timestamp
- `trigger`: Event type (pull_request, issue_comment)
- `command`: Command that was executed
- `messages`: Array of conversation messages (stored but not yet fully implemented)

### Session Size Limits

- **Max prompt length**: 30,000 characters (truncated if exceeded)
- **Max session metadata**: 50,000 characters (old sessions trimmed if exceeded)
- **GitHub comment max**: 65,536 characters

## Rate Limits & Cost

### Mistral API
- Each teleport session uses Mistral API credits
- Cost depends on your Mistral plan
- Check [console.mistral.ai](https://console.mistral.ai) for pricing

### GitHub API
- Standard GitHub API rate limits apply
- The action makes ~5-10 API calls per trigger
- Most repositories have sufficient limits

## Troubleshooting

### Common Issues

#### "gh CLI not found"
**Solution:** The action installs it automatically via `actions/github-cli/setup-gh-cli`. If this fails, check your runner has network access.

#### "Failed to create teleport session"
**Solutions:**
1. Verify `MISTRAL_API_KEY` is correct and has credits
2. Check `WORKDIR` exists and is a valid directory
3. Enable `DEBUG=true` to see full error output

#### "No comments posted to PR"
**Note:** The action posts an **initial comment** with the session link. The actual review comments are posted **asynchronously** by the Vibe assistant running in the session. Check:
1. The session link in the initial comment
2. The Vibe Code Web session for errors
3. GitHub Actions workflow logs

#### "Session URL not extracted"
**Solution:** The URL extraction looks for patterns like `https://chat.mistral.ai/session/abc123`. If the format changes, the action needs updating.

### Debug Mode

Enable debug logging by setting the `DEBUG` environment variable:

```yaml
env:
  DEBUG: "true"
```

Or pass it via workflow:

```bash
act -j vibe-review -e test-event.json -s MISTRAL_API_KEY=your_key -s DEBUG=true
```

### Checking Logs

View workflow logs in GitHub Actions to see:
- Input validation results
- Teleport session creation output
- Session URL extraction
- API call errors

## Limitations

1. **Async Review Comments**: Review comments are posted by the Vibe assistant asynchronously, not synchronously by the action
2. **True session resumption not available**: Each trigger creates a new session with history (API limitation)
3. **Session URLs change**: Each new session has a different URL, but conversation context is maintained
4. **Large diffs**: Very large PRs may hit token limits (prompt truncated at 30,000 chars)
5. **No direct API access**: Cannot send messages to existing sessions via Nuage API
6. **Cost**: Each teleport session uses Mistral API credits

## Security

### Secret Handling
- `MISTRAL_API_KEY` is passed via GitHub Actions secrets and is automatically masked in logs
- The API key is used to create teleport sessions via `vibe --teleport`
- Prompts are passed via stdin to avoid command-line argument exposure
- All GitHub API calls use the provided `GITHUB_TOKEN`

### Input Sanitization
- File paths are validated to prevent path traversal attacks
- Line numbers are validated to be numeric
- Comment bodies are truncated to GitHub's maximum size
- Workdir is validated to exist before use

## Contributing

This action is part of the Mistral Vibe project. Contributions are welcome!

### Development Setup

1. Clone the repository
2. Make changes to files in `.github/actions/vibe-code-review/`
3. Test locally using `act`:
   ```bash
   # Install act: https://github.com/nektos/act
   act -j vibe-review -e .github/actions/vibe-code-review/test-pr-event.json \
     -s MISTRAL_API_KEY=your_api_key \
     -s GITHUB_TOKEN=your_github_token
   ```
4. Commit and push changes

### Testing

Create test event files for local testing:

```json
# test-pr-event.json
{
  "action": "opened",
  "number": 123,
  "pull_request": {
    "number": 123
  },
  "repository": {
    "full_name": "owner/repo",
    "owner": {
      "login": "owner"
    },
    "name": "repo"
  }
}

# test-comment-event.json
{
  "action": "created",
  "issue": {
    "number": 123,
    "pull_request": {}
  },
  "comment": {
    "body": "/vibe review",
    "user": {
      "login": "human-user"
    }
  },
  "repository": {
    "full_name": "owner/repo"
  }
}
```

### Test Event Types

| Event | File | Description |
|-------|------|-------------|
| PR opened | `test-pr-event.json` | Tests initial PR review |
| PR push | `test-pr-sync-event.json` | Tests re-review on push |
| Comment | `test-comment-event.json` | Tests slash command |

## Support

For issues or questions:
- Open an issue in the [Mistral Vibe repository](https://github.com/mistralai/mistral-vibe)
- Check the [Mistral AI Documentation](https://docs.mistral.ai)
- Join the Mistral AI community

## License

This action is licensed under the same terms as the Mistral Vibe project.
