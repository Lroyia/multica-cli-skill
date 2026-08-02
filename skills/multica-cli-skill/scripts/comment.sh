#!/usr/bin/env bash
# multica-cli-skill / comment.sh — 管 issue 评论（v0.10 新增）
#
# 子命令（互斥）:
#   list       <issue-id-or-uuid> [选项]   列出某 issue 的评论
#   add        <issue-id-or-uuid> [选项]   在某 issue 上发评论（或回复）
#   update     <comment-id>         [选项]  编辑评论（仅作者/管理员）
#   delete     <comment-id>         [选项]  删除评论（仅作者/管理员）
#   resolve    <comment-id>         [选项]  把评论标记为「线程的解决结论」
#   unresolve  <comment-id>         [选项]  撤销「解决结论」（重新打开线程）
#
# 设计依据:
#   - server/internal/handler/comment.go
#   - server/cmd/server/router.go:
#       POST   /api/issues/{id}/comments
#       GET    /api/issues/{id}/comments
#       PUT    /api/comments/{commentId}
#       DELETE /api/comments/{commentId}
#       POST   /api/comments/{commentId}/resolve
#       DELETE /api/comments/{commentId}/resolve
#   - 评论 type 仅允许 client_authorable: "comment" / "progress_update"
#     （"status_change" 和 "system" 是平台生成的，禁止客户端伪造）
#   - /note 前缀：评论首 token 是 /note（大小写不敏感）则不会被 agent 触发
#
# 凭证来源（与 order.sh / list.sh / update.sh 完全一致）:
#   --config > <skill_dir>/config.json > $MULTICA_CLI_ORDER_CONFIG > ~/.multica/config.json
#   $MULTICA_TOKEN 覆盖 token；--server-url / --app-url / --workspace-id 覆盖对应字段
#
# 前置依赖: curl, jq, uname

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

# ---- 帮助 ----
# usage 块的范围标记 BEGIN_USAGE / END_USAGE，由 usage() 提取
# BEGIN_USAGE
# multica-cli-skill / comment.sh — 管 issue 评论（v0.10 新增）
#
# 子命令（互斥）:
#   list       <issue-id-or-uuid> [选项]   列出某 issue 的评论
#   add        <issue-id-or-uuid> [选项]   在某 issue 上发评论（或回复）
#   update     <comment-id>         [选项]  编辑评论（仅作者/管理员）
#   delete     <comment-id>         [选项]  删除评论（仅作者/管理员）
#   resolve    <comment-id>         [选项]  把评论标记为线程的解决结论
#   unresolve  <comment-id>         [选项]  撤销解决结论（重新打开线程）
#
# 公共选项:
#   --config <path>           覆盖 config.json 路径
#   --server-url URL          覆盖 server_url
#   --app-url URL             覆盖 app_url
#   --workspace-id UUID       覆盖 workspace_id
#   --json                    以 JSON 形式输出
#   --yes / -y                跳过确认（update / delete 默认要确认）
#   --dry-run                 只打印请求体，不真发请求
#
# list 额外选项:
#   --threads-only            只看顶层评论（roots_only=true）
#   --summary                 每条 content 截到 200 字（agent 上下文友好）
#   --fold                    折叠已解决线程到 root + 结论
#   --since RFC3339           只看该时间之后的评论
#   --thread <uuid>           看某条线程
#   --tail N                  线程尾 N 条回复（要 --thread）
#   --recent N                最近 N 个线程
#   --limit N                 客户端截到 N 条
#   --list-type comment|progress_update   按 type 过滤
#   --hide-resolved           隐藏已 resolve 的评论
#
# add 额外选项:
#   --content TEXT            评论正文（必填）；可与 --content-file 拼接
#   --content-file <path>     从文件读正文（适合多行 / 长 markdown）
#   --type comment|progress_update      默认 comment
#   --parent-id <uuid>        回复某条评论（构成线程）
#   --attachment-ids u1,u2,... 关联已上传附件（先用 attachments.sh upload）
#   --suppress-agent-ids u1,u2,...  本评论不触发这些 agent
#   --note                    在正文前加 "/note "（不触发任何 agent）
#
# update 额外选项:
#   --content TEXT            必填
#   --content-file <path>     替代 --content
#   --attachment-ids u1,u2,... 替换附件集合（省略 = 保留原集合）
#   --suppress-agent-ids u1,u2,...
#
# 示例:
#   comment.sh list LRO-45
#   comment.sh list LRO-45 --threads-only --summary
#   comment.sh add  LRO-45 --content "看一下"
#   comment.sh add  LRO-45 --content-file ./note.md --note
#   comment.sh add  LRO-45 --content "我也说一句" --parent-id <comment-uuid>
#   comment.sh update <comment-uuid> --content "改一下" --yes
#   comment.sh delete <comment-uuid> --yes
#   comment.sh resolve <comment-uuid>
#   comment.sh unresolve <comment-uuid>
# END_USAGE
usage() {
  sed -n '/^# BEGIN_USAGE$/,/^# END_USAGE$/p' "$0" \
    | sed '1d;$d' \
    | sed 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "$*" >&2; }

umask 077
TMP_DIR="$(mktemp -d /tmp/multica-cli-skill.XXXXXX)" || die "failed to create private temp directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

command -v jq >/dev/null 2>&1 || die "jq is required. Install jq first."

# 解析脚本所在的 skill 目录
SKILL_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
SKILL_DIR_CONFIG="$SKILL_DIR/config.json"

# ---- 配置路径解析 ----
CONFIG_PATH_IS_DEFAULT="false"
resolve_config_path() {
  # 1) --config 显式指定（最高优先级）
  [[ -n "$CONFIG_PATH" ]] && return
  # 2) <skill_dir>/config.json
  if [[ -f "$SKILL_DIR_CONFIG" ]]; then
    CONFIG_PATH="$SKILL_DIR_CONFIG"
    CONFIG_PATH_IS_DEFAULT="true"
    return
  fi
  # 3) $MULTICA_CLI_ORDER_CONFIG 环境变量
  if [[ -n "${MULTICA_CLI_ORDER_CONFIG:-}" ]]; then
    CONFIG_PATH="$MULTICA_CLI_ORDER_CONFIG"
    return
  fi
  # 4) ~/.multica/config.json
  local home="${HOME:-${USERPROFILE:-}}"
  [[ -n "$home" ]] || die "HOME is not set. Set HOME (or USERPROFILE on Windows), or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  home="$(printf '%s' "$home" | tr '\134' '/')"
  CONFIG_PATH="$home/.multica/config.json"
  CONFIG_PATH_IS_DEFAULT="true"
}

# ---- 解析子命令 ----
SUBCMD="${1:-}"
[[ "$SUBCMD" == "-h" || "$SUBCMD" == "--help" || -z "$SUBCMD" ]] && { usage; exit 0; }
shift
case "$SUBCMD" in
  list|add|update|delete|resolve|unresolve) ;;
  *) die "unknown subcommand: $SUBCMD (use list / add / update / delete / resolve / unresolve)" ;;
esac

# ---- 通用参数 ----
CONFIG_PATH=""
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""
OUTPUT_JSON="false"
ASSUME_YES="false"
DRY_RUN="false"

# ---- 子命令参数 ----
# 通用 positional target
TARGET=""

# list
LIST_THREADS_ONLY="false"
LIST_SUMMARY="false"
LIST_FOLD="false"
LIST_SINCE=""
LIST_THREAD=""
LIST_TAIL=""
LIST_RECENT=""
LIST_LIMIT=""
LIST_TYPE_FILTER=""      # comment / progress_update 客户端过滤
LIST_HIDE_RESOLVED="false"

# add
ADD_CONTENT=""
ADD_CONTENT_FILE=""
ADD_TYPE=""
ADD_PARENT_ID=""
ADD_ATTACHMENT_IDS=""
ADD_SUPPRESS_AGENT_IDS=""
ADD_NOTE="false"

# update
UPDATE_CONTENT=""
UPDATE_CONTENT_FILE=""
UPDATE_ATTACHMENT_IDS=""
UPDATE_SUPPRESS_AGENT_IDS=""

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    # 通用
    --config)        CONFIG_PATH="$2"; shift 2;;
    --server-url)    SERVER_URL_OVERRIDE="$2"; shift 2;;
    --app-url)       APP_URL_OVERRIDE="$2"; shift 2;;
    --workspace-id)  WORKSPACE_ID_OVERRIDE="$2"; shift 2;;
    --json)          OUTPUT_JSON="true"; shift;;
    --yes|-y)        ASSUME_YES="true"; shift;;
    --dry-run)       DRY_RUN="true"; shift;;

    # list
    --threads-only)  LIST_THREADS_ONLY="true"; shift;;
    --summary)       LIST_SUMMARY="true"; shift;;
    --fold)          LIST_FOLD="true"; shift;;
    --since)         LIST_SINCE="$2"; shift 2;;
    --thread)        LIST_THREAD="$2"; shift 2;;
    --tail)          LIST_TAIL="$2"; shift 2;;
    --recent)        LIST_RECENT="$2"; shift 2;;
    --limit)         LIST_LIMIT="$2"; shift 2;;
    --list-type)     LIST_TYPE_FILTER="$2"; shift 2;;
    --hide-resolved) LIST_HIDE_RESOLVED="true"; shift;;

    # add / update 共享
    --content)       if [[ "$SUBCMD" == "add" ]]; then ADD_CONTENT="$2"; shift 2
                     elif [[ "$SUBCMD" == "update" ]]; then UPDATE_CONTENT="$2"; shift 2
                     else die "--content not supported for $SUBCMD"; fi;;
    --content-file)  if [[ "$SUBCMD" == "add" ]]; then ADD_CONTENT_FILE="$2"; shift 2
                     elif [[ "$SUBCMD" == "update" ]]; then UPDATE_CONTENT_FILE="$2"; shift 2
                     else die "--content-file not supported for $SUBCMD"; fi;;
    --type)          if [[ "$SUBCMD" == "add" ]]; then ADD_TYPE="$2"; shift 2
                     else die "--type only supported for add"; fi;;
    --parent-id)     ADD_PARENT_ID="$2"; shift 2;;
    --attachment-ids)
                     if [[ "$SUBCMD" == "add" ]]; then ADD_ATTACHMENT_IDS="$2"; shift 2
                     elif [[ "$SUBCMD" == "update" ]]; then UPDATE_ATTACHMENT_IDS="$2"; shift 2
                     else die "--attachment-ids not supported for $SUBCMD"; fi;;
    --suppress-agent-ids)
                     if [[ "$SUBCMD" == "add" ]]; then ADD_SUPPRESS_AGENT_IDS="$2"; shift 2
                     elif [[ "$SUBCMD" == "update" ]]; then UPDATE_SUPPRESS_AGENT_IDS="$2"; shift 2
                     else die "--suppress-agent-ids not supported for $SUBCMD"; fi;;
    --note)          ADD_NOTE="true"; shift;;

    # positional
    -h|--help) usage; exit 0;;
    --*) die "unknown flag: $1";;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"; shift
      else die "unexpected positional arg: $1"
      fi
      ;;
  esac
done

# ---- 1) 凭证解析（与 order.sh 完全一致）----
TOKEN=""
SERVER_URL=""
APP_URL=""
WORKSPACE_ID=""

resolve_config_path
if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$CONFIG_PATH_IS_DEFAULT" == "true" ]]; then
    die "Multica CLI config not found: $CONFIG_PATH. Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  fi
  die "config file not found: $CONFIG_PATH"
fi
TOKEN="$(jq -r '.token       // empty' "$CONFIG_PATH")"
SERVER_URL="$(jq -r '.server_url // empty' "$CONFIG_PATH")"
APP_URL="$(jq   -r '.app_url    // empty' "$CONFIG_PATH")"
WORKSPACE_ID="$(jq -r '.workspace_id // empty' "$CONFIG_PATH")"
if [[ -n "${MULTICA_TOKEN:-}" ]]; then
  TOKEN="$MULTICA_TOKEN"
fi
[[ -n "$SERVER_URL_OVERRIDE"   ]] && SERVER_URL="$SERVER_URL_OVERRIDE"
[[ -n "$APP_URL_OVERRIDE"      ]] && APP_URL="$APP_URL_OVERRIDE"
[[ -n "$WORKSPACE_ID_OVERRIDE" ]] && WORKSPACE_ID="$WORKSPACE_ID_OVERRIDE"

[[ -z "$TOKEN"      ]] && die "missing token. Set MULTICA_TOKEN env, or write token into $CONFIG_PATH, or pass --config"
[[ -z "$SERVER_URL" ]] && die "missing server_url. Set server_url in $CONFIG_PATH or pass --server-url"
SERVER_URL="${SERVER_URL%/}"
[[ -z "$APP_URL" ]] && APP_URL="$SERVER_URL"
AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"

# 注意：comment.sh 涉及 issue-scoped (/api/issues/{id}/comments) 和
# comment-scoped (/api/comments/{id}) 两类接口。后者要求 workspace_id 用于
# 限定 scope（UpdateComment / DeleteComment 内部用 resolveWorkspaceID 从
# X-Workspace-ID header / query workspace_id 拿）。如果没有 workspace_id，
# 这些接口会 404 或 403。

# ---- 2) HTTP 工具 ----
# 内嵌 args 数组而不是抽公共函数：command substitution + 数组赋值会在 IFS
# 上拆开带空格的 -H "Authorization: Bearer ..." 这种引号值。
# 把 workspace_id 拼到 URL 的 query 上，自动用 ? 或 & 分隔
append_workspace_id() {
  local url="$1"
  if [[ -n "$WORKSPACE_ID" ]]; then
    local sep="?"
    [[ "$url" == *\?* ]] && sep="&"
    url="${url}${sep}workspace_id=$(jq -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  fi
  echo "$url"
}

api_get() {
  local path="$1" outfile="$2"
  local url; url=$(append_workspace_id "$SERVER_URL$path")
  local args=(
    -sS -o "$outfile" -w "%{http_code}"
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" "$url" || echo "000"
}

api_post() {
  local path="$1" body="$2" outfile="$3"
  local url; url=$(append_workspace_id "$SERVER_URL$path")
  local args=(
    -sS -o "$outfile" -w "%{http_code}"
    -X POST
    -H "@$AUTH_HEADER_FILE"
    -H "Content-Type: application/json"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" --data "$body" "$url" || echo "000"
}

api_put() {
  local path="$1" body="$2" outfile="$3"
  local url; url=$(append_workspace_id "$SERVER_URL$path")
  local args=(
    -sS -o "$outfile" -w "%{http_code}"
    -X PUT
    -H "@$AUTH_HEADER_FILE"
    -H "Content-Type: application/json"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" --data "$body" "$url" || echo "000"
}

api_delete() {
  local path="$1" outfile="$2"
  local url; url=$(append_workspace_id "$SERVER_URL$path")
  local args=(
    -sS -o "$outfile" -w "%{http_code}"
    -X DELETE
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" "$url" || echo "000"
}

# ---- 3) /api/me 校验 ----
ME_HTTP=$(api_get "/api/me" $TMP_DIR/me.json)
if [[ "$ME_HTTP" != "200" ]]; then
  cat $TMP_DIR/me.json >&2 || true
  rm -f $TMP_DIR/me.json
  die "/api/me returned HTTP $ME_HTTP - token invalid or expired."
fi
rm -f $TMP_DIR/me.json

# ---- 4) 工具 ----
is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# csv → JSON 数组（空 → null）
csv_to_json_array() {
  local csv="$1"
  if [[ -z "$csv" ]]; then
    echo "null"
  else
    jq -nc --arg s "$csv" '($s | split(",")) | map(select(. != ""))'
  fi
}

# 把 "..." 写到 stderr 显示前 80 字
preview_text() {
  local s="$1"
  local max=80
  if [[ ${#s} -gt $max ]]; then
    echo "${s:0:$max}…"
  else
    echo "$s"
  fi
}

# ============================================================
# 子命令实现
# ============================================================

# ---- list ----
cmd_list() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh list <issue-id-or-uuid> [--threads-only] [--summary] [--fold] [--since RFC3339] [--thread <comment-uuid>] [--tail N] [--recent N] [--limit N] [--list-type TYPE] [--hide-resolved]"

  # 组合 query 参数
  local q=""
  q+="roots_only=$([[ "$LIST_THREADS_ONLY" == "true" ]] && echo true || echo false)"
  q+="&summary=$([[ "$LIST_SUMMARY" == "true" ]] && echo true || echo false)"
  q+="&fold=$([[ "$LIST_FOLD" == "true" ]] && echo true || echo false)"
  [[ -n "$LIST_SINCE"   ]] && q+="&since=$(jq -rn --arg v "$LIST_SINCE" '$v|@uri')"
  [[ -n "$LIST_THREAD"  ]] && q+="&thread=$(jq -rn --arg v "$LIST_THREAD" '$v|@uri')"
  # tail 必须在 thread 上下文中使用，单独传会 400
  [[ -n "$LIST_TAIL"    ]] && q+="&tail=$LIST_TAIL"
  [[ -n "$LIST_RECENT"  ]] && q+="&recent=$LIST_RECENT"

  # 互斥检查
  if [[ "$LIST_FOLD" == "true" && -n "$LIST_SINCE" ]]; then
    die "--fold and --since are mutually exclusive (server-side rule, see server/internal/handler/comment.go)"
  fi
  if [[ "$LIST_FOLD" == "true" && -n "$LIST_TAIL" ]]; then
    die "--fold and --tail are mutually exclusive (server-side rule)"
  fi
  if [[ "$LIST_FOLD" == "true" && "$LIST_THREADS_ONLY" == "true" ]]; then
    die "--fold and --threads-only are mutually exclusive"
  fi

  local OUT="$TMP_DIR/list.json"
  local HTTP
  HTTP=$(api_get "/api/issues/$TARGET/comments?$q" "$OUT")
  if [[ "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "GET /api/issues/$TARGET/comments returned HTTP $HTTP"
  fi

  # 客户端过滤
  local FILTERED="$OUT"
  if [[ -n "$LIST_TYPE_FILTER" ]]; then
    FILTERED="${OUT}.filtered"
    jq --arg t "$LIST_TYPE_FILTER" '[ .[] | select(.type == $t) ]' "$OUT" > "$FILTERED"
  fi
  if [[ "$LIST_HIDE_RESOLVED" == "true" ]]; then
    local tmp="${FILTERED}.tmp"
    jq '[ .[] | select(.resolved_at == null) ]' "$FILTERED" > "$tmp" && mv "$tmp" "$FILTERED"
  fi
  if [[ -n "$LIST_LIMIT" ]]; then
    local tmp="${FILTERED}.tmp"
    jq --argjson n "$LIST_LIMIT" '.[0:$n]' "$FILTERED" > "$tmp" && mv "$tmp" "$FILTERED"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$FILTERED"
    rm -f "$OUT" "$FILTERED"
    return
  fi

  # 人话版
  local COUNT; COUNT=$(jq 'length' "$FILTERED")
  echo "Issue: $TARGET"
  echo "Comments: $COUNT"
  echo "---"
  if [[ "$COUNT" -eq 0 ]]; then
    rm -f "$OUT" "$FILTERED"
    return
  fi

  # 按 created_at 升序打印（与 server 默认一致）
  jq -r '
    .[] |
    [
      (.id[0:8]),
      (.resolved_at // "" | if . != "" then " [resolved]" else "" end),
      (.type // "comment"),
      (.author_type // "?"),
      (.author_id // "" | if . != "" then .[0:8] else "?" end),
      (.created_at // ""),
      "  ",
      (.content | gsub("\n"; " ") | .[0:140])
    ] | join("")
  ' "$FILTERED"

  rm -f "$OUT" "$FILTERED"
}

# ---- add ----
cmd_add() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh add <issue-id-or-uuid> --content TEXT|--content-file <path> [--type comment|progress_update] [--parent-id UUID] [--attachment-ids u1,u2] [--suppress-agent-ids u1,u2] [--note]"

  # 收集 content
  local content=""
  if [[ -n "$ADD_CONTENT_FILE" ]]; then
    [[ -f "$ADD_CONTENT_FILE" ]] || die "--content-file not found: $ADD_CONTENT_FILE"
    content="$(cat "$ADD_CONTENT_FILE")"
  fi
  if [[ -n "$ADD_CONTENT" ]]; then
    if [[ -n "$content" ]]; then
      content="${content}"$'\n'"${ADD_CONTENT}"  # 多源拼接（罕见）
    else
      content="$ADD_CONTENT"
    fi
  fi
  [[ -z "$content" ]] && die "comment content is required: pass --content TEXT or --content-file <path>"

  # --note：把 /note 拼到首 token（大小写不敏感也认）
  if [[ "$ADD_NOTE" == "true" ]]; then
    if [[ ! "$content" =~ ^[[:space:]]*/[Nn][Oo][Tt][Ee]([[:space:]]|$) ]]; then
      content="/note ${content}"
    fi
  fi

  # type 白名单
  local type="comment"
  if [[ -n "$ADD_TYPE" ]]; then
    case "$ADD_TYPE" in
      comment|progress_update) type="$ADD_TYPE" ;;
      *) die "--type must be one of: comment / progress_update (status_change and system are platform-generated)" ;;
    esac
  fi

  local body
  body=$(jq -n \
    --arg content "$content" \
    --arg type "$type" \
    --arg parent_id "$ADD_PARENT_ID" \
    --argjson attachment_ids "$(csv_to_json_array "$ADD_ATTACHMENT_IDS")" \
    --argjson suppress_agent_ids "$(csv_to_json_array "$ADD_SUPPRESS_AGENT_IDS")" \
    '
    {
      content: $content,
      type:    $type,
      parent_id:        (if $parent_id == "" then null else $parent_id end),
      attachment_ids:   (if $attachment_ids == null then null else $attachment_ids end),
      suppress_agent_ids: (if $suppress_agent_ids == null then null else $suppress_agent_ids end),
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "POST /api/issues/$TARGET/comments"
    echo "Body:"
    echo "$body" | jq .
    return
  fi

  local OUT="$TMP_DIR/add.json"
  local HTTP
  HTTP=$(api_post "/api/issues/$TARGET/comments" "$body" "$OUT")
  if [[ "$HTTP" != "201" && "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "POST /api/issues/$TARGET/comments returned HTTP $HTTP"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$OUT"
    rm -f "$OUT"
    return
  fi

  local CID AUTHOR CREATED TYPE RESOLVED
  CID=$(jq -r '.id' "$OUT")
  AUTHOR=$(jq -r '"\(.author_type[0:1] | ascii_upcase)\(.author_type[1:]):\(.author_id[0:8])"' "$OUT")
  CREATED=$(jq -r '.created_at' "$OUT")
  TYPE=$(jq -r '.type' "$OUT")
  RESOLVED=$(jq -r '.resolved_at // ""' "$OUT")
  echo "Comment posted."
  echo "  ID:      $CID"
  echo "  Issue:   $TARGET"
  echo "  Type:    $TYPE"
  echo "  Author:  $AUTHOR"
  echo "  Created: $CREATED"
  [[ -n "$RESOLVED" ]] && echo "  Resolved: $RESOLVED"
  echo "  Content: $(preview_text "$content")"

  # 触发结果（如有）
  local TRIG_COUNT
  TRIG_COUNT=$(jq -r '.trigger_outcomes | length // 0' "$OUT" 2>/dev/null || echo 0)
  if [[ "$TRIG_COUNT" -gt 0 ]]; then
    echo "  Mentions ($TRIG_COUNT):"
    jq -r '.trigger_outcomes[] | "    - \(.target_type):\(.target_id[0:8]) [\(.status)]" + (if .reason_code != "" then " (\(.reason_code))" else "" end)' "$OUT"
  fi

  rm -f "$OUT"
}

# ---- update ----
cmd_update() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh update <comment-id> --content TEXT|--content-file <path> [--attachment-ids u1,u2] [--suppress-agent-ids u1,u2]"

  # 收集 content
  local content=""
  if [[ -n "$UPDATE_CONTENT_FILE" ]]; then
    [[ -f "$UPDATE_CONTENT_FILE" ]] || die "--content-file not found: $UPDATE_CONTENT_FILE"
    content="$(cat "$UPDATE_CONTENT_FILE")"
  fi
  if [[ -n "$UPDATE_CONTENT" ]]; then
    if [[ -n "$content" ]]; then
      content="${content}"$'\n'"${UPDATE_CONTENT}"
    else
      content="$UPDATE_CONTENT"
    fi
  fi
  [[ -z "$content" ]] && die "comment content is required: pass --content TEXT or --content-file <path>"

  # attachment_ids：缺省 = null（保留原集合）；显式传 "" = 清空
  local attachment_ids_json suppress_agent_ids_json
  if [[ -n "$UPDATE_ATTACHMENT_IDS" ]]; then
    attachment_ids_json=$(csv_to_json_array "$UPDATE_ATTACHMENT_IDS")
  else
    attachment_ids_json="null"
  fi
  suppress_agent_ids_json=$(csv_to_json_array "$UPDATE_SUPPRESS_AGENT_IDS")

  local body
  body=$(jq -n \
    --arg content "$content" \
    --argjson attachment_ids "$attachment_ids_json" \
    --argjson suppress_agent_ids "$suppress_agent_ids_json" \
    '
    {
      content: $content,
      attachment_ids:   (if $attachment_ids == null then null else $attachment_ids end),
      suppress_agent_ids: (if $suppress_agent_ids == null then null else $suppress_agent_ids end),
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "PUT /api/comments/$TARGET"
    echo "Body:"
    echo "$body" | jq .
    return
  fi

  # 默认要确认（编辑有副作用：会取消原评论相关 task，重新触发 mentions）
  if [[ "$ASSUME_YES" != "true" ]]; then
    echo "About to update comment $TARGET:"
    echo "  New content: $(preview_text "$content")"
    if [[ -n "$UPDATE_ATTACHMENT_IDS" ]]; then
      echo "  Attachment set: $UPDATE_ATTACHMENT_IDS (will REPLACE existing)"
    fi
    if [[ -n "$UPDATE_SUPPRESS_AGENT_IDS" ]]; then
      echo "  Suppress agents: $UPDATE_SUPPRESS_AGENT_IDS"
    fi
    echo "WARN: editing comment content cancels any agent task whose batch contained this comment, then re-triggers mentions on the new content."
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
  fi

  local OUT="$TMP_DIR/update.json"
  local HTTP
  HTTP=$(api_put "/api/comments/$TARGET" "$body" "$OUT")
  if [[ "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "PUT /api/comments/$TARGET returned HTTP $HTTP"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$OUT"
    rm -f "$OUT"
    return
  fi

  local UPDATED UPDATED_AT
  UPDATED=$(jq -r '.updated_at' "$OUT")
  echo "Comment updated."
  echo "  ID:       $TARGET"
  echo "  Updated:  $UPDATED"
  echo "  Content:  $(preview_text "$content")"

  local TRIG_COUNT
  TRIG_COUNT=$(jq -r '.trigger_outcomes | length // 0' "$OUT" 2>/dev/null || echo 0)
  if [[ "$TRIG_COUNT" -gt 0 ]]; then
    echo "  Re-triggered ($TRIG_COUNT):"
    jq -r '.trigger_outcomes[] | "    - \(.target_type):\(.target_id[0:8]) [\(.status)]" + (if .reason_code != "" then " (\(.reason_code))" else "" end)' "$OUT"
  fi

  rm -f "$OUT"
}

# ---- delete ----
cmd_delete() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh delete <comment-id> [--yes]"

  # 确认：删除有副作用（cancel tasks, cascade-删除 attachment rows）
  if [[ "$ASSUME_YES" != "true" ]]; then
    echo "About to DELETE comment $TARGET."
    echo "WARN: author or admin only (403 otherwise). Server will cancel any agent task whose batch contained this comment and remove the comment + its attachments."
    read -r -p "Continue? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
  fi

  local OUT="$TMP_DIR/delete.json"
  local HTTP
  HTTP=$(api_delete "/api/comments/$TARGET" "$OUT")
  if [[ "$HTTP" != "204" && "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "DELETE /api/comments/$TARGET returned HTTP $HTTP (204 = success)"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    jq -nc --arg id "$TARGET" '{deleted: true, comment_id: $id}'
    rm -f "$OUT"
    return
  fi

  echo "Comment deleted: $TARGET"
  rm -f "$OUT"
}

# ---- resolve ----
cmd_resolve() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh resolve <comment-id>"

  # 解析路径：comment-scoped，不需要 /api/issues/{id} 前缀
  local OUT="$TMP_DIR/resolve.json"
  local HTTP
  HTTP=$(api_post "/api/comments/$TARGET/resolve" "{}" "$OUT")
  if [[ "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "POST /api/comments/$TARGET/resolve returned HTTP $HTTP"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$OUT"
    rm -f "$OUT"
    return
  fi

  local RESOLVED_AT RESOLVED_BY
  RESOLVED_AT=$(jq -r '.resolved_at' "$OUT")
  RESOLVED_BY=$(jq -r '"\(.resolved_by_type // "")\(.resolved_by_id // "" | if . != "" then ":\(.[0:8])" else "" end)"' "$OUT")
  echo "Comment resolved: $TARGET"
  echo "  Resolved at: $RESOLVED_AT"
  echo "  Resolved by: $RESOLVED_BY"
  rm -f "$OUT"
}

# ---- unresolve ----
cmd_unresolve() {
  [[ -z "$TARGET" ]] && die "usage: comment.sh unresolve <comment-id>"

  local OUT="$TMP_DIR/unresolve.json"
  local HTTP
  HTTP=$(api_delete "/api/comments/$TARGET/resolve" "$OUT")
  if [[ "$HTTP" != "200" ]]; then
    cat "$OUT" >&2 || true; rm -f "$OUT"
    die "DELETE /api/comments/$TARGET/resolve returned HTTP $HTTP"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$OUT"
    rm -f "$OUT"
    return
  fi

  echo "Comment unresolved: $TARGET"
  rm -f "$OUT"
}

# ---- 派发 ----
case "$SUBCMD" in
  list)       cmd_list ;;
  add)        cmd_add ;;
  update)     cmd_update ;;
  delete)     cmd_delete ;;
  resolve)    cmd_resolve ;;
  unresolve)  cmd_unresolve ;;
esac
