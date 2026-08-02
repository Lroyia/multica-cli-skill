# multica-cli-skill

[English](README.md) | **中文**

复用用户现有的 Multica CLI 登录配置，直接通过 Bash + curl + jq 创建、查询、更新 Multica issue，并管理评论和附件。

默认读取 `multica login` 写入的 `~/.multica/config.json`。本 skill **只读**该文件，不会修改或回显其中的 token。

## 实现依据

本 skill **不是凭空猜测的 API 包装**，而是基于阅读 Multica 服务端源码实现：

- 源码仓库：<https://github.com/multica-ai/multica.git>
- 关键参考目录：`server/internal/handler/`（`issue.go` / `comment.go` / `project.go` / `squad.go` / `workspace.go` 等）、`server/internal/cli/`（`config.go` / `client.go`）、`server/cmd/server/router.go`、`server/cmd/multica/cmd_*.go`
- 每个请求的 URL、Header、Query 参数、Body 字段、合法值集合、错误码、auth 作用域都从上述源码反推，而非依赖官方未发布的 API 文档
- 完整的字段→源码行号对照表见 [`references/multica-cli-skill-source-map.md`](references/multica-cli-skill-source-map.md)；如果服务端行为与文档不一致，以源码为准并同步更新 skill

换句话说，本 skill ≈ "用 curl + jq 复现一遍 `multica` CLI 子命令背后的 HTTP 请求"，所以字段名、合法值集合、错误信息都与后端严格一致。

## 使用场景

最常见的安装位置是**给运行时的编码工具（Claude Code、Cursor、Aider、自研 agent 等）使用**，让它们在产出工作结果时，可以借助本 skill 把"过程证据"和"产物"实时回报到 Multica 客户端。

**典型场景：单元测试截图反馈**

编码工具运行单测 → 用 Playwright / Puppeteer / headless Chrome 截图 → 通过本 skill 上传到对应 issue，并附评论说明结论。

```bash
# 1. 编码工具跑完单测，假设产物在 ./screenshots/ 下
ls ./screenshots
# login.png  dashboard.png  checkout-failed.png

# 2. 用本 skill 把截图作为附件逐张上传
bash scripts/attachments.sh upload ./screenshots/login.png --issue MUL-123
bash scripts/attachments.sh upload ./screenshots/dashboard.png --issue MUL-123
bash scripts/attachments.sh upload ./screenshots/checkout-failed.png --issue MUL-123

# 3. 输出一段评论，附带截图引用 + 测试结论
bash scripts/comment.sh add MUL-123 \
  --content "$(cat <<'EOF'
本轮单测结果（3/3 通过）：

- ✅ 登录页：login.png
- ✅ 仪表盘：dashboard.png
- ❌ 结算页：checkout-failed.png（按钮点击无响应，已复现 5/5）

建议下一步：定位 checkout 页的 onClick handler。
EOF
)"

# 4. 如有需要，把 issue 状态推进
bash scripts/update.sh MUL-123 --status in_review
```

这样做的收益：

- **过程可追溯**：截图、错误堆栈、运行日志不再只停留在 agent 的上下文里，而是落到 Multica issue 的时间线上
- **客户端零感知**：在 Multica App / Web 里直接看到图、看到结论，不需要 agent 把图重新发回 IM
- **可被异步消费**：值班同学刷 issue 流时，能直接看到编码工具的最新进度，不需要等 agent 主动汇报

其他类似场景：

| 场景 | 编码工具产物 | 通过 skill 投递 |
| --- | --- | --- |
| UI 走查 | 截图 + 录屏 | 附件 + 评论 |
| E2E 跑测 | trace.zip / video.webm | 附件 + 评论 + 状态更新 |
| 性能压测 | flame graph / 报告 PDF | 附件 + 评论 |
| 代码评审 | diff / lint report | 评论（Markdown 即可） |
| 线上告警 | 日志切片 | 评论（附 `/note` 前缀避免触发 agent） |

## 目录结构

```text
multica-cli-skill/
├── .claude-plugin/
│   ├── plugin.json         # Claude Code 插件 manifest
│   └── marketplace.json    # 自托管 marketplace 条目
├── skills/
│   └── multica-cli-skill/  # skill 本身
│       ├── SKILL.md
│       ├── scripts/        # order.sh, list.sh, update.sh, comment.sh, attachments.sh
│       └── references/     # multica-cli-skill-source-map.md
├── README.md               # 英文（默认）
├── README.zh.md            # 中文
├── config.json.example     # 仅供 --config 自定义文件参考
├── config.schema.json
├── LICENSE
└── .gitignore
```

## 安装为 Claude Code 插件

仓库自带一个自托管 marketplace。一次性加入 marketplace，然后安装插件：

```text
# 1. 加入 marketplace（一次性）
/plugin marketplace add lroyia/multica-cli-skill https://gitee.com/lroyia/multica-app/raw/master/multica-cli-skill/.claude-plugin/marketplace.json

# 2. 安装插件
/plugin install multica-cli-skill@multica-cli-skill
```

安装完成后，skill 在 Claude Code 需要时自动加载。沿用原来的用法——传 `mul_xxx` token、按名字模糊匹配负责人、创建 / 查询 / 更新 issue、发评论、上传附件。

后续升级：

```text
/plugin marketplace update multica-cli-skill
/plugin install multica-cli-skill@multica-cli-skill   # 重装
# 或
claude plugin update multica-cli-skill
```

## 一分钟上手

```bash
# 1. 首次使用：让 Multica CLI 写入 ~/.multica/config.json
multica login

# 2. 进入 skill
cd multica-cli-skill/skills/multica-cli-skill

# 3. 创建 issue
bash scripts/order.sh \
  --title "线上告警: 支付成功率下降" \
  --description "请排查最近一小时的支付错误" \
  --assignee "前端组" \
  --project "支付重构" \
  --priority high

# 4. 查询
bash scripts/list.sh list --open-only
bash scripts/list.sh search --q "支付成功率" --limit 10
bash scripts/list.sh get MUL-123

# 5. 更新
bash scripts/update.sh MUL-123 --status done

# 6. 评论
bash scripts/comment.sh add MUL-123 --content "问题已定位"
bash scripts/comment.sh list MUL-123 --threads-only

# 7. 附件
bash scripts/attachments.sh upload ./error.png --issue MUL-123
bash scripts/attachments.sh list MUL-123
```

## 配置选择与覆盖顺序

脚本按以下顺序**逐级查找**配置文件（命中即停）：

1. `--config <path>`
2. `<skill_dir>/config.json`
3. `$MULTICA_CLI_ORDER_CONFIG`
4. `~/.multica/config.json`

读取文件后再应用字段覆盖：

1. `$MULTICA_TOKEN` 覆盖配置中的 `token`
2. `--server-url` 覆盖 `server_url`
3. `--app-url` 覆盖 `app_url`
4. `--workspace-id` 覆盖 `workspace_id`

因此 `--config` 与 `$MULTICA_CLI_ORDER_CONFIG` 都会选择一份**完整配置文件**；不会只替换其中某个字段。

配置格式与 Multica CLI 的 `CLIConfig` 一致：

```json
{
  "server_url": "https://api.multica.ai",
  "app_url": "https://app.multica.ai",
  "workspace_id": "00000000-0000-0000-0000-000000000000",
  "token": "mul_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

- `server_url`、`token` 必填。
- `app_url` 缺省时回退到 `server_url`。
- `workspace_id` 在成员/项目匹配和附件操作中需要。
- `config.json.example` 与 `config.schema.json` 可用于自定义 `--config` 文件；日常使用无需复制模板。

## 配置缺失

默认配置不存在时，脚本会直接报错并提示：

```text
Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG.
```

显式 `--config` 或 `$MULTICA_CLI_ORDER_CONFIG` 指向不存在的文件时，会返回 `config file not found`，不会回退到其他凭证。

## Windows Git Bash

脚本优先使用 `$HOME`，为空时回退到 `$USERPROFILE`，并把 Windows 反斜杠规范为 `/`。同时设置 `MSYS2_ARG_CONV_EXCL` 的必要前缀，避免 Git Bash 把 `/note`、`/uploads` 和 `/api` 误转换为 `C:/Program Files/Git/...`。因此以下两类路径都能解析：

```text
/c/Users/Alice/.multica/config.json
C:/Users/Alice/.multica/config.json
```

依赖：`bash`、`curl`、`jq`、`uname`。Windows 可通过 Git Bash 运行，并使用 `choco install jq` 安装 jq。

## 安全说明

1. `~/.multica/config.json` 仅被读取，不会被任何脚本改写。
2. 脚本不会输出配置全文或完整 Authorization header。
3. 不要把真实 token 放入仓库、测试 fixture、日志或 issue 评论。
4. 每次运行会创建权限受限的 `/tmp/multica-cli-skill.XXXXXX/` 私有目录，并通过退出 trap 清理，避免跨用户读取和符号链接覆盖。
5. 如果需要 CI / bot 的独立凭证，给本 skill 显式传 `--config` 即可。

## auto-match

`--assignee` / `--squad` / `--agent` / `--member` / `--project` 会按以下顺序评分：

| 分数 | 规则 |
| --- | --- |
| 100 | 完全相同（大小写敏感） |
| 90 | 完全相同（大小写不敏感） |
| 70 | 大小写不敏感子串 |
| 50 | 去掉空格、`-`、`_` 后做子串匹配 |

`--strict-match` 只接受唯一的完全相同结果。其余 API、参数与行为详见 `SKILL.md`。
