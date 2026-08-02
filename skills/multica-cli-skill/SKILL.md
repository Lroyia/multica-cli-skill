---
name: multica-cli-skill
description: "Use when you need to create, list, search, fetch, update, comment on, or manage attachments for Multica issues using the user's existing Multica CLI login. Reads `~/.multica/config.json` by default (written by `multica login`), with a config search order of `--config <path>` > `<skill_dir>/config.json` > `$MULTICA_CLI_ORDER_CONFIG` > `~/.multica/config.json`, plus `$MULTICA_TOKEN` overrides, and provides fuzzy assignee/project matching through Bash, curl, and jq. Works in Windows Git Bash, macOS, and Linux."
allowed-tools: Bash(curl *), Bash(jq *), Bash(multica *), Read, Write
---

# 下单 + 自动匹配 + 查询 — Multica Issue 技能

默认读取 `multica login` 写入的 `~/.multica/config.json`，直接调用 Multica 后端创建、查询、更新 issue，并管理评论和附件。适合希望复用本机 CLI 登录状态、但需要脚本化 fuzzy match 和完整 API 能力的用户。配置文件仅被读取，不会被本 skill 改写。

> **v0.12 目录迁移**：本 skill 随 Claude Code 插件市场发布，从仓库根 `SKILL.md` / `scripts/` / `references/` 改为插件规范布局 `skills/multica-cli-skill/{SKILL.md, scripts/, references/}`。脚本里 `SKILL_DIR` 通过 `dirname(dirname(SCRIPT_PATH))` 计算，自动跟随新位置；`<skill_dir>/config.json` 现在指 `skills/multica-cli-skill/config.json`。

> **v0.7 必填收紧**：下单接口（`order.sh`）的必填项现在是 **`--title`** / **`--description`** / **负责人**（`--assignee*` 任一） / **项目**（`--project*` 任一）。状态（`--status`）不传则服务端默认 `todo`（"待办"），与 `server/internal/handler/issue.go` 的 `CreateIssue` 默认行为一致。
>
> **v0.11 配置优先级**：配置文件路径解析由原来的 3 级（`--config` > `$MULTICA_CLI_ORDER_CONFIG` > `~/.multica/config.json`）调整为 4 级：**`--config <path>` > `<skill_dir>/config.json` > `$MULTICA_CLI_ORDER_CONFIG` > `~/.multica/config.json`**。新增的 `<skill_dir>/config.json` 便于把 skill 部署到自包含目录（比如容器内 CI、测试夹具），无需在 `~/.multica/config.json` 之外另设 `MULTICA_CLI_ORDER_CONFIG`。
>
> **v0.1.0 配置变体**：功能继承自 `multica-order` v0.10；唯一的核心差异是默认复用用户的 `~/.multica/config.json`。请求端标识和 `/tmp` 文件前缀独立，两个 skill 可以并存。
>
> **v0.2 保留**：按名字自动匹配小队 / agent / 成员 / 项目（4 级打分 fuzzy match）。
>
> **v0.4 保留**：`list.sh` 工单查询 / 搜索 / 取详情。
>
> **v0.8 新增**：`update.sh` 修改 issue 字段（status / priority / assignee / project / title / description）。调用 `PUT /api/issues/{id-or-identifier}`，会先 `GET` 当前 issue 做 diff、列 pending changes，再问 "Apply? [y/N]" 确认；`--yes` 跳过确认；`--dry-run` 不发请求。
>
> **v0.9 修复**：
> 1. `/api/projects` 返回 `{"projects":[...], "total":N}` 包裹对象（不是裸数组），order.sh / list.sh / update.sh 里的 `pick_best` 直接 `.[ ]` 遍历会报 `Cannot index object with number`。修复：fetch_list / list.sh 的 projects 拉取处增加解包步骤，把 `.projects` 数组写回临时文件，pick_best 依然期望裸数组。
> 2. `update.sh` 的 `pick_best` 有一个先前潜伏的 jq typo：`--arg ifield "$id_field"` 声明了 `ifield`，但 jq 体里写的是 `.[$i][$id_field]`（未定义变量）。以前 `update.sh --project "..."` 走不到这一步（因为 `fetch_list /api/projects` 会先炸），修了 #1 之后会触发，现在一并修正为 `.[$i][$ifield]`。order.sh / list.sh 里的 pick_best 早已用 `$ifield`，不受影响。
>
> **v0.10 新增**：`comment.sh` —— issue 评论的 list / add / update / delete / resolve / unresolve 6 个子命令，覆盖了 `server/internal/handler/comment.go` 暴露的所有客户端入口（`POST /api/issues/{id}/comments`、`GET /api/issues/{id}/comments`、`PUT /api/comments/{id}`、`DELETE /api/comments/{id}`、`POST /api/comments/{id}/resolve`、`DELETE /api/comments/{id}/resolve`）。list 支持 `--threads-only / --summary / --fold / --since / --thread <uuid> / --tail N / --recent N / --list-type / --hide-resolved / --limit N`；add 支持 `--content / --content-file / --type / --parent-id / --attachment-ids / --suppress-agent-ids / --note`；update / delete 默认会问 "Continue? [y/N]"（`--yes` 跳过），因为服务端 `isAuthor || isAdmin` 会放行管理员。**调试时只能使用自己创建的测试评论，避免误改真实评论。**

下面所有结论都可以在 `references/multica-cli-skill-source-map.md` 里找到源码出处。

## 何时使用

- 用户给了一个 `mul_xxx` 或 `mcn_xxx` 形式的 token，希望直接建一个 issue / 任务 / 订单。
- 用户希望"指派给前端组" / "分派给 xiaoming agent" / "放到 支付重构 项目里"，但你只有 CLI token。
- 自动化场景：CI 失败、监控告警、表单提交后，要自动在 Multica 里建一条跟踪工单。
- 想回查"我之前用这个 skill 创建的工单现在什么状态"。
- 想发 / 改 / resolve issue 下的评论（v0.10 `comment.sh`）—— 包括 mark thread resolved / unresolve / reply / 写一条不触发 agent 的 /note。
- 不要使用本 skill 的场景：用户希望走完整 UI 流程、或者只是查看 issue —— 直接用 `multica issue` 即可。

## 凭证从哪来（v0.1.0）

默认复用用户的 Multica CLI 配置 `~/.multica/config.json`。该文件由 `multica login` 写入；本 skill 只读，不会修改它。

### 配置文件路径优先级（v0.11 起 4 级）

按以下顺序**逐级查找**，命中即停：

1. `--config <path>` 显式指定的配置文件（最高优先级，覆盖一切）
2. `<skill_dir>/config.json` —— 脚本所在 skill 目录下的本地 config，便于自包含部署 / 测试
3. `$MULTICA_CLI_ORDER_CONFIG` 环境变量指向的路径
4. `~/.multica/config.json`（由 `multica login` 写入的默认用户配置）

### 字段覆盖（与配置文件路径选择独立）

在选定配置文件后，再依次应用以下覆盖（同样后者覆盖前者）：

1. `$MULTICA_TOKEN` 覆盖所选文件中的 `token`
2. `--server-url` / `--app-url` / `--workspace-id` 覆盖所选文件中的对应字段

所有默认文件都不存在时，先运行 `multica login`；也可以通过 `--config` 指向另一个符合 CLIConfig schema 的文件，或在 `<skill_dir>/config.json` 放一份。

配置 schema 与 `server/internal/cli/config.go` 的 `CLIConfig` 对齐：

```jsonc
{
  "server_url":   "https://api.multica.ai",    // 必填；API 根地址（无尾斜杠）
  "app_url":      "https://app.multica.ai",    // 可选；缺省回退 server_url
  "workspace_id": "5c1f...uuid...",            // 可选；auto-match 成员时必填
  "token":        "mul_xxxxxxxx..."            // 必填；PAT（mul_ / mcn_ 前缀）
}
```

`config.json.example` 仅用于 `--config` 自定义文件场景；日常使用不需要复制，直接复用 `~/.multica/config.json`。完整 JSON Schema 见 `config.schema.json`。

> **安全提醒**：CLI 配置包含明文 token。任何能够读取该文件的人都可能获得对应 workspace 权限。不要把配置全文或 Authorization header 输出到日志、评论或测试结果中。

## 核心 API（参考源码 `server/internal/handler/`、`server/cmd/server/router.go`）

| 操作 | Method + Path | 说明 |
| --- | --- | --- |
| 校验 token | `GET /api/me` | 返回当前用户信息；401 → token 失效 |
| 拉小队列表 | `GET /api/squads?workspace_id=...` | `[]SquadResponse` |
| 拉 agent 列表 | `GET /api/agents?workspace_id=...` | `[]AgentResponse` |
| 拉成员列表 | `GET /api/workspaces/{id}/members` | `[]MemberWithUserResponse` |
| 拉项目列表 | `GET /api/projects?workspace_id=...` | `[]ProjectResponse` |
| **下单** | `POST /api/issues?workspace_id=...` | `CreateIssueRequest` body，返 `IssueResponse` |
| 列工单 | `GET /api/issues?workspace_id=...` | 支持 `status` / `priority` / `assignee_id` / `creator_id` / `project_id` / `open_only` / `include_closed` 等过滤 |
| 搜索 | `GET /api/issues/search?q=...` | 全文搜索 |
| 取单条 | `GET /api/issues/{id}` | 单条详情 |

请求头（POST 下单）：

| Header | 必填 | 说明 |
| --- | --- | --- |
| `Authorization` | 是 | `Bearer <token>` |
| `Content-Type` | 是 | `application/json` |
| `X-Client-Capabilities` | 否 | 推荐传 `stable_attachment_urls` |
| `X-Client-Platform` | 否 | 标识调用方，比如 `multica-cli-skill` |
| `X-Client-Version` | 否 | 当前 `0.6.0` |
| `X-Client-OS` | 否 | `linux` / `darwin` / `windows` |
| `X-Workspace-ID` | 否 | 与 URL `?workspace_id=` 二选一；都给最稳 |

请求体（`CreateIssueRequest`，见 `server/internal/handler/issue.go`）：

```jsonc
{
  "title":         "必填",
  "description":   "可选，markdown",
  "status":        "backlog|todo|in_progress|in_review|done|blocked|cancelled",  // 缺省 todo
  "priority":      "urgent|high|medium|low|none",                                 // 缺省 none
  "assignee_type": "member | agent | squad",                                       // 可选
  "assignee_id":   "<uuid>",                                                       // 可选
  "parent_issue_id": "<uuid>",                                                     // 可选
  "project_id":    "<uuid>",                                                       // 可选
  "stage":         1,                                                              // 可选，>=1
  "start_date":    "YYYY-MM-DD",                                                   // 可选
  "due_date":      "YYYY-MM-DD",                                                   // 可选
  "attachment_ids": ["<uuid>"],                                                    // 可选
  "label_ids":     ["<uuid>"],                                                     // 可选
  "allow_duplicate": false                                                         // 可选
}
```

成功响应（`IssueResponse`）核心字段：`id` / `workspace_id` / `number` / `identifier`（`MUL-N`）/ `title` / `status` / `priority` / `creator_type` / `creator_id` / `created_at`。

错误响应：`{ "error": "..." }`，常见消息：

| HTTP | 错误消息 | 含义 |
| --- | --- | --- |
| 400 | `title is required` / `invalid status "X"; valid values: ...` / `stage must be >= 1` | 请求体不合法 |
| 401 | `unauthorized` | token 失效 |
| 403 | `you do not have access to this workspace` | 跨 workspace 引用 |
| 422 | `agent_unavailable` / assignee 校验失败 | assignee / project / parent 跨 workspace |

## 自动匹配算法（v0.2 起）

负责人和项目都支持"用名字找人 / 找项目"。匹配打分：

| 分数 | 规则 |
| --- | --- |
| 100 | 完全相同（大小写敏感） |
| 90 | 完全相同（大小写不敏感） |
| 70 | 大小写不敏感子串匹配 |
| 50 | 忽略空格 / `-` / `_` 后再做子串匹配 |
| 0 | 不匹配 |

多候选中取**最高分**；分数相同的取**列表中靠前**的。`--strict-match` 模式下只接受 100 分且仅一个匹配，否则报错。

负责人类型优先级：

- `--squad "..."`：只在 `/api/squads` 里找，匹配到 `assignee_type=squad`
- `--agent "..."`：只在 `/api/agents` 里找，匹配到 `assignee_type=agent`
- `--member "..."`：只在 `/api/workspaces/{id}/members` 里找，匹配到 `assignee_type=member`（`user.email` 也作为名字候选）
- `--assignee "..."`：自动按 **squad → agent → member** 顺序匹配，先命中就用

匹配上的 `assignee_type` + `assignee_id` + `project_id` 会写进 `POST /api/issues` 的请求体。

> `assignee_type=squad` 是被后端接受的（2026-07-30 探查结论）。`/api/issues` POST 同时接受 `assignee_type ∈ {member, agent, squad}`，`/api/issues/{id-or-identifier}` PUT 也支持把 assignee 改回 squad。本 skill 的 `--squad "<name>"` 会走 `/api/squads` fuzzy match，命中的 squad UUID 直接作为 `assignee_id` 提交，不需要绕道 squad leader agent。Web 客户端里能选 squad 作负责人，API 同样能。
>
> 历史误解：v0.8 之前 SKILL.md 曾警告「assignee_type=squad 不是 CreateIssueRequest 直接支持的值」，那是根据源码注释推断、未经实测的错误结论。已经被实测（LRO-52 / LRO-54 创建+回读均成功）推翻。

## 标准调用流程（v0.1.0）

1. **解析凭证**。按上述优先级从 `~/.multica/config.json` 或显式配置拿到 `server_url` / `app_url` / `workspace_id` / `token`。
2. **校验 token**。`GET /api/me`，401 时提示用户更新 `config.json`。
3. **按需拉列表**。只有 `--assignee` / `--squad` / `--agent` / `--member` / `--project` 触发时才拉对应列表。
4. **执行 fuzzy match**。按上面的打分规则挑出 `assignee_id` / `project_id`。
5. **构造请求体**。把解析出来的 `assignee_type`+`assignee_id` 和 `project_id` 填进 `CreateIssueRequest`。
6. **POST 到 `POST {server_url}/api/issues?workspace_id={workspace_id}`**。
7. **拼 web URL**：`{app_url}/{workspace_slug-or-name}/issues/{issue.id}`（v0.8 起）。
   - web 路由段 = 创建响应 `IssueResponse.id` 字段（UUID primary key），**不是** `identifier`（如 `LRO-40`）——后者人读在 UI 里用，但**不**能用在 URL 里。
   - **不能用 `workspace_id`**——web 路由只认 workspace 的 `slug`（优先）或 `name`（回退），用 id 拼出来的 URL 在浏览器里打不开。
   - 脚本三层回退拿 workspace 路径段：
     1. `multica workspace list`（注意：CLI 可能登录在别的 workspace，看不到当前 workspace）
     2. `GET {server_url}/api/workspaces/{workspace_id}`（用本 skill 的 token；不依赖 CLI）
     3. 实在拿不到 → 回退到 `workspace_id` 并在 stderr 打 `WARN:` 警告
8. **输出结果**：默认人话版；`--json` 时输出含 `web_url` / `matched_assignee_type` / `matched_assignee_id` / `matched_project_id` / `config_path` 的 JSON。

## 脚本实现（bash + curl + jq）

五个可执行脚本保存在 `multica-cli-skill/scripts/`，依赖：`curl` + `jq` + `uname`。

### `order.sh` — 下单

```text
order.sh --title TEXT --description TEXT --assignee ... --project ... [选项]

必填（v0.7 起）:
  --title TEXT                    issue 标题
  --description TEXT              issue 正文（markdown）；不想写就传 " " 或简单描述
  --assignee-type member|agent|squad --assignee-id UUID      (显式 UUID)
  或 --assignee  "<name>"        (按名字 fuzzy match squad→agent→member)
  或 --squad     "<name>"        (强制 squad)
  或 --agent     "<name>"        (强制 agent)
  或 --member    "<name>"        (强制 member；user.email 也参与匹配)
  --project-id UUID              (显式 UUID)
  或 --project   "<title>"       (按名字 fuzzy match /api/projects)

内容（可选）:
  --priority urgent|high|medium|low|none
  --status backlog|todo|in_progress|in_review|done|blocked|cancelled
                                  缺省: 不传则服务端默认 todo（"待办"）
  --due-date YYYY-MM-DD
  --label-ids u1,u2,...
  --parent-issue-id UUID
  --allow-duplicate

凭证:
  --config <path>                  显式指定 CLIConfig 文件；缺省查 $MULTICA_CLI_ORDER_CONFIG
                                  再缺省 ~/.multica/config.json
  --server-url URL                 覆盖 config 里的 server_url
  --app-url URL                    覆盖 config 里的 app_url
  --workspace-id UUID              覆盖 config 里的 workspace_id
  $MULTICA_TOKEN                   覆盖 config 里的 token（CI / 沙箱最常用）

输出:
  --json                           完整 JSON（含 matched_* + config_path）
  --dry-run                        打印请求体不下单
  --strict-match                   auto-match 只接受完全相同的名字
```

### `list.sh` — 查询

```text
list.sh list   [过滤选项]
list.sh search --q <关键词> [--limit N] [--include-closed]
list.sh get    <identifier|uuid>       # MUL-123 / 5c1f-...

过滤选项（list 子命令，支持任一组合）:
  --statuses backlog,todo,in_progress,in_review,done,blocked,cancelled
  --priorities urgent,high|medium|low|none
  --assignee-id UUID              |  --assignee "前端组"
  --creator-id UUID               |  --creator "老王"
  --project-id UUID               |  --project "支付重构"
  --open-only                     |  --include-closed
  --include-no-assignee           |  --include-no-project
  --scheduled                     |  --label-ids u1,u2,...
  --sort created_at|updated_at|priority|due_date|number
  --direction asc|desc            |  --limit N | --offset N
  --strict-match                  |  --q "关键词"  (自动改走 /search endpoint)
```

### `update.sh` — 修改字段（v0.8 新增）

调用 `PUT /api/issues/{id-or-identifier}`，**先 GET 当前值 → 算 diff → 列出 pending changes → 默认问 "Apply? [y/N]" → 才发 PUT**。

```text
update.sh <identifier|uuid> [字段选项]

字段（至少给一个，否则报错）:
  --status backlog|todo|in_progress|in_review|done|blocked|cancelled
  --priority urgent|high|medium|low|none
  --assignee-type member|agent|squad --assignee-id UUID       (显式 UUID)
  或 --assignee "<name>"      (按名字 fuzzy match squad→agent→member)
  或 --squad    "<name>"      (强制 squad)
  或 --agent    "<name>"      (强制 agent)
  或 --member   "<name>"      (强制 member；user.email 也参与匹配)
  --project-id UUID
  或 --project "<title>"      (按名字 fuzzy match /api/projects)
  --title TEXT
  --description TEXT
  --json '{"k":"v",...}'       (原始 body，跳过白名单校验)

控制:
  --dry-run          只打 diff + body，不发请求
  --yes / -y         跳过确认（CI / 脚本场景）
  --json-output      以 JSON 形式输出更新后的完整 issue（含 web_url）
  --config / --server-url / --app-url / --workspace-id
```

**白名单校验**：`--status` / `--priority` / `--assignee-type` 都接受合法值集合，非法值立刻报错（不真发请求）。`--json` 是 escape hatch——跳过白名单直接透传 body。

**自动警告**：
- `done` → 任何非 `done`：打印 "WARN: 正在把 done 工单改回 ...，请确认确实是要 reopen"
- `in_review` → `backlog`：打印 "WARN: 正在把 in_review 工单踢回 backlog（基本等于撤销评审）"

**支持的字段（v0.8 探查结论）**：后端 `PUT /api/issues/{id-or-identifier}` 接 JSON body，**支持** `status` / `priority` / `assignee_id` (+ `assignee_type`) / `project_id` / `title` / `description`；**不接受** `stage`（直接被丢弃）；**静默忽略** `identifier` / `number`（不可改，避免和 prefix 冲突）。`PATCH` 返回 405，所以**只走 PUT**。

**示例**：

```bash
# 1. 改单个字段：把状态推进到 done（带确认）
bash scripts/update.sh LRO-37 --status done
# → 列出 diff (in_review → done)，问 Apply? [y/N]，确认后 PUT

# 2. 跳过确认（CI 场景）
bash scripts/update.sh LRO-37 --status done --yes

# 3. dry-run：先看 diff 和 body，不发请求
bash scripts/update.sh LRO-37 --status done --priority high --dry-run

# 4. 改优先级 + 标题 + 项目，一次 PUT
bash scripts/update.sh LRO-37 --priority high --title "新标题" --project "支付重构" --yes

# 5. 转派：按名字 fuzzy match 新负责人（squad→agent→member）
bash scripts/update.sh LRO-37 --assignee "前端组" --yes

# 6. 编程式读结果
RESULT=$(bash scripts/update.sh LRO-37 --status done --yes --json-output)
echo "$RESULT" | jq -r '.identifier, .web_url, .updated_at'

# 7. 兜底：--json 透传任意 body（高级用户）
bash scripts/update.sh LRO-37 --json '{"priority":"high","assignee_id":"94b9618a-...","assignee_type":"squad"}' --yes
```

**输出**：默认人话版（Identifier / Status / Priority / Assignee / Project / Updated / Web URL），`--json-output` 时输出含 `web_url` 的完整 JSON。

### `comment.sh` — 评论（v0.10 新增）

issue 评论的完整 CRUD + resolve / unresolve。所有凭证 / header 逻辑与 `order.sh` / `update.sh` 共享；workspace_id 走 `X-Workspace-ID` header + `?workspace_id=` query 双碰。

```text
comment.sh <subcommand> <target-id> [选项]

subcommand:
  list       <issue-id-or-uuid> [选项] 某 issue 的评论
  add        <issue-id-or-uuid> [选项] 发评论 / 回复
  update     <comment-id>         [选项] 编辑评论（仅作者/管理员）
  delete     <comment-id>         [选项] 删除评论（仅作者/管理员）
  resolve    <comment-id>         [选项] 把评论标记为线程的「解决结论」
  unresolve  <comment-id>         [选项] 撤销「解决结论」（重新打开线程）

公共选项:
  --config / --server-url / --app-url / --workspace-id
  --json        JSON 输出
  --yes / -y    跳过 update/delete 的默认确认
  --dry-run     只打印 body，不发请求

list 额外:
  --threads-only            roots_only=true（只看顶层评论）
  --summary                 summary=true（每条 content 截 200 字，agent 上下文友好）
  --fold                    fold=true（折叠已解决线程到 root + 结论）
  --since RFC3339           只看该时间之后的评论
  --thread <comment-uuid>   看某条线程
  --tail N                  线程尾 N 条回复（要 --thread）
  --recent N                最近 N 个线程
  --limit N                 客户端截到 N 条
  --list-type comment|progress_update   按 type 过滤
  --hide-resolved           隐藏已 resolve 的评论

add 额外:
  --content TEXT            评论正文（必填）
  --content-file <path>     从文件读正文（多行 / 长 markdown）
  --type comment|progress_update      默认 comment
  --parent-id <uuid>        回复某条评论（构成线程）
  --attachment-ids u1,u2,... 关联已上传附件（先用 attachments.sh upload）
  --suppress-agent-ids u1,u2,...  本评论不触发这些 agent
  --note                    在正文前加 "/note "（不触发任何 agent）

update 额外:
  --content TEXT            必填
  --content-file <path>     替代 --content
  --attachment-ids u1,u2,... 替换附件集合（省略 = 保留原集合）
  --suppress-agent-ids u1,u2,...

resolve / unresolve: 无额外选项
```

**典型用法**：

```bash
# 1. 列一个 issue 的所有评论
bash scripts/comment.sh list LRO-55

# 2. 概览：只要顶层评论 + 摘要（agent 上下文友好）
bash scripts/comment.sh list LRO-55 --threads-only --summary --json

# 3. 看一条线程的全部回复
bash scripts/comment.sh list LRO-55 --thread <comment-uuid> --tail 10

# 4. 发一条 comment
bash scripts/comment.sh add LRO-55 --content "看一下"

# 5. 从文件读内容（多行 / 长 markdown）
bash scripts/comment.sh add LRO-55 --content-file ./note.md

# 6. 回复某条评论
bash scripts/comment.sh add LRO-55 --content "我也说一句" --parent-id <comment-uuid>

# 7. 发一条 note（不触发任何 agent）
bash scripts/comment.sh add LRO-55 --content "今天先不并发测试" --note

# 8. 标记某条评论为线程的解决结论
bash scripts/comment.sh resolve <comment-uuid>

# 9. 撤销结论
bash scripts/comment.sh unresolve <comment-uuid>

# 10. 编辑自己的评论（默认会问 Continue? [y/N]，--yes 跳过）
bash scripts/comment.sh update <comment-uuid> --content "改一下" --yes

# 11. 删自己的评论（默认会问，--yes 跳过）
bash scripts/comment.sh delete <comment-uuid> --yes

# 12. 编程式读取
RESULT=$(bash scripts/comment.sh list LRO-55 --json)
echo "$RESULT" | jq 'length'
```

**服务端关键细节（参考 `server/internal/handler/comment.go`）**：

| 主题 | 探查结论 |
| --- | --- |
| **认证 / 权限** | `UpdateComment` / `DeleteComment` / `ResolveComment` / `UnresolveComment` 走 `isAuthor \|\| isAdmin` 路径。**workspace admin 永远可以改 / 删任何评论**——不要用别人的评论测 403，会真删（2026-07-31 事故） |
| **type 白名单** | `clientAuthorableCommentTypes = {"comment", "progress_update"}`。`status_change` / `system` 是平台生成的，客户端伪造会被 400 拒（`isClientAuthorableCommentType` 校验） |
| **空内容** | `req.Content == ""` 直接 400 `content is required`；含 NUL 字节（`0x00`）会被 `sanitizeNullBytes` 清掉再检，所以"全 NUL"也走空内容路径 |
| **HTML 转义** | 后端**不**做 HTML sanitize（Markdown 源格式保留）；XSS 在渲染层（`rehype-sanitize`）和编辑层（`@tiptap/markdown` with `html:false`）处理。脚本里**不要**自己转义 `>` `<` `&` 之类 |
| **resolve / unresolve** | `POST /api/comments/{id}/resolve` 是「标记为线程的解决结论」；同线程已有的 resolved 会被 `ClearOtherThreadResolutions` 原子清掉（一线程一 resolution 约束）。`DELETE /api/comments/{id}/resolve` 把这条评论的 `resolved_at` 抹掉（同线程不会自动清——这个调用就是单点操作） |
| **trigger_outcomes** | create / update 响应里有 `trigger_outcomes[]`：每个 `@agent` / `@squad` mention 的触发结果（queued / coalesced / deferred / blocked + reason_code）。blocked 不会让整个请求失败——评论还是发的，只是 mention 不触发 |
| **`/note` 前缀** | 评论首 token 是 `/note`（大小写不敏感）=「人类备忘」，不会被任何 agent 触发。脚本 `--note` 自动拼前缀 |
| **删除的副作用** | `DELETE /api/comments/{id}` 是**硬删**（`server/pkg/db/queries/comment.sql:445 DeleteComment`），无软删除。服务端会 cancel 触发该评论的 agent task + re-trigger 同一批幸存评论。**没有恢复 API**——误删就是真的没了 |
| **list 模式互斥** | `--fold` 与 `--since` / `--tail` / `--threads-only` 服务端互斥（comment.go 显式 400）；`--tail` 必须配 `--thread`；`--threads-only` 与 `--thread` / `--recent` / `--tail` 互斥 |
| **list 体量上限** | 服务端 `commentHardCap = 2000`（comment.go:275），`recent` / `tail` 都会被 cap 到这个值 |
| **没有 GET /api/comments/{id}** | 只能 `GET /api/issues/{id}/comments` 在列表里 filter。脚本没有实现 `get` 子命令，需要单条详情时直接 `list ... --json \| jq '.[] \| select(.id == "...")'` |

**和现有脚本的关系**：

- `attachments.sh upload ... --comment <uuid>` 现在可以接 `comment.sh add` 之后拿到的 comment_id
- `update.sh` 改 issue 字段（status / priority / assignee / project / title / description）；`comment.sh` 改 issue 内的评论文本（content / attachment_ids / suppress_agent_ids）——**两个脚本不能互相替代**
- 服务端 `EventCommentCreated/Updated/Resolved/...` 实时事件不在本 skill 范围（用 multica CLI 订阅 websocket）

> **安全 / 误删警示**：用 `comment.sh update` / `delete` 改 **别人** 的评论时，服务端只检查 `isAuthor || isAdmin`。管理员 token 能修改或删除他人评论；虽然脚本默认询问 `Continue? [y/N]`，但 `--yes` 会跳过确认。**调试时始终使用自己创建的测试评论。**

### 典型调用

```bash
# 1. 首次使用：先让 Multica CLI 写入用户配置
multica login
cd multica-cli-skill
# 默认读取 ~/.multica/config.json，无需再复制 token

# 2. 最简：title + description + assignee + project（v0.7 必填项）
bash scripts/order.sh \
  --title "线上告警: 支付成功率掉到 80%" \
  --description "支付服务近 1h 成功率从 99% 跌到 80%，请尽快排查" \
  --assignee "老王" \
  --project "支付重构"

# 3. 按名字匹配小队
bash scripts/order.sh \
  --title "前端登录页跳转异常" \
  --description "用户登录后白屏，无法跳转到 dashboard" \
  --squad "前端组" \
  --project "支付重构" \
  --priority high

# 4. 按名字匹配成员 + 项目
bash scripts/order.sh \
  --title "重构支付回调逻辑" \
  --description "当前回调幂等校验有 bug，需重构成 idempotency-key 模式" \
  --member "老王" \
  --project "支付重构" \
  --priority urgent --due-date 2026-08-05

# 5. CI 场景：token 走 env，url 走 config
export MULTICA_TOKEN=mul_xxx
bash scripts/order.sh --title "..." --description "..." --assignee "前端组" --project "..."

# 6. 自定义 config 路径
bash scripts/order.sh --title "..." --description "..." --assignee "前端组" \
  --project "..." --config /etc/multica-cli-skill/prod.json

# 7. dry run：先看请求体再下单
bash scripts/order.sh --title "..." --description "..." \
  --squad "前端组" --project "..." --dry-run

# 8. 严格匹配：只接受完全相同的名字
bash scripts/order.sh --title "..." --description "..." \
  --assignee "前端组" --project "..." --strict-match

# 9. 编程式读取结果
RESULT=$(bash scripts/order.sh \
  --title "..." --description "..." \
  --assignee "前端组" --project "支付重构" \
  --json)
echo "$RESULT" | jq -r '.identifier, .web_url'
echo "$RESULT" | jq -r '.matched_assignee_type, .matched_assignee_id, .matched_project_id'

# 10. 命令行部分覆盖（用本地 config，但临时换 workspace）
bash scripts/order.sh \
  --config ./config.json \
  --workspace-id <another-uuid> \
  --title "..." --description "..." \
  --assignee "前端组" --project "..."

# 11. 回查工单（list.sh，凭证同样走 config.json）
bash scripts/list.sh list --open-only
bash scripts/list.sh list --assignee "前端组" --open-only
bash scripts/list.sh search --q "支付成功率" --limit 10
bash scripts/list.sh get MUL-123

# 12. 改工单状态（update.sh，默认问确认，--yes 跳过）
bash scripts/update.sh MUL-123 --status done
bash scripts/update.sh MUL-123 --priority high --assignee "前端组" --yes
bash scripts/update.sh MUL-123 --status done --dry-run     # 先看 diff
bash scripts/update.sh MUL-123 --json '{"status":"done"}' --yes  # 透传 body
```

> **必填校验**：传少了 `order.sh` 会立即报错（exit 1）并提示缺哪项。例如忘了 `--description` 会得到 `ERROR: --description is required (issue 正文); 不想写就传 " " 或简单描述`；忘了负责人会得到 `ERROR: assignee is required. Pass one of: ...`；忘了项目会得到 `ERROR: project is required. Pass one of: ...`。

## 错误处理速查

| HTTP | 含义 | 怎么办 |
| --- | --- | --- |
| 200/201 | 创建成功 | 解析 `identifier` + `web_url` |
| 400 | 请求体不合法 | 看 `error`：`title is required` / `invalid status "X"` / `stage must be >= 1` |
| 401 | token 失效 | 重新运行 `multica login`，或更新显式 `--config` 文件 / `$MULTICA_TOKEN` |
| 403 | 没有当前 workspace 权限 | 用 `multica auth status` 确认当前 CLI 登录和 workspace |
| 404 | workspace_id 不存在 / 域名错 | 检查 `config.json` 里的 `server_url` / `workspace_id` |
| 409 | 标题重复 | 加 `--allow-duplicate` |
| 422 | 跨 workspace 引用 | 把所有 UUID 限定到同一 workspace |
| 5xx | 服务端问题 | 退避重试 1~2 次 |

凭证相关：

| 场景 | 行为 |
| --- | --- |
| 默认 `~/.multica/config.json` 不存在 | 报错并提示先运行 `multica login`，或传 `--config` / `$MULTICA_CLI_ORDER_CONFIG` |
| 缺 `token` | 报错 `missing token. Set MULTICA_TOKEN env, or write token into <config.json>, or pass --config` |
| 缺 `server_url` | 报错 `missing server_url. Set server_url in <config.json> or pass --server-url` |
| `--member` 但 config.json 里没 `workspace_id` 且命令行也没传 | 报错 `--workspace-id (or workspace_id in config) is required to auto-match members` |
| auto-match 在 squad/agent/member/project 里都没匹配上 | 报错 `no squad/agent/member matched "<input>" in workspace <uuid>` |
| `--strict-match` 下有多个同名的 | 报错 `ambiguous strict match: N entries named "<input>"` |
| **v0.7** 缺 `--title` | 报错 `--title is required` |
| **v0.7** 缺 `--description` | 报错 `--description is required (issue 正文); 不想写就传 " " 或简单描述` |
| **v0.7** 缺负责人（4 选 1 都没给） | 报错 `assignee is required. Pass one of: ...` |
| **v0.7** 缺项目（2 选 1 都没给） | 报错 `project is required. Pass one of: ...` |
| 缺 `--status` | 不报错；服务端默认 `todo`（"待办"），见 `server/internal/handler/issue.go:2430-2433` |

## 与已有 CLI 命令的关系

- `multica issue create` 与本 skill 都调用 `POST /api/issues`，并默认读取同一个 `~/.multica/config.json`。本 skill 额外提供 fuzzy assignee/project 匹配、查询、更新、评论和附件脚本。
- 想看小队列表 / 项目列表：分别对应 `multica squad list`、`multica project list`（同样走 CLI 的凭证）。脚本里如果检测到 `multica` 二进制在场，会先用它反查 workspace slug 来拼 web URL；如果 CLI 看不到当前 workspace（登录到别的 profile 了），会自动 fallback 到 `GET /api/workspaces/{id}`。
- 更丰富的操作（label 管理、attachment 上传）：参考 `multica issue --help`，本 skill 不重复造轮子。

## 安全注意事项

1. **不要把 token 写到日志**。脚本只读取 CLI 配置；每次运行会用 `umask 077` 创建 `/tmp/multica-cli-skill.XXXXXX/` 私有目录，并通过退出 trap 清理响应和临时 Authorization header。
2. **CLI 配置只读**：脚本不会改写 `~/.multica/config.json`。自定义 `config.json` 仍已由 `.gitignore` 排除。
3. **凭证字段做最小化**：CLIConfig 只需 `server_url` / `app_url` / `workspace_id` / `token` 四个字段，不要加入其他 secret。
4. **多 workspace 隔离**：需要其他登录配置时使用 `--config` 或 `$MULTICA_CLI_ORDER_CONFIG`，不要覆盖默认文件。
5. **网络层**：默认 HTTPS；只有当 `server_url` 是 `http://` 且确实是自托管时才发明文。
6. **重放风险**：`POST /api/issues` 没有 idempotency key，重复执行会产生重复 issue。外部调用方在标题里嵌入唯一标识做去重。
7. **token 选型**：优先永久 PAT（创建时不传 `expires_in_days`），彻底回避"server 不主动 rotate" 的限制。

## 已知不支持 / 后续扩展

- ❌ 暂不支持 `attachment_ids` 上传流程（需要先调上传接口）。
- ~~❌ 暂不支持 `squad` 作为 `assignee_type`（后端只接受 `member` / `agent`）。~~ **已废除**：2026-07-30 探查后确认 `assignee_type=squad` 被后端接受，`--squad` 命令正常工作。
- ❌ 没有 idempotency key，重试由调用方负责去重。
- ❌ `update.sh` 不支持改 `stage`（后端 PUT 不接受；后端设计上应该是单独接口）。
- ❌ `update.sh` 不能改 `identifier` / `number`（后端静默忽略；应该是有意锁住的，避免和 prefix 冲突）。
- ✅ 后续可以加：`--attachment <path>` 一站式上传、`--assignee-prefer <type>`、`-i <inbox-file>` 批量、PowerShell 版本、**token 即将过期检测**（如果用临时 PAT，提前 N 天告警）。
- ✅ v0.10 已加：`comment.sh` 完整评论 CRUD（list / add / update / delete / resolve / unresolve）。后续可加：`comment.sh get <comment-id>` 现在只能 `list ... \| jq`，可加客户端单条查询；`comment.sh add --from-file multi-line.md` 现在是 `--content-file` 单一文件，可加 stdin；`comment.sh update --lock-target` 锁定只能在当前评论加 reply 防误删；`comment.sh add --require-author-only` 全局避错保险。