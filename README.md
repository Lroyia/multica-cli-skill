# multica-cli-skill

**English** | [中文](README.zh.md)

Reuse the user's existing Multica CLI login configuration to create, query, and update Multica issues, and to manage comments and attachments, directly through Bash + curl + jq.

By default it reads `~/.multica/config.json` written by `multica login`. This skill **only reads** that file — it never modifies it or echoes the token back to output.

## Implementation basis

This skill is **not an API wrapper built by guessing**. It is implemented by reading the Multica server source code:

- Source repository: <https://github.com/multica-ai/multica.git>
- Key reference directories: `server/internal/handler/` (`issue.go`, `comment.go`, `project.go`, `squad.go`, `workspace.go`, etc.), `server/internal/cli/` (`config.go`, `client.go`), `server/cmd/server/router.go`, `server/cmd/multica/cmd_*.go`
- Every request URL, header, query parameter, body field, valid value set, error code, and auth scope is reverse-engineered from the source above — not from any unpublished official API docs
- The complete field → source-line mapping lives in [`references/multica-cli-skill-source-map.md`](references/multica-cli-skill-source-map.md). If server behavior diverges from this document, the source code wins and the skill must be updated to match

In other words, this skill is roughly equivalent to "replaying the HTTP request behind each `multica` CLI subcommand with curl + jq", so field names, valid value sets, and error messages match the backend exactly.

## Use cases

The most common installation is **into a runtime coding tool** (Claude Code, Cursor, Aider, custom agents, etc.), so that when those tools produce work output they can use this skill to push "process evidence" and "artifacts" back to the Multica client in real time.

**Typical scenario: unit test screenshot feedback**

The coding tool runs unit tests → captures screenshots with Playwright / Puppeteer / headless Chrome → uploads them to the relevant issue via this skill, with a comment explaining the outcome.

```bash
# 1. Coding tool finishes unit tests; assume artifacts are in ./screenshots/
ls ./screenshots
# login.png  dashboard.png  checkout-failed.png

# 2. Upload each screenshot as an attachment via this skill
bash scripts/attachments.sh upload ./screenshots/login.png --issue MUL-123
bash scripts/attachments.sh upload ./screenshots/dashboard.png --issue MUL-123
bash scripts/attachments.sh upload ./screenshots/checkout-failed.png --issue MUL-123

# 3. Post a comment with screenshot references + test verdict
bash scripts/comment.sh add MUL-123 \
  --content "$(cat <<'EOF'
This round of unit tests (3/3 passing):

- ✅ Login page: login.png
- ✅ Dashboard: dashboard.png
- ❌ Checkout page: checkout-failed.png (button click unresponsive, reproduced 5/5)

Suggested next step: locate the onClick handler on the checkout page.
EOF
)"

# 4. If needed, advance the issue status
bash scripts/update.sh MUL-123 --status in_review
```

Benefits:

- **Traceable process**: screenshots, error stacks, and run logs no longer stay only in the agent's context — they land on the Multica issue timeline
- **Zero client overhead**: viewers see the image and the verdict directly inside the Multica App / Web; the agent does not need to re-send the image over IM
- **Async-consumable**: the on-duty teammate can scroll the issue stream and immediately see what the coding tool is doing, without waiting for the agent to report in

Other similar scenarios:

| Scenario | Coding tool artifact | Delivered via skill |
| --- | --- | --- |
| UI walkthrough | screenshots + screen recording | attachment + comment |
| E2E test run | trace.zip / video.webm | attachment + comment + status update |
| Performance benchmark | flame graph / report PDF | attachment + comment |
| Code review | diff / lint report | comment (Markdown is enough) |
| Production alert | log slice | comment (prefix with `/note` to avoid triggering agent) |

## Repository layout

```text
multica-cli-skill/
├── .claude-plugin/
│   ├── plugin.json         # Claude Code plugin manifest
│   └── marketplace.json    # Self-hosted marketplace entry
├── skills/
│   └── multica-cli-skill/  # The skill itself
│       ├── SKILL.md
│       ├── scripts/        # order.sh, list.sh, update.sh, comment.sh, attachments.sh
│       └── references/     # multica-cli-skill-source-map.md
├── README.md               # English (default)
├── README.zh.md            # Chinese
├── config.json.example     # Reference template for --config custom files only
├── config.schema.json
├── LICENSE
└── .gitignore
```

## Install as a Claude Code plugin

The repository ships with a self-hosted marketplace. Add it once, then install the plugin:

```text
# 1. Add the marketplace (once)
/plugin marketplace add lroyia/multica-cli-skill https://gitee.com/lroyia/multica-app/raw/master/multica-cli-skill/.claude-plugin/marketplace.json

# 2. Install the plugin
/plugin install multica-cli-skill@multica-cli-skill
```

After installation, the skill loads automatically when Claude Code needs it. Use it just like before — pass an `mul_xxx` token, fuzzy match assignees, create / query / update issues, post comments, upload attachments.

To upgrade later:

```text
/plugin marketplace update multica-cli-skill
/plugin install multica-cli-skill@multica-cli-skill   # reinstall
# or
claude plugin update multica-cli-skill
```

## Quick start (1 minute)

```bash
# 1. First-time use: let Multica CLI write ~/.multica/config.json
multica login

# 2. Enter the skill directory
cd multica-cli-skill/skills/multica-cli-skill

# 3. Create an issue
bash scripts/order.sh \
  --title "Prod alert: payment success rate dropped" \
  --description "Please investigate the payment errors in the last hour" \
  --assignee "Frontend Team" \
  --project "Payment Refactor" \
  --priority high

# 4. Query
bash scripts/list.sh list --open-only
bash scripts/list.sh search --q "payment success rate" --limit 10
bash scripts/list.sh get MUL-123

# 5. Update
bash scripts/update.sh MUL-123 --status done

# 6. Comment
bash scripts/comment.sh add MUL-123 --content "Root cause located"
bash scripts/comment.sh list MUL-123 --threads-only

# 7. Attachment
bash scripts/attachments.sh upload ./error.png --issue MUL-123
bash scripts/attachments.sh list MUL-123
```

## Configuration selection and override order

The scripts look up the configuration file in this order (stop at first hit):

1. `--config <path>`
2. `<skill_dir>/config.json`
3. `$MULTICA_CLI_ORDER_CONFIG`
4. `~/.multica/config.json`

After the file is loaded, these field-level overrides apply:

1. `$MULTICA_TOKEN` overrides the `token` field
2. `--server-url` overrides `server_url`
3. `--app-url` overrides `app_url`
4. `--workspace-id` overrides `workspace_id`

So both `--config` and `$MULTICA_CLI_ORDER_CONFIG` select a **complete configuration file** — they do not replace a single field inside another file.

The configuration format matches the Multica CLI's `CLIConfig`:

```json
{
  "server_url": "https://api.multica.ai",
  "app_url": "https://app.multica.ai",
  "workspace_id": "00000000-0000-0000-0000-000000000000",
  "token": "mul_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

- `server_url` and `token` are required.
- `app_url` falls back to `server_url` when missing.
- `workspace_id` is required for member/project matching and attachment operations.
- `config.json.example` and `config.schema.json` are for custom `--config` files; daily use does not require copying the template.

## Missing configuration

When the default configuration is missing, the script aborts with:

```text
Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG.
```

When an explicit `--config` or `$MULTICA_CLI_ORDER_CONFIG` points to a non-existent file, the error is `config file not found` and no other credentials are tried.

## Windows Git Bash

The scripts prefer `$HOME`, fall back to `$USERPROFILE`, and normalize Windows backslashes to `/`. They also set the necessary `MSYS2_ARG_CONV_EXCL` prefixes so Git Bash does not rewrite `/note`, `/uploads`, and `/api` to `C:/Program Files/Git/...`. Both of the following path styles resolve:

```text
/c/Users/Alice/.multica/config.json
C:/Users/Alice/.multica/config.json
```

Dependencies: `bash`, `curl`, `jq`, `uname`. On Windows, run via Git Bash and install jq with `choco install jq`.

## Security notes

1. `~/.multica/config.json` is only read; no script ever overwrites it.
2. The scripts never print the full configuration file or the full Authorization header.
3. Do not put real tokens in the repo, test fixtures, logs, or issue comments.
4. Each run creates a permission-restricted `/tmp/multica-cli-skill.XXXXXX/` private directory and cleans it up via an exit trap, to prevent cross-user reads and symlink-overwrite attacks.
5. For independent CI / bot credentials, pass `--config` explicitly to this skill.

## auto-match

`--assignee` / `--squad` / `--agent` / `--member` / `--project` are scored in this order:

| Score | Rule |
| --- | --- |
| 100 | Exact match (case-sensitive) |
| 90 | Exact match (case-insensitive) |
| 70 | Case-insensitive substring |
| 50 | Substring after stripping spaces, `-`, `_` |

`--strict-match` only accepts a single exact match. See `SKILL.md` for the rest of the API, parameters, and behavior.
