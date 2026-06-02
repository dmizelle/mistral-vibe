# Vibe Code Review GitHub Action

Automated code review using Mistral Vibe with persistent session context across triggers.

## Features

- **Automated PR Reviews**: Automatically reviews code on PR creation and updates
- **Persistent Sessions**: One Vibe Code session per PR that maintains context across multiple triggers
- **Slash Commands**: Support for `/vibe review`, `/vibe fix`, `/vibe add tests`, `/vibe explain`, etc.
- **Structured Output**: Categorized issues (high/medium/low priority) in a clean format
- **GitHub Suggestions**: Uses GitHub's suggestion syntax for one-click code fixes
- **Session Links**: Posts Vibe Code session URLs to PR for manual interaction

## How It Works

This action creates a **new teleport session with full conversation history** for each trigger, since the Nuage API does not expose an endpoint for sending messages to existing sessions. Session metadata and conversation history are stored in hidden PR comments to maintain context.

### Session Continuation Pattern

1. On first trigger (PR opened), a new teleport session is created
2. Session metadata (URL, history, etc.) is stored in a hidden comment: `<!-- VIBE_SESSION: {base64 JSON} -->`
3. On subsequent triggers (push, comment, etc.):
   - Previous conversation history is retrieved from the hidden comment
   - A **new teleport session** is created with the full history + new command
   - Session metadata is updated with new session info
4. This provides the appearance of a continuous session while working around API limitations

## Usage

### 1. Copy the Example Workflow

Copy [`.github/workflows/vibe-review.example.yml`](vibe-review.example.yml) to your repository's `.github/workflows/` directory, e.g., as `vibe-review.yml`.

### 2. Add Required Secrets

Create the following repository secret:
- **`MISTRAL_API_KEY`**: Your Mistral API key from [console.mistral.ai](https://console.mistral.ai)

### 3. Customize (Optional)

You can customize the workflow by modifying these inputs:

```yaml
- name: Run Vibe Code Review
  uses: ./.github/actions/vibe-code-review
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
- `/vibe review` - Perform a full code review
- `/vibe review again` - Re-review the PR
- `/vibe review <file>` - Review a specific file
- `/vibe fix` - Suggest fixes for issues
- `/vibe fix <file>` - Fix issues in a specific file
- `/vibe add tests` - Generate tests for the changes
- `/vibe add tests for <file>` - Generate tests for a specific file
- `/vibe explain` - Explain the code changes
- `/vibe explain <topic>` - Explain a specific topic or change
- `@mistral-vibe review` - Same as `/vibe review`
- `@mistral-vibe fix the issues` - Same as `/vibe fix`

## Output Format

### Summary Comment

The action posts a structured summary comment with:

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

[Open Vibe Code Session](https://chat.mistral.ai/session/abc123)
```

### Inline Comments

For specific code issues, inline review comments are posted with:
- **Regular comments**: For issues that need explanation
- **Suggestions**: For code fixes using GitHub's suggestion syntax:
  ```suggestion
  fixed code here
  ```

## Requirements

### GitHub Token Permissions

The `GITHUB_TOKEN` must have:
- `pull-requests: write` - To post PR review comments
- `issues: write` - To post and update issue comments
- `contents: read` - To fetch PR diffs

These permissions are automatically granted when using `secrets.GITHUB_TOKEN` in a workflow with the appropriate `permissions` block.

### Dependencies

The action requires:
- `gh` CLI (GitHub CLI) - Automatically installed via `actions/github-cli/setup-gh-cli`
- `uv` - Automatically installed via `astral-sh/setup-uv`
- `jq` - For JSON processing
- Mistral Vibe - Installed via `uv sync`

## Configuration

### Environment Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `GITHUB_TOKEN` | GitHub API token | Yes | - |
| `MISTRAL_API_KEY` | Mistral API key | Yes | - |
| `WORKDIR` | Working directory | No | `.` |
| `REVIEW_MODE` | Review intensity | No | `normal` |
| `AUTO_APPROVE` | Enable auto-approve | No | `true` |

### Review Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `quick` | Focus on critical issues only | Fast feedback on small changes |
| `normal` | Balanced review | Most PRs |
| `thorough` | Comprehensive analysis | Important/large PRs |

## Examples

### Basic Workflow

```yaml
name: Vibe Review
on: [pull_request]
jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
      issues: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: ./.github/actions/vibe-code-review
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
```

### With Custom Working Directory

```yaml
- uses: ./.github/actions/vibe-code-review
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    workdir: "./app"
    review_mode: "thorough"
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
- `messages`: Array of conversation messages

## Troubleshooting

### Common Issues

1. **"gh CLI not found"**: Ensure the GitHub CLI action runs before this action
2. **"Failed to create teleport session"**: Check your Mistral API key is valid
3. **No comments posted**: Verify the GITHUB_TOKEN has write permissions
4. **Session URL not extracted**: The teleport output format may have changed

### Debug Mode

Enable debug logging by setting the `DEBUG` environment variable:

```yaml
env:
  DEBUG: "true"
```

### Checking Logs

View workflow logs in GitHub Actions to see detailed output from the action.

## Limitations

1. **True session resumption not available**: Due to API limitations, each trigger creates a new session with history rather than truly resuming
2. **Rate limits**: Mistral API and GitHub API both have rate limits
3. **Session links change**: Each new session has a new URL, but the conversation context is maintained
4. **Large diffs**: Very large PRs may hit token limits

## Contributing

This action is part of the Mistral Vibe project. Contributions are welcome!

### Development Setup

1. Clone the repository
2. Make changes to files in `.github/actions/vibe-code-review/`
3. Test locally using `act`:
   ```bash
   act -j vibe-review -e test-event.json -s MISTRAL_API_KEY=your_key
   ```
4. Commit and push changes

### Testing

Create test events for local testing:

```json
# .github/actions/vibe-code-review/test-pr.json
{
  "action": "opened",
  "number": 123,
  "pull_request": {
    "number": 123,
    "diff_url": "https://github.com/owner/repo/pull/123.diff"
  },
  "repository": {
    "full_name": "owner/repo"
  }
}
```

## License

This action is licensed under the same terms as the Mistral Vibe project.

## Support

For issues or questions:
- Open an issue in the Mistral Vibe repository
- Check the [Mistral AI Documentation](https://docs.mistral.ai)
- Join the Mistral AI community
