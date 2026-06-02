# Vibe Code Review GitHub Action

Automated code review using Mistral Vibe with persistent context across triggers.

## 🎯 Features

### ✅ Implemented

- **Automated Code Review**: Fully automated PR reviews with comment posting
- **Two Operation Modes**:
  - **Automatic mode** (default): Vibe reviews and posts comments automatically
  - **Interactive mode**: Creates a Vibe Code Web session for manual interaction
- **Persistent Context**: Review history stored in hidden PR comments
- **Slash Commands**: Support for `/vibe review`, `/vibe fix`, `/vibe add tests`, `/vibe explain`
- **Structured Output**: Categorized issues (high/medium/low priority) with GitHub suggestions
- **Session Links**: Posts interactive session URLs when requested
- **Bot Loop Prevention**: Automatically skips commands from bot users
- **Rate Limit Handling**: Retries GitHub API calls with exponential backoff

### 📋 Architecture

This action uses **two distinct modes** to work around Nuage API limitations:

#### Mode 1: Interactive Session (Default)
```
GitHub Event → Action → Vibe (teleport mode) → Extract URL → Post Link
```
- Creates a **Vibe Code Web session** with context
- Posts session link to PR
- User interacts manually in the web UI
- Context from previous sessions included in prompt

#### Mode 2: Automatic Review
```
GitHub Event → Action → Vibe (programmatic mode) → Parse JSON → Post comments via gh CLI
```
- Vibe runs in **programmatic mode without teleport**
- Assistant returns **structured JSON** with review findings
- Action parses JSON and posts comments automatically
- Full context maintained via hidden comment history

## 🚀 Usage

### 1. Copy the Example Workflow

Copy [`.github/workflows/vibe-review.example.yml`](vibe-review.example.yml) to your repository's `.github/workflows/` directory, e.g., as `vibe-review.yml`.

### 2. Add Required Secrets

Create the following repository secret:
- **`MISTRAL_API_KEY`**: Your Mistral API key from [console.mistral.ai](https://console.mistral.ai)

### 3. Customize (Optional)

```yaml
- name: Run Vibe Code Review
  uses: ./.github/actions/vibe-code-review
  with:
    # Required
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    
    # Optional
    workdir: "./src"           # Working directory
    review_mode: "thorough"    # quick | normal | thorough
    mode: "interactive"         # interactive | review
    debug: "false"             # Enable debug logging
```

## 🎮 Trigger Commands

### Automatic Triggers
- **PR opened**: Automatically triggers a full code review
- **PR synchronized** (push): Re-reviews with updated code
- **PR reopened**: Re-reviews the PR

### Manual Triggers (via PR comments)

#### Automatic Review Commands (posts comments automatically)
- `/vibe review` - Perform a full code review
- `/vibe review again` - Re-review the PR
- `/vibe review <file>` - Review a specific file
- `/vibe fix` - Suggest fixes for issues
- `/vibe fix <file>` - Fix issues in a specific file
- `/vibe add tests` - Generate tests for the changes
- `/vibe add tests for <file>` - Generate tests for a specific file
- `/vibe explain` - Explain the code changes
- `/vibe explain <topic>` - Explain a specific topic

#### Interactive Session Commands (creates session link only)
- `/vibe interactive` - Start an interactive session
- `/vibe session` - Same as interactive
- `/vibe start session` - Same as interactive

#### @Mention Syntax
- `@mistral-vibe review` - Same as `/vibe review`
- `@mistral-vibe fix the issues` - Same as `/vibe fix`

## 📄 Output Format

### Automatic Mode: Summary Comment

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
- ✅ Good use of type hints
```

### Automatic Mode: Inline Comments

For code fixes, inline review comments are posted with:

**Regular comments**: For issues that need explanation

**Suggestions**: For code fixes using GitHub's suggestion syntax:
```suggestion
fixed code here
```
This creates a one-click apply button in GitHub.

### Interactive Mode: Session Link

```markdown
### 🤖 Mistral Vibe Session

A Vibe Code Web session has been created for this PR.

**Command**: `/vibe review`

[Open Vibe Code Session](https://chat.mistral.ai/session/abc123)

You can interact with the assistant in this session.
```

## 🔧 How It Works

### Session Context Persistence

To maintain context across multiple triggers (pushes, comments), the action stores review history in a **hidden PR comment**:

```html
<!-- VIBE_SESSION: eyJ2ZXJzaW9uIjogIjEuMCIsICJyZXZpZXdfaGlzdG9yeSI6IFtd... -->
```

This JSON contains:
- `version`: Metadata schema version
- `pr_number`: PR number
- `repository`: Repository name
- `sessions`: Array of interactive session info (URLs, timestamps)
- `review_history`: Array of previous review summaries
- `comment_tracking`: For future use (tracking posted comments)

### Interactive Session Flow (Default)

1. Trigger detected (PR event, `/vibe` command, or any trigger)
2. Fetch PR diff from GitHub
3. Get previous context from hidden comment
4. Build prompt with diff + history
5. Run `vibe --teleport` to create web session
6. Extract session URL from output
7. Post session link to PR
8. Save session info to hidden comment

**User interaction**: User manually opens the session link and interacts with the assistant in the browser.

### Automatic Review Flow

1. Trigger detected (with `mode: "review"` or `/vibe review` command)
2. Fetch PR diff from GitHub
3. Get previous review history from hidden comment
4. Build prompt with diff + history
5. Run `vibe --agent code-reviewer --no-teleport`
6. Parse JSON response from assistant
7. Post summary comment to PR issue
8. Post inline comments and suggestions to PR review
9. Save review summary to hidden comment

## 📋 Requirements

### GitHub Token Permissions

The `GITHUB_TOKEN` must have:
- `pull-requests: write` - To post PR review comments
- `issues: write` - To post and update issue comments
- `contents: read` - To fetch PR diffs

These permissions are automatically granted when using `secrets.GITHUB_TOKEN` in a workflow with the appropriate `permissions` block.

### Dependencies

The action automatically installs:
- `uv` - Python package manager (via astral-sh/setup-uv)
- `mistral-vibe` - The Vibe CLI tool (via uv sync)
- `gh` CLI - GitHub CLI (via actions/github-cli/setup-gh-cli)
- `jq` - JSON processor (installed per-OS)

## 🎛️ Configuration

### Environment Variables

| Variable | Description | Required | Default |
|----------|-------------|----------|---------|
| `GITHUB_TOKEN` | GitHub API token | Yes | - |
| `MISTRAL_API_KEY` | Mistral API key | Yes | - |
| `WORKDIR` | Working directory relative to repo root | No | "." |
| `REVIEW_MODE` | Review intensity (quick/normal/thorough) | No | "normal" |
| `MODE` | Execution mode (review/interactive) | No | "interactive" |
| `DEBUG` | Enable debug logging | No | "false" |

### Review Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `quick` | Focus on critical issues only | Fast feedback on small changes |
| `normal` | Balanced review (high + medium) | Most PRs |
| `thorough` | Comprehensive analysis (all priorities) | Important/large PRs |

### Execution Modes

| Mode | Description | Output |
|------|-------------|--------|
| `interactive` | Creates web session for manual interaction | Posts session link only (default) |
| `review` | Automatic review with comment posting | Posts comments to PR |

## 📁 Examples

### Basic Workflow (Automatic Reviews)

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

### Interactive Mode Only

```yaml
- uses: ./.github/actions/vibe-code-review
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    mode: "interactive"
```

### With Custom Settings

```yaml
- uses: ./.github/actions/vibe-code-review
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    workdir: "./app"
    review_mode: "thorough"
    debug: "true"
```

### Only on Specific Branches

```yaml
on:
  pull_request:
    types: [opened, synchronize]
    branches: [main, develop]
```

## 🚨 Limitations & Known Issues

### Current Limitations

1. **Session URLs change**: Each interactive session has a new URL (by design)
2. **Large diffs**: PRs with very large diffs (>20KB) are truncated
3. **Concurrent triggers**: The `concurrency` setting prevents race conditions, but rapid triggers may still have issues
4. **Rate limits**: GitHub API and Mistral API both have rate limits
5. **No comment resolution**: Cannot yet mark comments as resolved when issues are fixed

### Workarounds

1. **Large PRs**: Use `review_mode: "quick"` for large PRs, or split into multiple smaller PRs
2. **Comment resolution**: Manually delete outdated comments
3. **Session continuation**: Use automatic mode for continuous review; interactive mode for one-off sessions

## 🔍 Troubleshooting

### Common Issues

1. **"gh CLI not found"**
   - Ensure the GitHub CLI action runs before this action
   - Check the workflow includes `uses: actions/github-cli/setup-gh-cli@v3`

2. **"REPO not set"**
   - Ensure the `REPOSITORY` or `GITHUB_REPOSITORY` environment variable is set
   - This should be automatically set by GitHub Actions

3. **"Failed to create teleport session"**
   - Check your Mistral API key is valid
   - Ensure the `mistral_api_key` secret is correctly set
   - Verify network connectivity to Mistral services

4. **No comments posted**
   - Check the GITHUB_TOKEN has `pull-requests: write` permission
   - Verify the workflow has the correct `permissions` block
   - In debug mode, check the JSON response from Vibe

5. **Session URL not extracted**
   - The teleport output format may have changed
   - Enable debug mode to see the full output

### Debug Mode

Enable debug logging by setting `debug: "true"`:

```yaml
- uses: ./.github/actions/vibe-code-review
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    mistral_api_key: ${{ secrets.MISTRAL_API_KEY }}
    debug: "true"
```

This will output detailed logs including:
- The prompt sent to Vibe
- The JSON response received
- GitHub API calls and responses
- Error details

### Checking Logs

View workflow logs in GitHub Actions to see detailed output from the action.

## 🛠️ Development

### Project Structure

```
.github/actions/vibe-code-review/
├── action.yml          # Composite action definition
├── entrypoint.sh       # Main orchestration script
└── README.md           # This file
```

### Local Testing with `act`

1. Install `act`: https://github.com/nektos/act
2. Create a test event file:

```json
# .github/actions/vibe-code-review/test-pr.json
{
  "action": "opened",
  "number": 123,
  "pull_request": {
    "number": 123,
    "diff_url": "https://github.com/owner/repo/pull/123.diff",
    "patch_url": "https://github.com/owner/repo/pull/123.patch",
    "user": {
      "login": "testuser"
    }
  },
  "repository": {
    "full_name": "owner/repo",
    "name": "repo",
    "owner": {
      "login": "owner"
    }
  }
}
```

3. Run the action:

```bash
act -j vibe-review \
  -e test-pr.json \
  -s MISTRAL_API_KEY=your_api_key \
  -s GITHUB_TOKEN=your_github_token \
  --env DEBUG=true
```

### Testing Interactive Mode

```json
# test-comment.json
{
  "action": "created",
  "issue": {
    "number": 123,
    "pull_request": {
      "number": 123
    }
  },
  "comment": {
    "id": 123456,
    "body": "/vibe review",
    "user": {
      "login": "testuser"
    }
  },
  "repository": {
    "full_name": "owner/repo"
  }
}
```

## 📚 JSON Response Schema

For automatic mode, the assistant must return JSON in this format:

```json
{
  "status": "approved" | "request_changes" | "needs_review",
  "summary": "Brief summary of the PR",
  "issues": {
    "high": [
      {
        "description": "Brief description of the issue",
        "file": "src/file.py",
        "line": 42,
        "details": "Detailed explanation of the issue",
        "suggestion": "Optional: suggested fix"
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
```

The action parses this JSON and:
- Posts a summary comment with categorized issues
- Posts inline comments for specific issues
- Posts GitHub suggestions for code in `suggestions_code`

## 🎓 Best Practices

1. **Start with automatic mode** for CI/CD integration
2. **Use interactive mode** for complex reviews requiring human judgment
3. **Set review_mode appropriately**: quick for small changes, thorough for major PRs
4. **Monitor the first few runs** in debug mode to verify JSON output
5. **Customize the prompt** by forking and modifying `build_review_prompt()`
6. **Use concurrency** to prevent multiple simultaneous reviews on the same PR

## 🤝 Contributing

This action is part of the Mistral Vibe project. Contributions are welcome!

### Issues & Bug Reports

- Open an issue in the Mistral Vibe repository
- Include the workflow file and logs
- Specify the trigger event and command used

### Feature Requests

- Open a discussion or issue describing the use case
- Include examples of desired behavior
- Explain the problem it solves

## 📜 License

This action is licensed under the same terms as the Mistral Vibe project.

## 🆘 Support

For issues or questions:
- Open an issue in the Mistral Vibe repository
- Check the [Mistral AI Documentation](https://docs.mistral.ai)
- Join the Mistral AI community
