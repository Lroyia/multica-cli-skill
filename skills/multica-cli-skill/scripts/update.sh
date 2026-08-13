#!/usr/bin/env bash
# multica-cli-skill / update.sh: 修改工单字段（status / priority / assignee / project / title / description）
#
# 用法:
#   update.sh <id-or-identifier> [选项]
#
# 必填 positional:
#   <id-or-identifier>      工单标识。形如 LRO-37 或 UUID；后端 /api/issues/{x} 同时接。
#
# 可修改字段（至少给一个）：
#   --status backlog|todo|in_progress|in_review|done|blocked|cancelled
#   --priority urgent|high|medium|low|none
#   --assignee-type member|agent|squad --assignee-id UUID
#   --assignee "前端组" | "老王"          # 按名字 fuzzy match squad→agent→member
#   --squad    "前端组"                   # 强制 squad
#   --agent    "xiaoming"                 # 强制 agent
#   --member   "老王"                     # 强制 member；email 也参与匹配
#   --project-id UUID
#   --project "支付重构"                  # 按项目名 fuzzy match /api/projects
#   --title TEXT
#   --description TEXT
#   --json '{"k":"v",...}'                # 原始 body（escape hatch，跳过白名单校验）
#
# 输出 / 控制:
#   --json-output      以 JSON 形式输出更新后的完整 issue（含 web_url）
#   --dry-run          只打印 diff 与将要发送的 body，不真的发请求
#   --yes              跳过确认（默认会问 Continue? [y/N]）
#   --config <path>    覆盖 config.json 路径
#   --server-url URL
#   --app-url URL
#   --workspace-id UUID
#
# 前置依赖: curl, jq, uname
# 凭证来源: 与 order.sh / list.sh 一致（$MULTICA_TOKEN > config.json）

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

TARGET=""
STATUS=""
PRIORITY=""
ASSIGNEE_TYPE=""
ASSIGNEE_ID=""
ASSIGNEE_NAME=""
SQUAD_NAME=""
AGENT_NAME=""
MEMBER_NAME=""
PROJECT_ID=""
PROJECT_NAME=""
TITLE_NEW=""
DESCRIPTION_NEW=""
RAW_JSON=""
CONFIG_PATH=""
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""
OUTPUT_JSON="false"
DRY_RUN="false"
ASSUME_YES="false"

# ---- 白名单 ----
ALLOWED_STATUSES=(backlog todo in_progress in_review done blocked cancelled)
ALLOWED_PRIORITIES=(urgent high medium low none)
ALLOWED_ASSIGNEE_TYPES=(member agent squad)

usage() { sed -n '2,46p' "$0"; }
die()   { echo "ERROR: $*" >&2; exit 1; }

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

# ---- 参数解析 ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --status)        STATUS="$2"; shift 2;;
    --priority)      PRIORITY="$2"; shift 2;;
    --assignee-type) ASSIGNEE_TYPE="$2"; shift 2;;
    --assignee-id)   ASSIGNEE_ID="$2"; shift 2;;
    --assignee)      ASSIGNEE_NAME="$2"; shift 2;;
    --squad)         SQUAD_NAME="$2"; shift 2;;
    --agent)         AGENT_NAME="$2"; shift 2;;
    --member)        MEMBER_NAME="$2"; shift 2;;
    --project-id)    PROJECT_ID="$2"; shift 2;;
    --project)       PROJECT_NAME="$2"; shift 2;;
    --title)         TITLE_NEW="$2"; shift 2;;
    --description)   DESCRIPTION_NEW="$2"; shift 2;;
    --json)          RAW_JSON="$2"; shift 2;;
    --config)        CONFIG_PATH="$2"; shift 2;;
    --server-url)    SERVER_URL_OVERRIDE="$2"; shift 2;;
    --app-url)       APP_URL_OVERRIDE="$2"; shift 2;;
    --workspace-id)  WORKSPACE_ID_OVERRIDE="$2"; shift 2;;
    --json-output)   OUTPUT_JSON="true"; shift;;
    --dry-run)       DRY_RUN="true"; shift;;
    --yes|-y)        ASSUME_YES="true"; shift;;
    -h|--help)       usage; exit 0;;
    --*)             die "unknown flag: $1";;
    *)
      if [[ -z "$TARGET" ]]; then TARGET="$1"; shift
      else die "unexpected positional arg: $1 (only one target allowed)"
      fi
      ;;
  esac
done

[[ -z "$TARGET" ]] && die "usage: update.sh <id-or-identifier> [--status S] [--priority P] [--assignee ...] [--project ...] [--title T] [--description D] [--json '{...}'] [--yes] [--dry-run]"

# ---- 白名单校验 ----
contains() { local needle="$1"; shift; for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done; return 1; }

if [[ -n "$STATUS" ]]; then
  contains "$STATUS" "${ALLOWED_STATUSES[@]}" || die "--status must be one of: ${ALLOWED_STATUSES[*]}"
fi
if [[ -n "$PRIORITY" ]]; then
  contains "$PRIORITY" "${ALLOWED_PRIORITIES[@]}" || die "--priority must be one of: ${ALLOWED_PRIORITIES[*]}"
fi
if [[ -n "$ASSIGNEE_TYPE" ]]; then
  contains "$ASSIGNEE_TYPE" "${ALLOWED_ASSIGNEE_TYPES[@]}" || die "--assignee-type must be one of: ${ALLOWED_ASSIGNEE_TYPES[*]}"
fi
if [[ -n "$ASSIGNEE_ID$ASSIGNEE_NAME$SQUAD_NAME$AGENT_NAME$MEMBER_NAME" ]]; then
  if [[ -n "$ASSIGNEE_TYPE$ASSIGNEE_ID" && -n "$ASSIGNEE_NAME$SQUAD_NAME$AGENT_NAME$MEMBER_NAME" ]]; then
    die "Use either --assignee-type/--assignee-id or --assignee/--squad/--agent/--member, not both"
  fi
  if [[ -n "$ASSIGNEE_TYPE" && -z "$ASSIGNEE_ID" ]] || [[ -z "$ASSIGNEE_TYPE" && -n "$ASSIGNEE_ID" ]]; then
    die "--assignee-type and --assignee-id must be given together"
  fi
fi
if [[ -n "$PROJECT_ID" && -n "$PROJECT_NAME" ]]; then
  die "Use either --project-id or --project, not both"
fi

# ---- 凭证解析（默认读取 Multica CLI home 配置）----
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

# ---- HTTP 工具 ----
api_get() {
  local path="$1" outfile="$2"
  local url="$SERVER_URL$path"
  if [[ -n "$WORKSPACE_ID" ]]; then
    url="$url?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  fi
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
api_put() {
  local path="$1" body="$2" outfile="$3"
  local url="$SERVER_URL$path"
  if [[ -n "$WORKSPACE_ID" ]]; then
    url="$url?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
  fi
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

# ---- /api/me 校验 ----
ME_HTTP=$(api_get "/api/me" $TMP_DIR/me.json)
if [[ "$ME_HTTP" != "200" ]]; then
  cat $TMP_DIR/me.json >&2 || true
  rm -f $TMP_DIR/me.json
  die "/api/me returned HTTP $ME_HTTP - token invalid or expired."
fi
rm -f $TMP_DIR/me.json

# ---- 解析 TARGET：identifier or UUID ----
RESOLVED_ID=""
if [[ "$TARGET" =~ ^[A-Za-z][A-Za-z0-9_-]*-[0-9]+$ ]] \
   || [[ "$TARGET" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  RESOLVED_ID="$TARGET"
else
  die "TARGET \"$TARGET\" is neither <PREFIX>-<N> nor a UUID"
fi

# ---- 取当前 issue（用于 diff + workspace slug）----
ISSUE_FILE=$TMP_DIR/issue.json
GET_HTTP=$(api_get "/api/issues/$RESOLVED_ID" "$ISSUE_FILE")
if [[ "$GET_HTTP" != "200" ]]; then
  cat "$ISSUE_FILE" >&2 || true
  rm -f "$ISSUE_FILE"
  die "GET /api/issues/$RESOLVED_ID returned HTTP $GET_HTTP"
fi

# workspace 路径段（slug → name → id 三层回退，与 list.sh 同款）
SEG_FILE="$TMP_DIR/workspace-path-seg"
if [[ -n "$WORKSPACE_ID" ]]; then
  SEG=""
  if command -v multica >/dev/null 2>&1; then
    SEG=$(multica workspace list --output json 2>/dev/null \
      | $JQ -r --arg id "$WORKSPACE_ID" '
          if type == "array" then (.[] | select(.id == $id) | (.slug // .name // empty))
          elif (.workspaces // null) != null then (.workspaces[] | select(.id == $id) | (.slug // .name // empty))
          else empty end
        ' | head -n1 || true)
  fi
  if [[ -z "$SEG" ]]; then
    local_resp="$(curl -sS -H "@$AUTH_HEADER_FILE" \
      "$SERVER_URL/api/workspaces/$WORKSPACE_ID" 2>/dev/null || true)"
    if [[ -n "$local_resp" ]] && [[ "$(echo "$local_resp" | $JQ -r '.id // empty')" == "$WORKSPACE_ID" ]]; then
      SEG="$(echo "$local_resp" | $JQ -r '.slug // .name // empty')"
    fi
  fi
  if [[ -n "$SEG" ]]; then
    printf '%s' "$SEG" > "$SEG_FILE"
  else
    printf '%s' "$WORKSPACE_ID" > "$SEG_FILE"
    echo "WARN: 无法从 CLI 或 API 反查 workspace slug/name，URL 将使用 workspace_id。" >&2
  fi
fi
WORKSPACE_PATH_SEG="$(cat "$SEG_FILE" 2>/dev/null || true)"

# ---- 名称 fuzzy match（与 order.sh 一致的打分函数）----
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
  in_noh=$(printf '%s' "$lc_in"  | tr -d ' -_')
  hay_noh=$(printf '%s' "$lc_hay" | tr -d ' -_')
  if [[ -n "$in_noh" && "$hay_noh" == *"$in_noh"* ]]; then echo 50; return; fi
  echo 0
}
pick_best() {
  local name_field="$1" id_field="$2" input="$3" file="$4"
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
}

# ---- 按需拉 squads / agents / members / projects ----
SQUADS_FILE=$TMP_DIR/squads.json
AGENTS_FILE=$TMP_DIR/agents.json
MEMBERS_FILE=$TMP_DIR/members.json
PROJECTS_FILE=$TMP_DIR/projects.json
rm -f "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"

need_squads=false; need_agents=false; need_members=false; need_projects=false
[[ -n "$ASSIGNEE_NAME" ]] && need_squads=true && need_agents=true && need_members=true
[[ -n "$SQUAD_NAME"    ]] && need_squads=true
[[ -n "$AGENT_NAME"    ]] && need_agents=true
[[ -n "$MEMBER_NAME"   ]] && need_members=true
[[ -n "$PROJECT_NAME"  ]] && need_projects=true

# fetch_list <api_path> <out_file> [wrapper_key]
#   默认期望响应是裸数组。/api/projects 返回 {"projects":[...], "total":N}，传 "projects" 自动解包。
fetch_list() {
  local path="$1" outfile="$2" wrapper_key="${3:-}"
  local h; h=$(api_get "$path" "$outfile")
  [[ "$h" == "200" ]] || { cat "$outfile" >&2 || true; rm -f "$outfile"; die "GET $path returned HTTP $h"; }
  if [[ -n "$wrapper_key" ]]; then
    if ! $JQ -e --arg k "$wrapper_key" '
        (type == "object") and ((.[$k] | type) == "array")
      ' "$outfile" >/dev/null 2>&1; then
      die "GET $path 返回的 shape 不是预期包裹对象（缺少 .$wrapper_key 数组）。请查看 $outfile"
    fi
    $JQ --arg k "$wrapper_key" '.[$k]' "$outfile" > "$outfile.tmp" && mv "$outfile.tmp" "$outfile"
  fi
}
if [[ "$need_squads" == "true" ]]; then fetch_list "/api/squads" "$SQUADS_FILE"; fi
if [[ "$need_agents" == "true" ]]; then fetch_list "/api/agents" "$AGENTS_FILE"; fi
if [[ "$need_members" == "true" ]]; then
  [[ -z "$WORKSPACE_ID" ]] && die "--assignee/--member requires workspace_id in config or --workspace-id"
  fetch_list "/api/workspaces/$WORKSPACE_ID/members" "$MEMBERS_FILE"
fi
if [[ "$need_projects" == "true" ]]; then fetch_list "/api/projects" "$PROJECTS_FILE" "projects"; fi

# ---- 解析 assignee / project 名 → UUID ----
if [[ -n "$ASSIGNEE_NAME" ]]; then
  found=""
  for kind in squad agent member; do
    case "$kind" in
      squad)
        [[ -f "$SQUADS_FILE" ]] && found=$(pick_best "name" "id" "$ASSIGNEE_NAME" "$SQUADS_FILE") && [[ -n "$found" ]] && { ASSIGNEE_ID="$found"; ASSIGNEE_TYPE="squad"; break; }
        ;;
      agent)
        [[ -f "$AGENTS_FILE" ]] && found=$(pick_best "name" "id" "$ASSIGNEE_NAME" "$AGENTS_FILE") && [[ -n "$found" ]] && { ASSIGNEE_ID="$found"; ASSIGNEE_TYPE="agent"; break; }
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
                    else 0 end ) }
              | select(.score > 0)
            ] | sort_by(-.score, .idx) | if length == 0 then empty else .[0].id end
          ' "$MEMBERS_FILE" | head -n1 || true)
          [[ -n "$found" ]] && { ASSIGNEE_ID="$found"; ASSIGNEE_TYPE="member"; }
        fi
        ;;
    esac
  done
  [[ -z "$ASSIGNEE_ID" ]] && die "no squad/agent/member matched \"$ASSIGNEE_NAME\""
fi
if [[ -n "$SQUAD_NAME" ]]; then
  [[ -f "$SQUADS_FILE" ]] || die "--squad requires /api/squads"
  ASSIGNEE_ID=$(pick_best "name" "id" "$SQUAD_NAME" "$SQUADS_FILE")
  [[ -n "$ASSIGNEE_ID" ]] || die "no squad matched \"$SQUAD_NAME\""
  ASSIGNEE_TYPE="squad"
fi
if [[ -n "$AGENT_NAME" ]]; then
  [[ -f "$AGENTS_FILE" ]] || die "--agent requires /api/agents"
  ASSIGNEE_ID=$(pick_best "name" "id" "$AGENT_NAME" "$AGENTS_FILE")
  [[ -n "$ASSIGNEE_ID" ]] || die "no agent matched \"$AGENT_NAME\""
  ASSIGNEE_TYPE="agent"
fi
if [[ -n "$MEMBER_NAME" ]]; then
  [[ -f "$MEMBERS_FILE" ]] || die "--member requires members list"
  found=$($JQ -r --arg n "$MEMBER_NAME" '
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
            else 0 end ) }
      | select(.score > 0)
    ] | sort_by(-.score, .idx) | if length == 0 then empty else .[0].id end
  ' "$MEMBERS_FILE" | head -n1 || true)
  [[ -n "$found" ]] || die "no member matched \"$MEMBER_NAME\""
  ASSIGNEE_ID="$found"; ASSIGNEE_TYPE="member"
fi
if [[ -n "$PROJECT_NAME" ]]; then
  [[ -f "$PROJECTS_FILE" ]] || die "--project requires projects list"
  PROJECT_ID=$(pick_best "title" "id" "$PROJECT_NAME" "$PROJECTS_FILE")
  [[ -n "$PROJECT_ID" ]] || die "no project matched \"$PROJECT_NAME\""
fi

# ---- 构造 PUT body ----
# 规则：--arg 传进来的空字符串在 jq 里是 "" 而不是 null；
# 用 `with_entries(select(.value != null and .value != ""))` 一次性把空字段去掉。
BODY_FILE=$TMP_DIR/body.json
if [[ -n "$RAW_JSON" ]]; then
  echo "$RAW_JSON" | $JQ . > "$BODY_FILE" 2>/dev/null || die "--json 传的不是合法 JSON"
else
  $JQ -n \
    --arg status        "$STATUS" \
    --arg priority      "$PRIORITY" \
    --arg assignee_id   "$ASSIGNEE_ID" \
    --arg assignee_type "$ASSIGNEE_TYPE" \
    --arg project_id    "$PROJECT_ID" \
    --arg title         "$TITLE_NEW" \
    --arg description   "$DESCRIPTION_NEW" \
    '{
      status:        $status,
      priority:      $priority,
      assignee_id:   $assignee_id,
      assignee_type: $assignee_type,
      project_id:    $project_id,
      title:         $title,
      description:   $description
    } | with_entries(select(.value != null and .value != ""))' \
    > "$BODY_FILE"
fi

BODY="$(cat "$BODY_FILE")"
KEYS=$(echo "$BODY" | $JQ -r 'keys | join(",")')
[[ -z "$KEYS" || "$KEYS" == "" ]] && die "no field to update. Pass at least one of --status / --priority / --assignee* / --project* / --title / --description / --json"

# ---- 取当前值（diff）----
CUR_STATUS=$($JQ -r '.status // "-"   ' "$ISSUE_FILE")
CUR_PRIORITY=$($JQ -r '.priority // "-"' "$ISSUE_FILE")
CUR_ASSIGNEE_TYPE=$($JQ -r '.assignee_type // "-"' "$ISSUE_FILE")
CUR_ASSIGNEE_ID=$($JQ -r '.assignee_id // "-"' "$ISSUE_FILE")
CUR_PROJECT_ID=$($JQ -r '.project_id // "-"' "$ISSUE_FILE")
CUR_TITLE=$($JQ -r '.title // "-"' "$ISSUE_FILE")
CUR_DESC_LEN=$($JQ -r '.description // "" | length' "$ISSUE_FILE")

echo "Target: $($JQ -r '"\(.identifier // "?")  (id: \(.id // "?"))"' "$ISSUE_FILE")"
echo "Title:  $CUR_TITLE"
echo
echo "Pending changes:"
echo "$BODY" | $JQ -r '
  to_entries | .[] |
  "  " + .key + ":  →  " +
    (if .key == "status"        then (.value | tostring)
     elif .key == "priority"     then (.value | tostring)
     elif .key == "assignee_id"  then .value
     elif .key == "assignee_type" then .value
     elif .key == "project_id"   then .value
     elif .key == "title"        then (.value | tostring)
     elif .key == "description"  then ("(" + ((.value | length | tostring)) + " chars)")
     else (.value | tostring)
     end)
'
echo
echo "Diff (before → after):"
echo "$BODY" | $JQ -r --arg cur_status "$CUR_STATUS" --arg cur_priority "$CUR_PRIORITY" \
                       --arg cur_aid "$CUR_ASSIGNEE_ID" --arg cur_atype "$CUR_ASSIGNEE_TYPE" \
                       --arg cur_pid "$CUR_PROJECT_ID" --arg cur_title "$CUR_TITLE" \
                       --argjson cur_desc_len "$CUR_DESC_LEN" '
  to_entries | .[] |
  "  " + .key + ":  " +
    (if .key == "status"         then $cur_status   + " → " + (.value | tostring)
     elif .key == "priority"     then $cur_priority + " → " + (.value | tostring)
     elif .key == "assignee_id"  then $cur_aid      + " → " + .value
     elif .key == "assignee_type" then $cur_atype    + " → " + .value
     elif .key == "project_id"   then $cur_pid      + " → " + .value
     elif .key == "title"        then $cur_title    + " → " + (.value | tostring)
     elif .key == "description"  then ($cur_desc_len|tostring) + " chars → " + ((.value | length|tostring)) + " chars"
     else "(unknown)" end)
'

# status 反向移动警告（done → 其他 / in_review → backlog）
if [[ -n "$STATUS" ]]; then
  CUR_STATUS=$($JQ -r '.status // ""' "$ISSUE_FILE")
  if [[ "$CUR_STATUS" == "done" && "$STATUS" != "done" ]]; then
    echo
    echo "WARN: 正在把 done 工单改回 \"$STATUS\"，请确认确实是要 reopen。"
  fi
  if [[ "$CUR_STATUS" == "in_review" && "$STATUS" == "backlog" ]]; then
    echo
    echo "WARN: 正在把 in_review 工单踢回 backlog（基本等于"撤销评审"），请确认。"
  fi
fi

echo
echo "Body:"
echo "$BODY" | $JQ .

# ---- 确认 ----
if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "(dry-run, no request sent)"
  exit 0
fi

if [[ "$ASSUME_YES" != "true" ]]; then
  # 始终从 stdin 读，避免 in-pipeline 阻塞
  if [[ -t 0 ]]; then
    read -r -p "Apply? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "Aborted."; exit 130;;
    esac
  else
    echo "(non-interactive stdin; pass --yes to confirm)" >&2
    exit 64
  fi
fi

# ---- 发送 PUT ----
echo
echo "→ PUT /api/issues/$RESOLVED_ID"
RESP=$TMP_DIR/resp.json
HTTP=$(api_put "/api/issues/$RESOLVED_ID" "$BODY" "$RESP")
if [[ "$HTTP" != "200" ]]; then
  echo "HTTP $HTTP" >&2
  cat "$RESP" >&2 || true
  rm -f "$RESP" "$BODY_FILE" "$ISSUE_FILE" "$SEG_FILE" "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
  exit 1
fi

if [[ "$OUTPUT_JSON" == "true" ]]; then
  $JQ --arg app "$APP_URL" --arg seg "${WORKSPACE_PATH_SEG:-${WORKSPACE_ID:-}}" \
    '. + {web_url: "\($app)/\($seg)/issues/\(.id)"}' "$RESP"
else
  $JQ -r --arg app "$APP_URL" --arg seg "${WORKSPACE_PATH_SEG:-${WORKSPACE_ID:-}}" '
    "Identifier:  \(.identifier // "-")  (id: \(.id // "-"))",
    "Title:       \(.title // "-")",
    "Status:      \(.status // "-")",
    "Priority:    \(.priority // "-")",
    "Assignee:    \(if .assignee_type then "\(.assignee_type) \(.assignee_id // "-")" else "-" end)",
    "Project:     \(.project_id // "-")",
    "Updated:     \((.updated_at // "-") | sub("T"; " "))",
    "Web URL:     \($app)/\($seg)/issues/\(.id)"
  ' "$RESP"
fi

rm -f "$RESP" "$BODY_FILE" "$ISSUE_FILE" "$SEG_FILE" "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"