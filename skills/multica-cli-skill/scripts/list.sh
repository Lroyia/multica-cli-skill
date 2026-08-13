#!/usr/bin/env bash
# multica-cli-skill / list.sh: 读取用户的 ~/.multica/config.json，直接调 /api/issues /api/issues/search 查询工单
#
# 子命令（互斥，缺省走 list）:
#   list      列出工单，支持按 status / priority / assignee / project 等过滤
#   search    全文搜索工单（按标题 / 描述 / 评论模糊匹配）
#   get       取单条工单详情（按 identifier 如 MUL-123 或 UUID）
#
# 用法:
#   list.sh list   [选项]
#   list.sh search [选项]
#   list.sh get    <identifier-or-uuid> [--json]
#
# 通用选项:
#   --config <path>                  config.json 路径；缺省同 order.sh 的解析规则
#   --server-url URL                 覆盖 config 里的 server_url
#   --app-url URL                    覆盖 config 里的 app_url
#   --workspace-id UUID              覆盖 config 里的 workspace_id
#   --json                           以 JSON 形式输出（不带 --pretty）
#
# list 子命令选项:
#   --statuses backlog,todo,in_progress,in_review,done,blocked,cancelled
#                                 多选；逗号分隔
#   --priorities urgent,high,medium,low,none
#   --assignee-id UUID              直接给出 assignee UUID
#   --assignee "前端组"|"老王"     按名字 fuzzy match（squad→agent→member）
#                                 命中后用命中的 UUID 作为 --assignee-id 透传
#   --creator-id UUID               按创建者 UUID 过滤
#   --creator "用户名"             同 assignee，按名字匹配
#   --project-id UUID               按项目 UUID
#   --project "支付重构"           同 assignee，按名字匹配
#   --open-only                     只看未关闭（open_only=true）
#   --include-closed                包含已关闭（默认行为）
#   --include-no-assignee           include_no_assignee=true
#   --include-no-project            include_no_project=true
#   --scheduled                     scheduled=true
#   --label-ids u1,u2,...           按 label 过滤
#   --q "<关键词>"                  list 也会以 q=<关键词> 调用 /search（互斥）
#   --sort created_at|updated_at|priority|due_date|number
#   --direction asc|desc            排序方向，缺省 desc
#   --limit N                       缺省 50，上限 500
#   --offset N                      翻页偏移
#   --strict-match                  fuzzy match 只接受完全相同的名字
#
# search 子命令选项:
#   --q "<关键词>"                  必填
#   --include-closed
#   --limit N
#   --offset N
#
# get 子命令:
#   list.sh get <identifier|uuid> [--json]
#   identifier 形如 MUL-123 / prefix-N；uuid 形如 5c1f-...
#   script 会自动判断：包含 -N 后缀的按 identifier 走 /api/issues/search?q=<id>，
#   纯 UUID 走 /api/issues/{id}。
#
# 前置依赖: curl, jq, uname
# 凭证来源: --config > <skill_dir>/config.json > $MULTICA_CLI_ORDER_CONFIG > ~/.multica/config.json；$MULTICA_TOKEN 覆盖 token

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

SUBCMD="${1:-list}"
shift || true

case "$SUBCMD" in
  list|search|get) ;;
  -h|--help)
    sed -n '2,52p' "$0"
    exit 0
    ;;
  *) echo "ERROR: unknown subcommand: $SUBCMD (use list / search / get)" >&2; exit 64;;
esac

# ---- 凭证（与 order.sh 完全一致的解析流程）----
TITLE=""
DESCRIPTION=""  # not used, kept to avoid env confusion
TOKEN=""
SERVER_URL=""
APP_URL=""
WORKSPACE_ID=""
CONFIG_PATH=""

usage() {
  sed -n '2,52p' "$0"
}

die() { echo "ERROR: $*" >&2; exit 1; }

umask 077
TMP_DIR="$(mktemp -d /tmp/multica-cli-skill.XXXXXX)" || die "failed to create private temp directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

# 解析脚本所在的 skill 目录
SKILL_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
SKILL_DIR_CONFIG="$SKILL_DIR/config.json"

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

# 子命令级参数
STATUSES_CSV=""
PRIORITIES_CSV=""
ASSIGNEE_ID=""
ASSIGNEE_NAME=""
CREATOR_ID=""
CREATOR_NAME=""
PROJECT_ID=""
PROJECT_NAME=""
OPEN_ONLY="false"
INCLUDE_CLOSED="false"
INCLUDE_NO_ASSIGNEE="false"
INCLUDE_NO_PROJECT="false"
SCHEDULED="false"
LABEL_IDS_CSV=""
Q=""
SORT=""
DIRECTION=""
LIMIT=""
OFFSET=""
OUTPUT_JSON="false"
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""
STRICT_MATCH="false"
COUNT_ONLY="false"
IDS_ONLY="false"
TARGET=""  # get 子命令要查的 identifier / uuid

# 解析参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    --statuses)        STATUSES_CSV="$2"; shift 2;;
    --priorities)      PRIORITIES_CSV="$2"; shift 2;;
    --assignee-id)     ASSIGNEE_ID="$2"; shift 2;;
    --assignee)        ASSIGNEE_NAME="$2"; shift 2;;
    --creator-id)      CREATOR_ID="$2"; shift 2;;
    --creator)         CREATOR_NAME="$2"; shift 2;;
    --project-id)      PROJECT_ID="$2"; shift 2;;
    --project)         PROJECT_NAME="$2"; shift 2;;
    --open-only)       OPEN_ONLY="true"; shift;;
    --include-closed)  INCLUDE_CLOSED="true"; shift;;
    --include-no-assignee) INCLUDE_NO_ASSIGNEE="true"; shift;;
    --include-no-project) INCLUDE_NO_PROJECT="true"; shift;;
    --scheduled)       SCHEDULED="true"; shift;;
    --label-ids)       LABEL_IDS_CSV="$2"; shift 2;;
    --q)               Q="$2"; shift 2;;
    --sort)            SORT="$2"; shift 2;;
    --direction)       DIRECTION="$2"; shift 2;;
    --limit)           LIMIT="$2"; shift 2;;
    --offset)          OFFSET="$2"; shift 2;;
    --config)          CONFIG_PATH="$2"; shift 2;;
    --server-url)      SERVER_URL_OVERRIDE="$2"; shift 2;;
    --app-url)         APP_URL_OVERRIDE="$2"; shift 2;;
    --workspace-id)    WORKSPACE_ID_OVERRIDE="$2"; shift 2;;
    --strict-match)    STRICT_MATCH="true"; shift;;
    --count-only)      COUNT_ONLY="true"; shift;;
    --ids-only)        IDS_ONLY="true"; shift;;
    --json)            OUTPUT_JSON="true"; shift;;
    -h|--help)         usage; exit 0;;
    *)
      if [[ "$SUBCMD" == "get" && -z "$TARGET" ]]; then
        TARGET="$1"; shift
      else
        die "unknown arg: $1"
      fi
      ;;
  esac
done

# sub-command 互斥检查
if [[ "$SUBCMD" == "search" && -z "$Q" ]]; then
  die "--q <keyword> is required for search"
fi
if [[ "$SUBCMD" == "get" && -z "$TARGET" ]]; then
  die "usage: list.sh get <identifier|uuid>"
fi
# list + search 用同一个 endpoint（/api/issues?open_only=false 可走 search 用的 /api/issues/search）
# 这里 list 默认走 /api/issues；只有 --q 才切到 /api/issues/search

# ---- 凭证解析（默认读取 Multica CLI home 配置）----
resolve_config_path
if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$CONFIG_PATH_IS_DEFAULT" == "true" ]]; then
    die "Multica CLI config not found: $CONFIG_PATH. Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  fi
  die "config file not found: $CONFIG_PATH"
fi
command -v jq >/dev/null 2>&1 || die "jq is required to parse $CONFIG_PATH. Install jq first."
JQ="jq"
TOKEN="$($JQ -r '.token       // empty' "$CONFIG_PATH")"
SERVER_URL="$($JQ -r '.server_url // empty' "$CONFIG_PATH")"
APP_URL="$($JQ   -r '.app_url    // empty' "$CONFIG_PATH")"
WORKSPACE_ID="$($JQ -r '.workspace_id // empty' "$CONFIG_PATH")"
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

# ---- 反查 workspace 路径段（slug → name → id）----
# Multica web 路由使用 workspace 的 slug/name，**不**直接用 id；用 id 拼出来的 URL 在浏览器里打不开。
# 三层回退：
#   1) multica CLI 子命令 `multica workspace list`（注意：CLI 可能登录在别的 workspace，看不到当前 workspace）
#   2) HTTP `GET /api/workspaces/{id}`（用本 skill 自带的 token；不依赖 CLI）
#   3) 最终回退到 workspace_id，并在 stderr 警告
resolve_workspace_path_seg() {
  local ws="$1" out="$2"
  local seg=""
  # 1) CLI
  if command -v multica >/dev/null 2>&1 && [[ -n "$ws" ]]; then
    seg=$(multica workspace list --output json 2>/dev/null \
      | $JQ -r --arg id "$ws" '
          if type == "array" then (.[] | select(.id == $id) | (.slug // .name // empty))
          elif (.workspaces // null) != null then (.workspaces[] | select(.id == $id) | (.slug // .name // empty))
          else empty end
        ' \
      | head -n1 || true)
  fi
  # 2) API 回退
  if [[ -z "$seg" && -n "$ws" && -n "$TOKEN" && -n "$SERVER_URL" ]]; then
    local resp
    resp="$(curl -sS -H "@$AUTH_HEADER_FILE" \
      -H "X-Client-Platform: multica-cli-skill" \
      "$SERVER_URL/api/workspaces/$ws" 2>/dev/null || true)"
    if [[ -n "$resp" ]] && [[ "$(echo "$resp" | $JQ -r '.id // empty')" == "$ws" ]]; then
      seg="$(echo "$resp" | $JQ -r '.slug // .name // empty')"
    fi
  fi
  if [[ -n "$seg" ]]; then
    printf '%s' "$seg" > "$out"
  else
    printf '%s' "$ws" > "$out"
    echo "WARN: 无法从 CLI 或 API 反查 workspace slug/name，URL 将使用 workspace_id（在浏览器中可能打不开）。建议在 config.json 里加上 workspace 的 slug 或在 multica CLI 里切换到对应 workspace。" >&2
  fi
}

WORKSPACE_PATH_SEG_FILE="$TMP_DIR/workspace-path-seg"
if [[ -n "$WORKSPACE_ID" ]]; then
  resolve_workspace_path_seg "$WORKSPACE_ID" "$WORKSPACE_PATH_SEG_FILE"
fi
WORKSPACE_PATH_SEG="$(cat "$WORKSPACE_PATH_SEG_FILE" 2>/dev/null || true)"

# auto-match helper（共用 order.sh 的 fuzzy match 打分）
score_name() {
  local input="$1" haystack="$2"
  [[ -z "$haystack" || -z "$input" ]] && { echo 0; return; }
  if [[ "$haystack" == "$input" ]]; then echo 100; return; fi
  local lc_in lc_hay
  lc_in=$(printf '%s' "$input"   | tr '[:upper:]' '[:lower:]')
  lc_hay=$(printf '%s' "$haystack" | tr '[:upper:]' '[:lower:]')
  if [[ "$lc_hay" == "$lc_in" ]]; then echo 90; return; fi
  if [[ "$lc_hay" == *"$lc_in"* ]]; then echo 70; return; fi
  local in_noh hay_noh
  in_noh=$(printf '%s' "$lc_in" | tr -d ' -_')
  hay_noh=$(printf '%s' "$lc_hay" | tr -d ' -_')
  if [[ -n "$in_noh" && "$hay_noh" == *"$in_noh"* ]]; then echo 50; return; fi
  echo 0
}

pick_best() {
  local name_field="$1" id_field="$2" input="$3" file="$4"
  if [[ "$STRICT_MATCH" == "true" ]]; then
    $JQ -r --arg n "$input" --arg nfield "$name_field" --arg ifield "$id_field" '
      [ .[] | { name: (.[$nfield] // ""), id: (.[$ifield] // "") } | select(.name == $n) ]
      | if length == 0 then empty
        elif length == 1 then .[0].id
        else error("ambiguous strict match: \(length) entries named \"\($n)\"") | empty
        end
    ' "$file" | head -n1
  else
    $JQ -r --arg n "$input" --arg nfield "$name_field" --arg ifield "$id_field" '
      [ range(0; length) as $i
        | { idx: $i,
            name: (.[$i][$nfield] // ""),
            id:   (.[$i][$ifield] // "") }
        | .score =
            ( if .name == $n then 100
              elif (.name | ascii_downcase) == ($n | ascii_downcase) then 90
              elif (.name | ascii_downcase | test($n | ascii_downcase)) then 70
              elif ((.name | ascii_downcase | gsub("[ \\-_]"; "")) | test($n | ascii_downcase | gsub("[ \\-_]"; ""))) then 50
              else 0
              end )
        | select(.score > 0)
      ]
      | sort_by(-.score, .idx)
      | if length == 0 then empty else .[0].id end
    ' "$file" | head -n1
  fi
}

# 通用 HTTP 调用
api_get() {
  local path="$1" outfile="$2"
  local url="$SERVER_URL$path"
  if [[ -n "$WORKSPACE_ID" ]]; then
    url="$url?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  fi
  local args=(
    -sS
    -o "$outfile"
    -w "%{http_code}"
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" "$url" || echo "000"
}

# /api/me 校验 token
ME_HTTP=$(api_get "/api/me" $TMP_DIR/me.json)
if [[ "$ME_HTTP" != "200" ]]; then
  cat $TMP_DIR/me.json >&2 || true
  rm -f $TMP_DIR/me.json
  die "/api/me returned HTTP $ME_HTTP - token invalid or expired."
fi
rm -f $TMP_DIR/me.json

# ---- 按需 fuzzy match ----
SQUADS_FILE=$TMP_DIR/squads.json
AGENTS_FILE=$TMP_DIR/agents.json
MEMBERS_FILE=$TMP_DIR/members.json
PROJECTS_FILE=$TMP_DIR/projects.json
rm -f "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"

need_squads=false; need_agents=false; need_members=false; need_projects=false
[[ -n "$ASSIGNEE_NAME" ]] && need_squads=true && need_agents=true && need_members=true
[[ -n "$CREATOR_NAME"   ]] && need_members=true
[[ -n "$PROJECT_NAME"   ]] && need_projects=true

if [[ "$need_squads" == "true" ]]; then
  H=$(api_get "/api/squads" "$SQUADS_FILE"); [[ "$H" == "200" ]] || { cat "$SQUADS_FILE" >&2; rm -f "$SQUADS_FILE"; die "GET /api/squads HTTP $H"; }
fi
if [[ "$need_agents" == "true" ]]; then
  H=$(api_get "/api/agents" "$AGENTS_FILE"); [[ "$H" == "200" ]] || { cat "$AGENTS_FILE" >&2; rm -f "$AGENTS_FILE"; die "GET /api/agents HTTP $H"; }
fi
if [[ "$need_members" == "true" ]]; then
  if [[ -z "$WORKSPACE_ID" ]]; then
    die "--workspace-id (or workspace_id in config) is required to lookup members"
  fi
  H=$(api_get "/api/workspaces/$WORKSPACE_ID/members" "$MEMBERS_FILE")
  [[ "$H" == "200" ]] || { cat "$MEMBERS_FILE" >&2; rm -f "$MEMBERS_FILE"; die "GET members HTTP $H"; }
fi
if [[ "$need_projects" == "true" ]]; then
  H=$(api_get "/api/projects" "$PROJECTS_FILE"); [[ "$H" == "200" ]] || { cat "$PROJECTS_FILE" >&2; rm -f "$PROJECTS_FILE"; die "GET /api/projects HTTP $H"; }
  # /api/projects 返回 {"projects":[...], "total":N}，解包成裸数组供后续 pick_best 使用
  if ! $JQ -e '.projects | type == "array"' "$PROJECTS_FILE" >/dev/null 2>&1; then
    die "GET /api/projects 返回的 shape 不是预期包裹对象（缺少 .projects 数组）。请查看 $PROJECTS_FILE"
  fi
  $JQ '.projects' "$PROJECTS_FILE" > "$PROJECTS_FILE.tmp" && mv "$PROJECTS_FILE.tmp" "$PROJECTS_FILE"
fi

# 匹配 assignee（squad → agent → member）
if [[ -n "$ASSIGNEE_NAME" ]]; then
  found=""
  for kind in squad agent member; do
    case "$kind" in
      squad)
        [[ -f "$SQUADS_FILE" ]] && found=$(pick_best "name" "id" "$ASSIGNEE_NAME" "$SQUADS_FILE") && [[ -n "$found" ]] && { ASSIGNEE_ID="$found"; break; }
        ;;
      agent)
        [[ -f "$AGENTS_FILE" ]] && found=$(pick_best "name" "id" "$ASSIGNEE_NAME" "$AGENTS_FILE") && [[ -n "$found" ]] && { ASSIGNEE_ID="$found"; break; }
        ;;
      member)
        if [[ -f "$MEMBERS_FILE" ]]; then
          found=$($JQ -r --arg n "$ASSIGNEE_NAME" '
            [ range(0; length) as $i
              | { idx: $i,
                  name: ((.[$i].user // .[$i]).name // ""),
                  email: ((.[$i].user // .[$i]).email // ""),
                  id: (.[$i].user_id // "") }
              | . + { score:
                  ( if .name == $n then 100
                    elif (.name | ascii_downcase) == ($n | ascii_downcase) then 90
                    elif (.name | ascii_downcase | test($n | ascii_downcase)) then 70
                    elif ((.name | ascii_downcase | gsub("[ \\-_]"; "")) | test($n | ascii_downcase | gsub("[ \\-_]"; ""))) then 50
                    elif (.email | ascii_downcase) == ($n | ascii_downcase) then 85
                    else 0
                    end ) }
              | select(.score > 0)
            ]
            | sort_by(-.score, .idx)
            | if length == 0 then empty else .[0].id end
          ' "$MEMBERS_FILE" | head -n1 || true)
          [[ -n "$found" ]] && ASSIGNEE_ID="$found"
        fi
        ;;
    esac
  done
  [[ -z "$ASSIGNEE_ID" ]] && die "no squad/agent/member matched \"$ASSIGNEE_NAME\""
fi

# 匹配 creator（仅 member）
if [[ -n "$CREATOR_NAME" ]]; then
  [[ ! -f "$MEMBERS_FILE" ]] && die "--creator requires members list"
  CREATOR_ID=$($JQ -r --arg n "$CREATOR_NAME" '
    [ range(0; length) as $i
      | { idx: $i,
          name: ((.[$i].user // .[$i]).name // ""),
          email: ((.[$i].user // .[$i]).email // ""),
          id: (.[$i].user_id // "") }
      | . + { score:
          ( if .name == $n then 100
            elif (.name | ascii_downcase) == ($n | ascii_downcase) then 90
            elif (.name | ascii_downcase | test($n | ascii_downcase)) then 70
            elif ((.name | ascii_downcase | gsub("[ \\-_]"; "")) | test($n | ascii_downcase | gsub("[ \\-_]"; ""))) then 50
            elif (.email | ascii_downcase) == ($n | ascii_downcase) then 85
            else 0
            end ) }
      | select(.score > 0)
    ]
    | sort_by(-.score, .idx)
    | if length == 0 then empty else .[0].id end
  ' "$MEMBERS_FILE" | head -n1 || true)
  [[ -z "$CREATOR_ID" ]] && die "no member matched creator \"$CREATOR_NAME\""
fi

# 匹配 project
if [[ -n "$PROJECT_NAME" ]]; then
  [[ ! -f "$PROJECTS_FILE" ]] && die "--project requires projects list"
  PROJECT_ID=$(pick_best "title" "id" "$PROJECT_NAME" "$PROJECTS_FILE")
  [[ -z "$PROJECT_ID" ]] && die "no project matched \"$PROJECT_NAME\""
fi

# ---- 构造 query ----
# 单值 vs 复数形式：根据后端签名，priority / status 同时支持单值和多值；
# 本脚本统一传复数 (priorities / statuses) 以方便加多选。
build_query() {
  local qs=""
  local k v
  while IFS='=' read -r k v; do
    [[ -z "$v" ]] && continue
    v_enc=$($JQ -rn --arg x "$v" '$x|@uri')
    [[ -n "$qs" ]] && qs+="&"
    qs+="$k=$v_enc"
  done
  echo "$qs"
}

QS=""
[[ -n "$STATUSES_CSV"   ]] && QS+="&statuses=$STATUSES_CSV"
[[ -n "$PRIORITIES_CSV" ]] && QS+="&priorities=$PRIORITIES_CSV"
[[ -n "$ASSIGNEE_ID"    ]] && QS+="&assignee_id=$ASSIGNEE_ID"
[[ -n "$CREATOR_ID"     ]] && QS+="&creator_id=$CREATOR_ID"
[[ -n "$PROJECT_ID"     ]] && QS+="&project_id=$PROJECT_ID"
[[ -n "$LABEL_IDS_CSV"  ]] && QS+="&label_ids=$LABEL_IDS_CSV"
[[ "$OPEN_ONLY"         == "true" ]] && QS+="&open_only=true"
[[ "$INCLUDE_CLOSED"    == "true" ]] && QS+="&include_closed=true"
[[ "$INCLUDE_NO_ASSIGNEE" == "true" ]] && QS+="&include_no_assignee=true"
[[ "$INCLUDE_NO_PROJECT"  == "true" ]] && QS+="&include_no_project=true"
[[ "$SCHEDULED"          == "true" ]] && QS+="&scheduled=true"
[[ -n "$SORT"           ]] && QS+="&sort=$SORT"
[[ -n "$DIRECTION"      ]] && QS+="&direction=$DIRECTION"
[[ -n "$LIMIT"          ]] && QS+="&limit=$LIMIT"
[[ -n "$OFFSET"         ]] && QS+="&offset=$OFFSET"

# 去掉开头的 '&'
QS="${QS#&}"

# 调对应 endpoint
fetch_issues() {
  local url="$SERVER_URL/api/issues"
  [[ -n "$WORKSPACE_ID" ]] && url+="?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  [[ -n "$QS" ]] && { [[ -n "$WORKSPACE_ID" ]] && url+="&$QS" || url+="?$QS"; }

  local args=(
    -sS
    -o $TMP_DIR/resp.json
    -w "%{http_code}"
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" "$url" || echo "000"
}

fetch_search() {
  local q_enc=$($JQ -rn --arg x "$Q" '$x|@uri')
  local url="$SERVER_URL/api/issues/search?q=$q_enc"
  [[ -n "$WORKSPACE_ID" ]] && url+="&workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  [[ "$INCLUDE_CLOSED" == "true" ]] && url+="&include_closed=true"
  [[ -n "$LIMIT"        ]] && url+="&limit=$LIMIT"
  [[ -n "$OFFSET"       ]] && url+="&offset=$OFFSET"

  local args=(
    -sS
    -o $TMP_DIR/resp.json
    -w "%{http_code}"
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  curl "${args[@]}" "$url" || echo "000"
}

# 把单个 issue 输出补一个 web_url 字段
attach_web_url() {
  local json_in="$1" json_out="$2"
  $JQ --arg app "$APP_URL" --arg ws "${WORKSPACE_PATH_SEG:-${WORKSPACE_ID:-}}" '
    [ .[]? | . + {
        web_url: (
          if .web_url then .web_url
          elif .id and .workspace_id then "\($app)/\($ws)/issues/\(.id)"
          else null end
        )
      } ]
  ' "$json_in" > "$json_out"
}

# 输出格式：默认对齐列的表格；--json 时给原 JSON + web_url 字段
render_table() {
  local file="$1"
  $JQ -r '
    ["IDENTIFIER","STATUS","PRIORITY","ASSIGNEE","UPDATED","TITLE"] as $h |
    ($h | @tsv),
    (.[] | [
      (.identifier // "-"),
      (.status // "-"),
      (.priority // "-"),
      (if .assignee_type and .assignee_id then "\(.assignee_type)/\(.assignee_id[0:8])"
       else "-" end),
      ((.updated_at // "-") | sub("T"; " ")),
      (.title // "-")
    ] | @tsv)
  ' "$file" | column -t -s $'\t'
}

# 简易输出模式（v0.4.1 加）：
#   --count-only  只打 count（避免用 jq select(...) 误读总数）
#   --ids-only    只打 identifier 列表（一行一个），可走 xargs / awk / grep
# 这两个开关和 --json / render_table 互斥；后者优先级最高（带 --json 时 count/ids-only 失效）
print_count() {
  local file="$1"
  $JQ 'length' "$file"
}
print_ids() {
  local file="$1"
  $JQ -r '.[] | (.identifier // "?")' "$file"
}

case "$SUBCMD" in
  list)
    if [[ -n "$Q" ]]; then
      HTTP=$(fetch_search) || true
    else
      HTTP=$(fetch_issues) || true
    fi
    if [[ "$HTTP" != "200" ]]; then
      cat $TMP_DIR/resp.json >&2 || true
      rm -f $TMP_DIR/resp.json "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
      die "GET issues returned HTTP $HTTP"
    fi

    # 解析为数组（list / search 都返回数组）
    RESP=$TMP_DIR/pretty.json
    $JQ '[.issues[]?] | map(select(.id))' $TMP_DIR/resp.json > "$RESP" || true

    COUNT=$($JQ 'length' "$RESP")
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      attach_web_url "$RESP" $TMP_DIR/out.json
      cat $TMP_DIR/out.json
    elif [[ "$COUNT_ONLY" == "true" ]]; then
      print_count "$RESP"
    elif [[ "$IDS_ONLY" == "true" ]]; then
      print_ids "$RESP"
    else
      echo "Returned $COUNT issue(s)"
      echo ""
      if [[ "$COUNT" -gt 0 ]]; then
        render_table "$RESP"
      fi
    fi
    ;;

  search)
    HTTP=$(fetch_search) || true
    if [[ "$HTTP" != "200" ]]; then
      cat $TMP_DIR/resp.json >&2 || true
      rm -f $TMP_DIR/resp.json "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
      die "GET /api/issues/search returned HTTP $HTTP"
    fi
    RESP=$TMP_DIR/pretty.json
    $JQ '[.issues[]?] | map(select(.id))' $TMP_DIR/resp.json > "$RESP" || true

    COUNT=$($JQ 'length' "$RESP")
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      attach_web_url "$RESP" $TMP_DIR/out.json
      cat $TMP_DIR/out.json
    elif [[ "$COUNT_ONLY" == "true" ]]; then
      print_count "$RESP"
    elif [[ "$IDS_ONLY" == "true" ]]; then
      print_ids "$RESP"
    else
      echo "Search \"$Q\" returned $COUNT issue(s)"
      echo ""
      if [[ "$COUNT" -gt 0 ]]; then
        render_table "$RESP"
      fi
    fi
    ;;

  get)
    # 判断 identifier 还是 uuid：
    #   后端 `GET /api/issues/{id_or_identifier}` 两种都直接拿，所以这里只要做一个简单验证后直接拿
    RESOLVED_ID=""
    if [[ "$TARGET" =~ ^[A-Za-z][A-Za-z0-9_-]*-[0-9]+$ ]] \
       || [[ "$TARGET" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      RESOLVED_ID="$TARGET"
    else
      die "TARGET \"$TARGET\" is neither <PREFIX>-<N> nor a UUID"
    fi

    URL="$SERVER_URL/api/issues/$RESOLVED_ID"
    [[ -n "$WORKSPACE_ID" ]] && URL+="?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
    HTTP=$(curl -sS -o $TMP_DIR/resp.json -w "%{http_code}" \
      -H "@$AUTH_HEADER_FILE" \
      -H "X-Client-Platform: multica-cli-skill" \
      -H "X-Client-Version: 0.1.0" \
      -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')" \
      ${WORKSPACE_ID:+-H "X-Workspace-ID: $WORKSPACE_ID"} \
      "$URL" || echo "000")
    if [[ "$HTTP" != "200" ]]; then
      cat $TMP_DIR/resp.json >&2 || true
      rm -f $TMP_DIR/resp.json "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
      die "GET /api/issues/$RESOLVED_ID returned HTTP $HTTP"
    fi

    if [[ "$OUTPUT_JSON" == "true" ]]; then
      $JQ --arg url "$APP_URL/${WORKSPACE_PATH_SEG:-${WORKSPACE_ID:-}}/issues/$($JQ -r '.id' $TMP_DIR/resp.json)" \
        '. + {web_url: $url}' $TMP_DIR/resp.json
    else
      $JQ -r --arg path_seg "${WORKSPACE_PATH_SEG:-${WORKSPACE_ID:-}}" '
        "Identifier:  \(.identifier // "-")  (id: \(.id // "-"))",
        "Title:       \(.title // "-")",
        "Status:      \(.status // "-")",
        "Priority:    \(.priority // "-")",
        "Assignee:    \(if .assignee_type then "\(.assignee_type) \(.assignee_id // "-")" else "-" end)",
        "Creator:     \(.creator_type // "-")  \(.creator_id // "-")",
        "Project:     \(.project_id // "-")",
        "Created:     \(.created_at // "-")",
        "Updated:     \((.updated_at // "-") | sub("T"; " "))",
        "Web URL:     \($app_url)/\($path_seg)/issues/\(.id)"
      ' --arg app_url "$APP_URL" $TMP_DIR/resp.json
    fi
    ;;
esac

rm -f $TMP_DIR/resp.json $TMP_DIR/pretty.json $TMP_DIR/out.json \
      "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
