# multica-cli-skill — 源码溯源对照表

本文档把 `SKILL.md` 里的后端行为追溯到 `https://github.com/multica-ai/multica.git` 的具体源码位置。如果后端行为与本文档不一致，以源码为准并同步更新 skill。

## 凭证 / 登录（v0.1.0）

| 结论 | 源码 / 配置位置 | 关键字段 |
| --- | --- | --- |
| 登录后落盘 `server_url`、`app_url`、`workspace_id`、`token` | `server/internal/cli/config.go` | `type CLIConfig struct` |
| 默认 CLI 凭证文件路径 `~/.multica/config.json` | `server/internal/cli/config.go` | `defaultCLIConfigPath = ".multica/config.json"` |
| Profile 隔离路径 `~/.multica/profiles/<name>/config.json` | `server/internal/cli/config.go` | `CLIConfigPathForProfile`；本 skill v0.1.0 不自动选择 profile，可用 `--config` 指定 |
| `multica-cli-skill` 默认只读 CLI 凭证（v0.11 4 级） | `multica-cli-skill/scripts/*.sh` | `--config` > `<skill_dir>/config.json` > `$MULTICA_CLI_ORDER_CONFIG` > `~/.multica/config.json` |
| 浏览器登录后通过 `POST /api/tokens` 换发 PAT | `server/cmd/multica/cmd_auth.go` | `runAuthLoginBrowser` 中 `client.PostJSON(ctx, "/api/tokens", ...)` |
| PAT 前缀合法值 `mul_` / `mcn_` | `server/cmd/multica/cmd_auth.go` | `loginTokenPrefixes` |
| Token 直接登录（`multica login --token <pat>`） | `server/cmd/multica/cmd_auth.go` | `runAuthLoginToken`；`validateLoginTokenPrefix` |

## Skill 凭证解析

配置字段与 `CLIConfig` 对齐：

| 字段 | 必填 | 含义 |
| --- | --- | --- |
| `server_url` | 是 | API 根地址（无尾斜杠） |
| `app_url` | 否 | 浏览器 Web 地址，缺省回退 `server_url` |
| `workspace_id` | 否 | UUID；auto-match 成员 / 拉 `/api/projects` 时必填 |
| `token` | 是 | PAT（`mul_` / `mcn_` 前缀） |

解析顺序：

1. 选择文件：`--config <path>` > `$MULTICA_CLI_ORDER_CONFIG` > `~/.multica/config.json`
2. `$MULTICA_TOKEN` 覆盖所选文件中的 token
3. `--server-url` / `--app-url` / `--workspace-id` 覆盖对应字段

脚本不会写回 CLI 配置。JSON Schema 见 `config.schema.json`；模板仅用于显式 `--config` 场景。

## 公共 HTTP / Header

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| API 客户端统一 Header | `server/internal/cli/client.go` | `setHeaders`：Bearer、X-Client-Capabilities、X-Client-Platform、X-Client-Version、X-Client-OS、可选 X-Agent-ID / X-Task-ID / X-Workspace-ID |
| `clientCapabilities` 常量值 `stable_attachment_urls` | `server/internal/cli/client.go` | `const clientCapabilities = "stable_attachment_urls"` |
| Auth 中间件优先 `Authorization: Bearer` | `server/internal/middleware/auth.go` | `r.Header.Get("Authorization")` 分支（第 241 行起） |

## Issue（下单 + 查询）

### 下单（order.sh）

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `POST /api/issues?workspace_id=...` 路由 | `server/cmd/server/router.go` | `/api/issues` 路由块（`r.Post("/", h.CreateIssue)`） |
| `CreateIssueRequest` schema | `server/internal/handler/issue.go` | `type CreateIssueRequest struct`（第 2373 行起） |
| `IssueResponse` schema | `server/internal/handler/issue.go` | `type IssueResponse struct`（第 32 行起） |
| 合法 `status` 集合 | `server/internal/handler/issue.go` | `var validIssueStatuses = []string{"backlog", "todo", "in_progress", "in_review", "done", "blocked", "cancelled"}` |
| 合法 `priority` 集合 | `server/internal/handler/issue.go` | `var validIssuePriorities = []string{"urgent", "high", "medium", "low", "none"}` |
| 缺省 `status="todo"` / `priority="none"` | `server/internal/handler/issue.go` | `CreateIssue` 函数内 |
| `validateIssueEnum` 错误格式 | `server/internal/handler/issue.go` | `fmt.Sprintf("invalid %s %q; valid values: %s", ...)` |
| `title is required` 错误 | `server/internal/handler/issue.go` | `CreateIssue` 函数内 `writeError(w, http.StatusBadRequest, "title is required")` |
| `stage must be >= 1` 错误 | `server/internal/handler/issue.go` | `CreateIssue` 函数内 `if req.Stage != nil && *req.Stage < 1` |
| `origin_type` / `origin_id` 仅接受 `quick_create`（白名单） | `server/internal/handler/issue.go` | `CreateIssue` 内 `switch *req.OriginType` |
| `assignee_type` 取值 `member` / `agent`（不含 `squad`） | `server/internal/handler/issue.go` | `validateAssigneePair` |
| `attachment_ids` 支持（v0.13 起 skill 用） | `server/internal/handler/issue.go` | `CreateIssueRequest.AttachmentIds` 字段；服务端接受 `[uuid]` 并绑定到新建的 issue |
| Issue 自增 `number` 与 `identifier = prefix-number` | `server/internal/handler/issue.go` | `issueToResponse` 中 `identifier := issuePrefix + "-" + strconv.Itoa(int(i.Number))` |
| 跨 workspace 引用被 `IssueService.Create` 拒 | `server/internal/handler/issue.go` | `CreateIssue` 函数内注释 + `IssueService.Create` 内部跨 workspace 校验 |
| `POST /api/issues` 内部行为：仅登录用户可创建 | `server/internal/handler/issue.go` | `creatorID, ok := requireUserID(w, r)` |

### 查询 / 搜索 / 取详情（v0.4 list.sh）

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `GET /api/issues?workspace_id=...` 路由 | `server/cmd/server/router.go` | `r.Get("/", h.ListIssues)`（路由表 `/api/issues` 块） |
| `ListIssues` handler | `server/internal/handler/issue.go` | `func (h *Handler) ListIssues`（第 778 行起） |
| `ListIssues` query 参数：`workspace_id` | `server/internal/handler/issue.go` | `h.resolveWorkspaceID(r)` |
| `priority` / `priorities`（多值） | `server/internal/handler/issue.go` | `prioritiesFilter := splitCommaParam(r.URL.Query().Get("priorities"))` |
| `status` / `statuses`（多值） | `server/internal/handler/issue.go` | `statusesFilter := splitCommaParam(r.URL.Query().Get("statuses"))` |
| `assignee_id`（单值）/ `assignee_ids`（多值） | `server/internal/handler/issue.go` | `assigneeFilter` / `assigneeIdsFilter` 段 |
| `assignee_types` / `assignee_filters` 多态筛选 | `server/internal/handler/issue.go` | `assigneeTypesFilter` / `parseActorFilterList` |
| `creator_id` / `creator_filters` | `server/internal/handler/issue.go` | `creatorFilter` / `parseActorFilterList` |
| `project_id` / `project_ids` | `server/internal/handler/issue.go` | `projectFilter` / `projectIDs := parseUUIDParamList(...)` |
| `involves_user_id`（间接 assignee） | `server/internal/handler/issue.go` | `involvesUserFilter` |
| `metadata` / `properties`（jsonb 过滤） | `server/internal/handler/issue.go` | `parseMetadataFilterParam` / `parsePropertiesFilterParam` |
| `open_only=true` 走 `ListOpenIssues`（无 limit） | `server/internal/handler/issue.go` | `if r.URL.Query().Get("open_only") == "true"` |
| `include_closed` / `include_no_assignee` / `include_no_project` | `server/internal/handler/issue.go` | `includeClosed` / `includeNoAssignee` / `includeNoProject` 字段 |
| `scheduled=true` | `server/internal/handler/issue.go` | `if r.URL.Query().Get("scheduled") == "true"` |
| `sort` / `direction` 排序 | `server/internal/handler/issue.go` | `s := r.URL.Query().Get("sort")` + 允许值 |
| `limit` / `offset` 翻页 | `server/internal/handler/issue.go` | `if l := r.URL.Query().Get("limit")` |
| `GET /api/issues/search?q=...` 路由 | `server/cmd/server/router.go` | `r.Get("/search", h.SearchIssues)` |
| `SearchIssues` handler | `server/internal/handler/issue.go` | `func (h *Handler) SearchIssues`（第 625 行起） |
| `SearchIssues` query：`q` / `limit` / `offset` / `include_closed` | `server/internal/handler/issue.go` | 第 629 / 637 / 645 / 651 行 |
| `GET /api/issues/{id}` 路由 | `server/cmd/server/router.go` | `r.Get("/", h.GetIssue)`（`/{id}` 子路由） |
| `GetIssue` handler | `server/internal/handler/issue.go` | `func (h *Handler) GetIssue`（第 1864 行起） |
| `issueListRowToResponse`（无 description 的精简版） | `server/internal/handler/issue.go` | `func issueListRowToResponse(...)`（第 120 行起） |
| `openIssueRowToResponse`（open_only 路径返回） | `server/internal/handler/issue.go` | `func openIssueRowToResponse(...)`（第 181 行起） |

## Squad（小队）

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `GET /api/squads` 路由 | `server/cmd/server/router.go` | `/api/squads` 子路由 |
| `ListSquads` handler | `server/internal/handler/squad.go` | `func (h *Handler) ListSquads`（第 189 行起） |
| `SquadResponse` schema | `server/internal/handler/squad.go` | `type SquadResponse struct`（第 22 行起）：`id` / `workspace_id` / `name` / `description` / `instructions` / `avatar_url` / `leader_id` / `creator_id` / `created_at` / `updated_at` / `archived_at` / `archived_by` / `member_count` / `member_preview` |
| `SquadMemberPreviewResponse` schema | `server/internal/handler/squad.go` | `type SquadMemberPreviewResponse struct`：`member_type` / `member_id` / `role` |
| `squadToResponse` 字段填充 | `server/internal/handler/squad.go` | `func (h *Handler) squadToResponse(s db.Squad) SquadResponse`（第 61 行起） |

## Agent

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `GET /api/agents` 路由 | `server/cmd/server/router.go` | `/api/agents` 子路由 |
| `ListAgents` handler | `server/internal/handler/agent.go` | `func (h *Handler) ListAgents` |
| `AgentResponse` schema | `server/internal/handler/agent.go` | `type AgentResponse struct`（第 37 行起）：`id` / `name` / `description` 等 |

## Member（workspace 成员）

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `GET /api/workspaces/{id}/members` 路由 | `server/cmd/server/router.go` | `/api/workspaces/{id}` 下的 `/members` |
| `ListMembersWithUser` handler | `server/internal/handler/workspace.go` | `func (h *Handler) ListMembersWithUser`（第 413 行起） |
| `MemberWithUserResponse` schema | `server/internal/handler/workspace.go` | `type MemberWithUserResponse struct`（第 402 行起）：`id` / `user_id` / `role` / `user.name` / `user.email` |
| `memberToResponse` 字段填充 | `server/internal/handler/workspace.go` | `func memberToResponse(m db.Member) MemberResponse`（第 89 行起） |

## Project

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `GET /api/projects` / `GET /api/projects/search` 路由 | `server/cmd/server/router.go` | `/api/projects` 子路由 |
| `ListProjects` handler | `server/internal/handler/project.go` | `func (h *Handler) ListProjects`（第 117 行起） |
| `ProjectResponse` schema | `server/internal/handler/project.go` | `type ProjectResponse struct`（第 23 行起）：`id` / `workspace_id` / `title` / `description` / `icon` / `status` / `priority` / `lead_type` / `lead_id` / `start_date` / `due_date` / `issue_count` / `done_count` / `resource_count` |
| `projectToResponse` 字段填充 | `server/internal/handler/project.go` | `func projectToResponse(p db.Project) ProjectResponse`（第 48 行起） |

## Skill 自身的 auto-match 算法（v0.2 新增）

文档在 `scripts/order.sh` 内实现，公式约定：

```text
score(input, hay) = max(
  100 if hay == input else 0,
  90  if ascii_lower(hay) == ascii_lower(input) else 0,
  70  if ascii_lower(hay) CONTAINS ascii_lower(input) else 0,
  50  if gsub("[-_ ]", "", ascii_lower(hay)) CONTAINS gsub("[-_ ]", "", ascii_lower(input)) else 0
)
最终取列表中分数最高者；同分取索引小者
```

匹配负责人类型优先级：

1. 显式传 `--squad` → 强制 squad。
2. 显式传 `--agent` → 强制 agent。
3. 显式传 `--member` → 强制 member（额外支持按 `user.email` 匹配，分数 85）。
4. 传 `--assignee "<name>"` → 默认顺序 squad → agent → member，先命中就用。

## 复现 CLI 子命令对应的实现

- `multica issue create` 的入口：`server/cmd/multica/cmd_issue.go` 中 `runIssueCreate`（或同文件下类似命名）。
- 它做的事和本 skill 完全一致：构造 `CreateIssueRequest` → 调 `client.PostJSON(ctx, "/api/issues", body, &out)` → 打印 `identifier` 与 `id`。
- 本 skill 等价于"用 curl + jq 跑一遍 runIssueCreate 的请求体 + 响应解析"。

## 复现 `multica auth status` 的脱敏输出

为了让用户确认 token 是否还有效，可以复用下面的片段（不是本 skill 必需）：

```bash
ME=$(curl -sS -H "Authorization: Bearer $TOKEN" "$SERVER_URL/api/me")
NAME=$(echo "$ME" | jq -r '.name')
EMAIL=$(echo "$ME" | jq -r '.email')
PREFIX="${TOKEN:0:12}..."
printf "Server:  %s\nUser:    %s (%s)\nToken:   %s\n" "$SERVER_URL" "$NAME" "$EMAIL" "$PREFIX"
```

源码：`server/cmd/multica/cmd_auth.go` 中 `runAuthStatus`。

## 不在本文档范围内、但调用方应该知道的事

1. **WebSocket 实时事件**：下单成功后，订阅了 `workspace` scope 的 WebSocket 客户端会收到 `issue:created` 事件；详情见 `server/internal/realtime/...`，与本 skill 无关。
2. **idempotency**：`POST /api/issues` 没有 idempotency key，重试由调用方负责去重。
3. **附件上传（v0.13 已支持）**：`order.sh` 现在支持 `--attachment <path>`（multipart 上传到 `/api/upload-file`，不绑 issue_id）和 `--attachment-ids <uuid-csv>`（复用已上传的附件）。两者可同时使用；前端无需再手动 `attachments.sh upload + order.sh` 两步。`POST /api/upload-file` 的 `issue_id` 是可选的；服务端会先把附件落库，再通过 `POST /api/issues` body 里的 `attachment_ids` 绑定。`CreateIssueRequest` 接受 `attachment_ids: [uuid]`。
4. **Web URL 中的 slug**：浏览器 URL 默认走 `<app_url>/<workspace_slug>/issues/<identifier>`；slug 在创建 workspace 时确定，可以 `multica workspace list` 反查。脚本已经做了 best-effort 反查，反查失败回退到用 `workspace_id` 拼路径。
5. **`assignee_type=squad` 已被验证支持**：2026-07-30 实测 LRO-52 / LRO-54 创建 + 回读均成功，`POST /api/issues` 的 `CreateIssueRequest` 接受 `assignee_type ∈ {member, agent, squad}`。`PUT /api/issues/{id}` 也支持把 assignee 改回 squad。脚本 `--squad "<name>"` 走 `/api/squads` fuzzy match，命中 UUID 直接提交。**历史误解已废除**（v0.8 之前曾警告「服务 不支持 squad」）。

## Comment（v0.10 新增 `comment.sh`）

| 结论 | 源码位置 | 关键行 / 关键字段 |
| --- | --- | --- |
| `POST /api/issues/{id}/comments` 路由 | `server/cmd/server/router.go` | `/api/issues/{id}/comments` 下的 POST |
| `GET /api/issues/{id}/comments` 路由 | `server/cmd/server/router.go` | `/api/issues/{id}/comments` 下的 GET |
| **`PUT /api/comments/{id}`** 路由 | `server/cmd/server/router.go` | `/api/comments/{commentId}` 下的 PUT |
| **`DELETE /api/comments/{id}`** 路由 | `server/cmd/server/router.go` | `/api/comments/{commentId}` 下的 DELETE |
| **`POST /api/comments/{id}/resolve`** 路由 | `server/cmd/server/router.go` | `/api/comments/{commentId}/resolve` 下的 POST |
| **`DELETE /api/comments/{id}/resolve`** 路由 | `server/cmd/server/router.go` | `/api/comments/{commentId}/resolve` 下的 DELETE |
| `CreateComment` handler | `server/internal/handler/comment.go` | `func (h *Handler) CreateComment`（第 1252 行起） |
| `ListComments` handler | `server/internal/handler/comment.go` | `func (h *Handler) ListComments`（第 357 行起） |
| `UpdateComment` handler | `server/internal/handler/comment.go` | `func (h *Handler) UpdateComment`（第 2657 行起） |
| `DeleteComment` handler | `server/internal/handler/comment.go` | `func (h *Handler) DeleteComment`（第 2844 行起） |
| `ResolveComment` handler | `server/internal/handler/comment.go` | `func (h *Handler) ResolveComment`（第 3053 行起） |
| `UnresolveComment` handler | `server/internal/handler/comment.go` | `func (h *Handler) UnresolveComment`（第 3134 行起） |
| `CreateCommentRequest` schema | `server/internal/handler/comment.go` | `type CreateCommentRequest struct`（第 1000 行起）：`content` / `type` / `parent_id` / `attachment_ids` / `suppress_agent_ids` |
| `CommentResponse` schema | `server/internal/handler/comment.go` | `type CommentResponse struct`（第 25 行起）：`id` / `issue_id` / `author_type` / `author_id` / `content` / `type` / `parent_id` / `created_at` / `updated_at` / `resolved_at` / `resolved_by_type` / `resolved_by_id` / `source_task_id` / `quick_action_id` / `reactions` / `attachments` / `reply_count` / `last_activity_at` / `content_truncated` / `thread_resolved` / `folded_count` / `trigger_outcomes` |
| **client-authorable type 白名单** | `server/internal/handler/comment.go` | `var clientAuthorableCommentTypes = map[string]struct{}{ "comment": {}, "progress_update": {} }`（第 1461 行起）；`isClientAuthorableCommentType`（第 1466 行） |
| **`/note` 前缀 = 不触发 agent** | `server/internal/handler/comment.go` | `const noteCommentPrefix = "/note"`；`isNoteComment`（第 1471 行起），首 token 大小写不敏感匹配 |
| **NUL 字节清理** | `server/internal/handler/comment.go` | `req.Content = sanitizeNullBytes(req.Content)`（CreateComment 第 1280 行 / UpdateComment 第 2728 行） |
| **auth 作用域** | `server/internal/handler/comment.go` | `UpdateComment` / `DeleteComment` 内部 `isAuthor || isAdmin`（第 2676 / 第 2878 行）——**admin token 永远可以改刪任何评论**。`GetCommentInWorkspace` 加 workspace_id 限定（第 2667 / 2868 行） |
| **workspace_id 解析** | `server/internal/middleware/workspace.go` | `func ResolveWorkspaceIDFromRequest`（第 68 行起），优先 task_token > context > X-Workspace-Slug > ?workspace_slug > ?workspace_id。脚本走 `X-Workspace-ID` header + `?workspace_id=` 双碰 |
| **response 跳考**：标记 resolve 时同线程其他 resolved 评论被原子清掉 | `server/internal/handler/comment.go` | `ClearOtherThreadResolutions`（ResolveComment handler 内，第 3069 行）+ `ResolveComment` SQL `COALESCE`（`server/pkg/db/queries/comment.sql:455`） |
| **list 参数** | `server/internal/handler/comment.go` | `since` / `thread` / `recent` / `tail` / `before` / `before_id` / `roots_only` / `summary` / `fold`（ListComments handler 参数解析部分） |
| **list 参数互斥** | `server/internal/handler/comment.go` | `fold` ⊥ `since` / `tail` / `roots_only`；`roots_only` ⊥ `thread` / `recent` / `tail` / `before`；`tail` 需配 `thread`；`before` 需配 `recnet` 或 `thread+tail`（全部以 400 拒） |
| **`commentHardCap = 2000`** | `server/internal/handler/comment.go` | `const commentHardCap = 2000`（第 275 行），`recent`/`tail` 超出被 cap |
| **`summary` 截断** | `server/internal/handler/comment.go` | `summaryContentRunes = 200`；`summarizeContent`（第 100 行起），rune 计数 + 省略号 |
| **`fold` 折叠逻辑** | `server/internal/handler/comment.go` | `foldResolvedThreads`（第 200 行起），reply-resolved 保留 root + 结论，root-resolved 只保留 root |
| **DeleteComment SQL（硬删）** | `server/pkg/db/queries/comment.sql` | `DELETE FROM comment WHERE id = $1 AND workspace_id = $2`（第 445 行）。**无软删除** |
| **DeleteComment 副作用** | `server/internal/handler/comment.go` | `CancelTasksByTriggerComment`（第 2886 行）+ `retriggerCancelledTaskSurvivors`（第 2964 行起）：取消触发该评论的 agent task + 重试同批幸存评论 |
| **EventCommentCreated/Updated/...** | `server/internal/handler/comment.go` | `h.publish(protocol.EventCommentCreated, ...)`（CreateComment 第 1435 行），websocket 订阅侧超本 skill 范围 |
| **CommentTriggerOutcome** | `server/internal/handler/comment.go` | `type CommentTriggerOutcome struct`（第 79 行）：`target_type` / `target_id` / `status` / `reason_code`——每个 @agent / @squad mention 的触发结果。blocked 不会让请求失败 |

**注释**：multica 平时还有路 `GET /api/issues/{id}/timeline`（`activity.go`），返回 comments + activities 合并的全量时间线。本 skill 不实现 timeline 接口（调用方一般拿 `list --summary` 就够）；需要提及 timeline 原始 events 时，直接调 `GET /api/issues/{id}/timeline` 即可，与 `comment.sh` 互补。
