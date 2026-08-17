#!/usr/bin/env bash
# multica-cli-skill: 读取用户的 ~/.multica/config.json，直接调 /api/issues 下单 + 自动匹配 squad/agent/member/project
#
# 用法:
#   order.sh --title "..." [选项]
#
# 必填:
#   --title TEXT                       issue 标题
#
# 内容（可选）:
#   --description TEXT                 markdown 正文
#   --priority urgent|high|medium|low|none
#   --status backlog|todo|in_progress|in_review|done|blocked|cancelled
#   --due-date YYYY-MM-DD
#   --label-ids u1,u2,...
#   --parent-issue-id UUID             子 issue 用
#   --allow-duplicate
#
# 附件（可选，v0.13 新增）:
#   --attachment <path>                可重复；multipart 上传到 /api/upload-file，不绑 issue_id
#   --attachment-ids u1,u2,...         复用已上传的附件（先 attachments.sh upload 拿 uuid）
#   --no-embed                         跳过把附件 markdown 追加到 description
#   默认会按 --attachment / --attachment-ids 顺序把 ![name](md_url) / !file[name](md_url) 拼到 description 末尾
#
# 负责人（4 选 1，优先级从高到低）:
#   --assignee-type member|agent|squad --assignee-id UUID
#   --assignee "前端组" | "老王" | "@xiaoming"     # 按名字自动匹配 squad→agent→member
#   --squad  "前端组"                              # 强制按小队匹配
#   --agent  "xiaoming"                            # 强制按 agent 匹配
#   --member "老王"                                # 强制按 member 匹配
#
# 项目（2 选 1）:
#   --project-id UUID
#   --project  "支付重构"           # 按项目名匹配 /api/projects
#
# 连接（可选）:
#   --config <path>                  显式指定 config.json
#   --server-url URL                 覆盖 config 里的 server_url
#   --app-url URL                    覆盖 config 里的 app_url
#   --workspace-id UUID              覆盖 config 里的 workspace_id
#
# 输出:
#   --json                           以 JSON 形式输出（含 web_url）
#   --dry-run                        只打印将要发出的请求，不真的下单
#   --strict-match                   auto-match 只接受完全相同的名字，否则报错
#
# 前置依赖: curl, jq, uname
#
# 凭证来源（配置文件路径解析，从高到低优先级）:
#   1) --config <path> 指定的文件
#   2) <skill_dir>/config.json（脚本所在 skill 目录的本地 config.json）
#   3) $MULTICA_CLI_ORDER_CONFIG 环境变量指向的文件
#   4) ~/.multica/config.json（由 multica login 写入）
#   然后再应用：
#   5) $MULTICA_TOKEN 覆盖配置文件里的 token
#   6) --server-url / --app-url / --workspace-id 覆盖对应字段
#
# 本 skill 只读 CLI 配置，不会改写或回显配置文件内容。

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

TITLE=""
DESCRIPTION=""
PRIORITY=""
STATUS=""
ASSIGNEE_TYPE=""
ASSIGNEE_ID=""
ASSIGNEE_NAME=""     # 自由文本，自动匹配
SQUAD_NAME=""        # 强制按 squad 匹配
AGENT_NAME=""        # 强制按 agent 匹配
MEMBER_NAME=""       # 强制按 member 匹配
PROJECT_ID=""
PROJECT_NAME=""      # 项目名自动匹配
PARENT_ISSUE_ID=""
DUE_DATE=""
LABEL_IDS_CSV=""
ATTACHMENT_PATHS=()           # v0.13：待上传的本地文件路径
ATTACHMENT_IDS_CSV=""         # v0.13：已上传附件 UUID，逗号分隔
EMBED_MARKDOWN="true"         # v0.13：是否把附件 markdown 追加到 description
CONFIG_PATH=""
CONFIG_PATH_IS_DEFAULT="false"
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""
OUTPUT_JSON="false"
ALLOW_DUPLICATE="false"
DRY_RUN="false"
STRICT_MATCH="false"

usage() {
  sed -n '2,42p' "$0"
}

die() { echo "ERROR: $*" >&2; exit 1; }

umask 077
TMP_DIR="$(mktemp -d /tmp/multica-cli-skill.XXXXXX)" || die "failed to create private temp directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

# 解析脚本所在的 skill 目录（父目录的父目录）
# order.sh 位于 <skill_dir>/scripts/order.sh，所以 SKILL_DIR = dirname(dirname(order.sh))
SKILL_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
SKILL_DIR_CONFIG="$SKILL_DIR/config.json"

resolve_config_path() {
  # 1) --config 显式指定（最高优先级）
  [[ -n "$CONFIG_PATH" ]] && return
  # 2) <skill_dir>/config.json（本地 config，便于自包含部署 / 测试）
  if [[ -f "$SKILL_DIR_CONFIG" ]]; then
    CONFIG_PATH="$SKILL_DIR_CONFIG"
    CONFIG_PATH_IS_DEFAULT="true"   # 标记为"未显式传 --config"以便报错时给出更友好的提示
    return
  fi
  # 3) $MULTICA_CLI_ORDER_CONFIG 环境变量
  if [[ -n "${MULTICA_CLI_ORDER_CONFIG:-}" ]]; then
    CONFIG_PATH="$MULTICA_CLI_ORDER_CONFIG"
    return
  fi
  # 4) ~/.multica/config.json（multica login 默认写入）
  local home="${HOME:-${USERPROFILE:-}}"
  [[ -n "$home" ]] || die "HOME is not set. Set HOME (or USERPROFILE on Windows), or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  home="$(printf '%s' "$home" | tr '\134' '/')"
  CONFIG_PATH="$home/.multica/config.json"
  CONFIG_PATH_IS_DEFAULT="true"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)            TITLE="$2"; shift 2;;
    --description)      DESCRIPTION="$2"; shift 2;;
    --priority)         PRIORITY="$2"; shift 2;;
    --status)           STATUS="$2"; shift 2;;
    --assignee-type)    ASSIGNEE_TYPE="$2"; shift 2;;
    --assignee-id)      ASSIGNEE_ID="$2"; shift 2;;
    --assignee)         ASSIGNEE_NAME="$2"; shift 2;;
    --squad)            SQUAD_NAME="$2"; shift 2;;
    --agent)            AGENT_NAME="$2"; shift 2;;
    --member)           MEMBER_NAME="$2"; shift 2;;
    --project-id)       PROJECT_ID="$2"; shift 2;;
    --project)          PROJECT_NAME="$2"; shift 2;;
    --parent-issue-id)  PARENT_ISSUE_ID="$2"; shift 2;;
    --due-date)         DUE_DATE="$2"; shift 2;;
    --label-ids)        LABEL_IDS_CSV="$2"; shift 2;;
    --attachment)       ATTACHMENT_PATHS+=("$2"); shift 2;;
    --attachment-ids)   ATTACHMENT_IDS_CSV="$2"; shift 2;;
    --no-embed)         EMBED_MARKDOWN="false"; shift;;
    --config)           CONFIG_PATH="$2"; shift 2;;
    --server-url)       SERVER_URL_OVERRIDE="$2"; shift 2;;
    --app-url)          APP_URL_OVERRIDE="$2"; shift 2;;
    --workspace-id)     WORKSPACE_ID_OVERRIDE="$2"; shift 2;;
    --allow-duplicate)  ALLOW_DUPLICATE="true"; shift;;
    --json)             OUTPUT_JSON="true"; shift;;
    --dry-run)          DRY_RUN="true"; shift;;
    --strict-match)     STRICT_MATCH="true"; shift;;
    -h|--help)          usage; exit 0;;
    *) die "unknown arg: $1";;
  esac
done

# v0.7：必填项校验（title / description / assignee / project）
[[ -z "$TITLE"       ]] && die "--title is required"
[[ -z "$DESCRIPTION" ]] && die "--description is required (issue 正文); 不想写就传 \" \" 或简单描述"

# 互斥检查：type+id 与 auto-match 不能同时给
if [[ -n "$ASSIGNEE_TYPE" || -n "$ASSIGNEE_ID" ]]; then
  [[ -n "$ASSIGNEE_NAME$SQUAD_NAME$AGENT_NAME$MEMBER_NAME" ]] && \
    die "Use either --assignee-type/--assignee-id or --assignee/--squad/--agent/--member, not both"
fi

# 必填：assignee（4 选 1：--assignee-type+id / --assignee / --squad / --agent / --member）
if [[ -z "$ASSIGNEE_TYPE$ASSIGNEE_ID$ASSIGNEE_NAME$SQUAD_NAME$AGENT_NAME$MEMBER_NAME" ]]; then
  die "assignee is required. Pass one of:
   --assignee-type member|agent|squad --assignee-id <uuid>      (显式 UUID)
   --assignee  \"<name>\"                                       (按名字 fuzzy match squad→agent→member)
   --squad     \"<name>\"                                       (强制 squad)
   --agent     \"<name>\"                                       (强制 agent)
   --member    \"<name>\"                                       (强制 member；user.email 也参与匹配)"
fi

# 必填：project（2 选 1：--project-id / --project）
if [[ -z "$PROJECT_ID$PROJECT_NAME" ]]; then
  die "project is required. Pass one of:
   --project-id <uuid>
   --project  \"<title>\"                                        (按名字 fuzzy match /api/projects)"
fi

if [[ -n "$PROJECT_ID" && -n "$PROJECT_NAME" ]]; then
  die "Use either --project-id or --project, not both"
fi

# v0.13：--attachment 本地文件必须存在
for p in "${ATTACHMENT_PATHS[@]}"; do
  [[ -f "$p" ]] || die "--attachment: file not found: $p"
done

# v0.13：--attachment-ids 预校验 UUID 格式（避免后续 server 端才报 422）
if [[ -n "$ATTACHMENT_IDS_CSV" ]]; then
  bad_ids=()
  IFS=',' read -r -a _ids <<< "$ATTACHMENT_IDS_CSV"
  for id in "${_ids[@]}"; do
    [[ -z "$id" ]] && continue
    if [[ ! "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
      bad_ids+=("$id")
    fi
  done
  if [[ ${#bad_ids[@]} -gt 0 ]]; then
    die "--attachment-ids contains invalid UUID: $(IFS=' '; echo "${bad_ids[*]}")"
  fi
fi

# ---- 1) 解析凭证（默认读取 Multica CLI home 配置）----
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

command -v /tmp/jq >/dev/null 2>&1 || command -v jq >/dev/null 2>&1 || die "jq is required to parse $CONFIG_PATH. Install jq first."
JQ="$(command -v /tmp/jq || command -v jq)"
TOKEN="$($JQ -r '.token       // empty' "$CONFIG_PATH")"
SERVER_URL="$($JQ -r '.server_url // empty' "$CONFIG_PATH")"
APP_URL="$($JQ   -r '.app_url    // empty' "$CONFIG_PATH")"
WORKSPACE_ID="$($JQ -r '.workspace_id // empty' "$CONFIG_PATH")"

# $MULTICA_TOKEN 总是最高优先级（覆盖 config.json 里的 token）
if [[ -n "${MULTICA_TOKEN:-}" ]]; then
  TOKEN="$MULTICA_TOKEN"
fi

# 命令行覆盖 config 里的 server_url / app_url / workspace_id
[[ -n "$SERVER_URL_OVERRIDE"   ]] && SERVER_URL="$SERVER_URL_OVERRIDE"
[[ -n "$APP_URL_OVERRIDE"      ]] && APP_URL="$APP_URL_OVERRIDE"
[[ -n "$WORKSPACE_ID_OVERRIDE" ]] && WORKSPACE_ID="$WORKSPACE_ID_OVERRIDE"

# 校验
[[ -z "$TOKEN"       ]] && die "missing token. Set MULTICA_TOKEN env, or write token into $CONFIG_PATH, or pass --config to a file with .token"
[[ -z "$SERVER_URL"  ]] && die "missing server_url. Set server_url in $CONFIG_PATH or pass --server-url"
SERVER_URL="${SERVER_URL%/}"
[[ -z "$APP_URL"     ]] && APP_URL="$SERVER_URL"
AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"

# 通用 HTTP 调用，写到指定路径，返回 HTTP code
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

# ---- v0.13 附件辅助 ----

# csv_to_json_array <csv>  →  echo "null"（空 csv）或 "[<uuid1>,<uuid2>...]"
# 与 scripts/comment.sh:350 保持一致
csv_to_json_array() {
  local csv="$1"
  if [[ -z "$csv" ]]; then
    echo "null"
  else
    $JQ -nc --arg s "$csv" '($s | split(",")) | map(select(. != ""))'
  fi
}

# upload_one_attachment <file_path>
#   → multipart POST /api/upload-file（不绑 issue_id）
#   → 解析响应 id / content_type / filename / markdown_url
#   → 写一行到 $TMP_DIR/uploaded_attachments.tsv: id<TAB>content_type<TAB>filename<TAB>markdown_url
#   → 在 stdout 输出对应 markdown snippet（图片 / 文件），供 bash 拼到 description
upload_one_attachment() {
  local file="$1"
  local out="$TMP_DIR/upload.json"
  local url
  url="$SERVER_URL/api/upload-file"
  [[ -n "$WORKSPACE_ID" ]] && url="$url?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"

  local args=(
    -sS -o "$out" -w "%{http_code}"
    -X POST
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.1.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
  )
  [[ -n "$WORKSPACE_ID" ]] && args+=(-H "X-Workspace-ID: $WORKSPACE_ID")
  args+=(-F "file=@${file}")

  local code
  code=$(curl "${args[@]}" "$url" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "POST /api/upload-file for '$file' returned HTTP $code"
  fi

  local id ctype filename md_url
  id=$($JQ -r '.id            // ""' "$out")
  ctype=$($JQ -r '.content_type // ""' "$out")
  filename=$($JQ -r '.filename     // ""' "$out")
  md_url=$($JQ -r '.markdown_url  // ""' "$out")
  rm -f "$out"

  if [[ -z "$id" || -z "$md_url" ]]; then
    die "POST /api/upload-file for '$file' returned an empty id or markdown_url"
  fi

  # 与 attachments.sh:312 保持一致的 label 转义
  local label
  label="$filename"
  label=$(echo "$label" | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g')

  local snippet
  if [[ "$ctype" == image/* ]]; then
    snippet="![${label}](${md_url})"
  else
    snippet="!file[${label}](${md_url})"
  fi

  # 持久化一条记录供后面拼 id 列表 + 输出
  printf '%s\t%s\t%s\t%s\n' "$id" "$ctype" "$filename" "$md_url" >> "$TMP_DIR/uploaded_attachments.tsv"
  printf '%s' "$snippet"
}

# fetch_one_attachment_meta <uuid>
#   → GET /api/attachments/{uuid} 拿 markdown_url + content_type
#   → 在 stdout 输出对应 markdown snippet；用 401/404 立刻 die
#   → 与 upload_one_attachment 共用 label 转义规则
fetch_one_attachment_meta() {
  local id="$1"
  local out="$TMP_DIR/att_meta.json"
  local url
  url="$SERVER_URL/api/attachments/${id}"
  [[ -n "$WORKSPACE_ID" ]] && url="$url?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"

  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.1.0" \
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$url" || echo "000")

  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "GET /api/attachments/$id returned HTTP $code (--attachment-ids 元信息拿不到，无法嵌入 markdown)"
  fi

  local ctype filename md_url
  ctype=$($JQ -r '.content_type // ""' "$out")
  filename=$($JQ -r '.filename    // ""' "$out")
  md_url=$($JQ -r '.markdown_url // ""' "$out")
  rm -f "$out"

  if [[ -z "$md_url" ]]; then
    die "GET /api/attachments/$id returned an empty markdown_url"
  fi

  local label
  label="$filename"
  label=$(echo "$label" | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g')

  local snippet
  if [[ "$ctype" == image/* ]]; then
    snippet="![${label}](${md_url})"
  else
    snippet="!file[${label}](${md_url})"
  fi

  printf '%s' "$snippet"
}

# ---- 2) /api/me 校验 ----
ME_HTTP=$(api_get "/api/me" $TMP_DIR/me.json)
if [[ "$ME_HTTP" != "200" ]]; then
  cat $TMP_DIR/me.json >&2 || true
  rm -f $TMP_DIR/me.json
  die "/api/me returned HTTP $ME_HTTP - token invalid or expired. Re-run 'multica login' or update $CONFIG_PATH.token with a permanent PAT."
fi
rm -f $TMP_DIR/me.json

# ---- 3) 取小队 / agent / member / project 列表（缓存）----
SQUADS_FILE=$TMP_DIR/squads.json
AGENTS_FILE=$TMP_DIR/agents.json
MEMBERS_FILE=$TMP_DIR/members.json
PROJECTS_FILE=$TMP_DIR/projects.json
rm -f "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"

# 这些列表只在下单方要求 auto-match 时才拉，避免无谓请求
need_squads=false
need_agents=false
need_members=false
need_projects=false
[[ -n "$ASSIGNEE_NAME" ]] && need_squads=true && need_agents=true && need_members=true
[[ -n "$SQUAD_NAME"    ]] && need_squads=true
[[ -n "$AGENT_NAME"    ]] && need_agents=true
[[ -n "$MEMBER_NAME"   ]] && need_members=true
[[ -n "$PROJECT_NAME"  ]] && need_projects=true

# fetch_list <api_path> <out_file> [wrapper_key]
#   拉取列表型接口的 JSON 响应并写到 out_file。
#   - 默认期望响应是裸数组（/api/squads、/api/agents 等都是这种）。
#   - 如果接口返回的是包装对象（如 /api/projects → {"projects":[...], "total":N}），
#     把 wrapper_key 传成数组字段名（"projects"），会自动解包成裸数组再写回。
#   - 解包前会校验 shape：必须是 "顶层对象 + 数组字段"，否则报错并提示人工排查。
fetch_list() {
  local path="$1" outfile="$2" wrapper_key="${3:-}"
  local http; http=$(api_get "$path" "$outfile")
  case "$http" in
    200) ;;
    *) cat "$outfile" >&2 || true; rm -f "$outfile"; die "GET $path returned HTTP $http";;
  esac
  if [[ -n "$wrapper_key" ]]; then
    if ! $JQ -e --arg k "$wrapper_key" '
        (type == "object") and ((.[$k] | type) == "array")
      ' "$outfile" >/dev/null 2>&1; then
      die "GET $path 返回的 shape 不是预期包裹对象（缺少 .$wrapper_key 数组）。请查看 $outfile"
    fi
    $JQ --arg k "$wrapper_key" '.[$k]' "$outfile" > "$outfile.tmp" && mv "$outfile.tmp" "$outfile"
  fi
}

# 名称匹配打分:
#   100: 完全相同（大小写敏感）
#    90: 完全相同（大小写不敏感）
#    70: 大小写不敏感子串匹配
#    50: 模糊：忽略空格/连字符后子串匹配
#    0: 不匹配
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
  # pick_best <jq_program_for_name> <jq_program_for_id> <input_name> <json_file>
  local name_field="$1" id_field="$2" input="$3" file="$4"
  if [[ "$STRICT_MATCH" == "true" ]]; then
    $JQ -r --arg n "$input" --arg nfield "$name_field" --arg ifield "$id_field" '
      [ .[]
        | { name: (.[$nfield] // ""), id: (.[$ifield] // "") }
        | select(.name == $n)
      ]
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

# 自动匹配负责人：按 squad → agent → member 优先级
resolve_assignee() {
  local query="$1"
  local found_type="" found_id=""

  for kind in squad agent member; do
    case "$kind" in
      squad)
        if [[ -f "$SQUADS_FILE" ]]; then
          local id; id=$(pick_best "name" "id" "$query" "$SQUADS_FILE")
          if [[ -n "$id" ]]; then found_type="squad"; found_id="$id"; break; fi
        fi
        ;;
      agent)
        if [[ -f "$AGENTS_FILE" ]]; then
          local id; id=$(pick_best "name" "id" "$query" "$AGENTS_FILE")
          if [[ -n "$id" ]]; then found_type="agent"; found_id="$id"; break; fi
        fi
        ;;
      member)
        if [[ -f "$MEMBERS_FILE" ]]; then
          local id; id=$($JQ -r --arg n "$query" '
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
          if [[ -n "$id" ]]; then found_type="member"; found_id="$id"; break; fi
        fi
        ;;
    esac
  done

  if [[ -z "$found_id" ]]; then
    die "no squad/agent/member matched \"$query\" in workspace ${WORKSPACE_ID:-<unset>}"
  fi
  echo "$found_type|$found_id"
}

if [[ "$need_squads" == "true" ]]; then
  fetch_list "/api/squads" "$SQUADS_FILE"
fi
if [[ "$need_agents" == "true" ]]; then
  fetch_list "/api/agents" "$AGENTS_FILE"
fi
if [[ "$need_members" == "true" ]]; then
  # /api/workspaces/{id}/members 或者 ?workspace_id= 都能用
  if [[ -n "$WORKSPACE_ID" ]]; then
    fetch_list "/api/workspaces/$WORKSPACE_ID/members" "$MEMBERS_FILE"
  else
    die "--workspace-id (or workspace_id in config) is required to auto-match members"
  fi
fi
if [[ "$need_projects" == "true" ]]; then
  # /api/projects 返回 {"projects":[...], "total":N}，传 "projects" 自动解包
  fetch_list "/api/projects" "$PROJECTS_FILE" "projects"
fi

# ---- 4) 执行匹配 ----
if [[ -n "$SQUAD_NAME" ]]; then
  [[ ! -f "$SQUADS_FILE" ]] && die "--squad requires squads list"
  ID=$(pick_best "name" "id" "$SQUAD_NAME" "$SQUADS_FILE")
  [[ -z "$ID" ]] && die "no squad matched \"$SQUAD_NAME\""
  ASSIGNEE_TYPE="squad"
  ASSIGNEE_ID="$ID"
fi
if [[ -n "$AGENT_NAME" ]]; then
  [[ ! -f "$AGENTS_FILE" ]] && die "--agent requires agents list"
  ID=$(pick_best "name" "id" "$AGENT_NAME" "$AGENTS_FILE")
  [[ -z "$ID" ]] && die "no agent matched \"$AGENT_NAME\""
  ASSIGNEE_TYPE="agent"
  ASSIGNEE_ID="$ID"
fi
if [[ -n "$MEMBER_NAME" ]]; then
  [[ ! -f "$MEMBERS_FILE" ]] && die "--member requires members list"
  ID=$($JQ -r --arg n "$MEMBER_NAME" '
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
  [[ -z "$ID" ]] && die "no member matched \"$MEMBER_NAME\""
  ASSIGNEE_TYPE="member"
  ASSIGNEE_ID="$ID"
fi
if [[ -n "$ASSIGNEE_NAME" ]]; then
  result=$(resolve_assignee "$ASSIGNEE_NAME")
  ASSIGNEE_TYPE="${result%%|*}"
  ASSIGNEE_ID="${result##*|}"
fi
if [[ -n "$PROJECT_NAME" ]]; then
  [[ ! -f "$PROJECTS_FILE" ]] && die "--project requires projects list"
  PROJECT_ID=$(pick_best "title" "id" "$PROJECT_NAME" "$PROJECTS_FILE")
  [[ -z "$PROJECT_ID" ]] && die "no project matched \"$PROJECT_NAME\""
fi

# ---- 4) v0.13：上传本地附件（不绑 issue_id），收集已上传附件的元信息 ----
# 放在自动匹配之后，确保 assignee / project 校验失败时不会留下孤儿附件
: > "$TMP_DIR/uploaded_attachments.tsv"
SNIPPETS_PARTS=()    # 用于追加到 description 的 markdown 片段数组

if [[ ${#ATTACHMENT_PATHS[@]} -gt 0 ]]; then
  echo "Uploading ${#ATTACHMENT_PATHS[@]} attachment(s)..." >&2
  for p in "${ATTACHMENT_PATHS[@]}"; do
    snippet=$(upload_one_attachment "$p")
    SNIPPETS_PARTS+=("$snippet")
  done
fi

# 把 --attachment-ids 的元信息也补齐；fragment 拼到 markdown 数组里（顺序按用户传入顺序）。
# 注意：只有要嵌 markdown 才需要 fetch metadata；--no-embed 直接跳过，省 N 次 GET。
if [[ -n "$ATTACHMENT_IDS_CSV" && "$EMBED_MARKDOWN" == "true" ]]; then
  IFS=',' read -r -a _ids <<< "$ATTACHMENT_IDS_CSV"
  for id in "${_ids[@]}"; do
    [[ -z "$id" ]] && continue
    snippet=$(fetch_one_attachment_meta "$id")
    SNIPPETS_PARTS+=("$snippet")
  done
fi

# 默认把所有 snippet 追加到 description 末尾（用空行隔开）
if [[ "$EMBED_MARKDOWN" == "true" && ${#SNIPPETS_PARTS[@]} -gt 0 ]]; then
  _joined=""
  for s in "${SNIPPETS_PARTS[@]}"; do
    if [[ -z "$_joined" ]]; then
      _joined="$s"
    else
      _joined="${_joined}

${s}"
    fi
  done
  if [[ -z "$DESCRIPTION" ]]; then
    DESCRIPTION="$_joined"
  else
    DESCRIPTION="${DESCRIPTION}

${_joined}"
  fi
fi

# ---- 5) 构造 body ----

# v0.13：汇总最终 attachment_ids（--attachment 上传产生的 id 放前面，--attachment-ids 放后面，避免依赖 fetch 顺序）
UPLOADED_IDS_PARTS=()
if [[ -f "$TMP_DIR/uploaded_attachments.tsv" ]]; then
  while IFS=$'\t' read -r id _ctype _filename _md; do
    [[ -n "$id" ]] && UPLOADED_IDS_PARTS+=("$id")
  done < "$TMP_DIR/uploaded_attachments.tsv"
fi
PRE_EXISTING_IDS_PARTS=()
if [[ -n "$ATTACHMENT_IDS_CSV" ]]; then
  IFS=',' read -r -a PRE_EXISTING_IDS_PARTS <<< "$ATTACHMENT_IDS_CSV"
fi
ATTACHMENT_IDS_CSV_FINAL=""
for id in "${UPLOADED_IDS_PARTS[@]}"; do
  if [[ -z "$ATTACHMENT_IDS_CSV_FINAL" ]]; then
    ATTACHMENT_IDS_CSV_FINAL="$id"
  else
    ATTACHMENT_IDS_CSV_FINAL="${ATTACHMENT_IDS_CSV_FINAL},${id}"
  fi
done
for id in "${PRE_EXISTING_IDS_PARTS[@]}"; do
  [[ -z "$id" ]] && continue
  if [[ -z "$ATTACHMENT_IDS_CSV_FINAL" ]]; then
    ATTACHMENT_IDS_CSV_FINAL="$id"
  else
    ATTACHMENT_IDS_CSV_FINAL="${ATTACHMENT_IDS_CSV_FINAL},${id}"
  fi
done

BODY=$($JQ -n \
  --arg title "$TITLE" \
  --arg description "$DESCRIPTION" \
  --arg priority "$PRIORITY" \
  --arg status "$STATUS" \
  --arg assignee_type "$ASSIGNEE_TYPE" \
  --arg assignee_id "$ASSIGNEE_ID" \
  --arg project_id "$PROJECT_ID" \
  --arg parent_issue_id "$PARENT_ISSUE_ID" \
  --arg due_date "$DUE_DATE" \
  --arg label_ids "$LABEL_IDS_CSV" \
  --argjson attachment_ids "$(csv_to_json_array "$ATTACHMENT_IDS_CSV_FINAL")" \
  --argjson allow_duplicate "$([[ "$ALLOW_DUPLICATE" == "true" ]] && echo true || echo false)" \
  '
  {
    title: $title,
    description:      (if $description == "" then null else $description end),
    priority:         (if $priority == "" then null else $priority end),
    status:           (if $status == "" then null else $status end),
    assignee_type:    (if $assignee_type == "" then null else $assignee_type end),
    assignee_id:      (if $assignee_id == "" then null else $assignee_id end),
    project_id:       (if $project_id == "" then null else $project_id end),
    parent_issue_id:  (if $parent_issue_id == "" then null else $parent_issue_id end),
    due_date:         (if $due_date == "" then null else $due_date end),
    label_ids:        (if $label_ids == "" then null else ($label_ids | split(",")) end),
    attachment_ids:   (if $attachment_ids == null then null else $attachment_ids end),
    allow_duplicate:  $allow_duplicate
  }
  | with_entries(select(.value != null))
  ')

if [[ "$DRY_RUN" == "true" ]]; then
  echo "==== DRY RUN: would POST $SERVER_URL/api/issues ===="
  echo "Headers: Authorization: Bearer ***, X-Client-Platform: multica-cli-skill, X-Workspace-ID: ${WORKSPACE_ID:-<unset>}"
  if [[ ${#ATTACHMENT_PATHS[@]} -gt 0 ]]; then
    echo "Will upload ${#ATTACHMENT_PATHS[@]} local file(s) via /api/upload-file (no issue_id bound):"
    for p in "${ATTACHMENT_PATHS[@]}"; do echo "  - $p"; done
  fi
  if [[ -n "$ATTACHMENT_IDS_CSV" && "$EMBED_MARKDOWN" == "true" ]]; then
    echo "Will fetch metadata for ${#PRE_EXISTING_IDS_PARTS[@]} pre-existing attachment(s) to embed markdown into description."
  fi
  if [[ "$EMBED_MARKDOWN" == "true" && ${#SNIPPETS_PARTS[@]} -gt 0 ]]; then
    echo "Will append ${#SNIPPETS_PARTS[@]} markdown snippet(s) to description."
  fi
  if [[ "$EMBED_MARKDOWN" == "false" && (${#ATTACHMENT_PATHS[@]} -gt 0 || -n "$ATTACHMENT_IDS_CSV") ]]; then
    echo "Note: --no-embed set; attachment markdown NOT appended to description."
  fi
  echo "Final description:"
  echo "$DESCRIPTION" | sed 's/^/  | /'
  echo "Body:"
  echo "$BODY" | $JQ .
  rm -f "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
  exit 0
fi

# ---- 6) POST ----
URL="$SERVER_URL/api/issues"
[[ -n "$WORKSPACE_ID" ]] && URL="$URL?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"

CURL_ARGS=(
  -sS
  -o $TMP_DIR/resp.json
  -w "%{http_code}"
  -H "@$AUTH_HEADER_FILE"
  -H "Content-Type: application/json"
  -H "X-Client-Platform: multica-cli-skill"
  -H "X-Client-Version: 0.1.0"
  -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
  -H "X-Client-Capabilities: stable_attachment_urls"
)
[[ -n "$WORKSPACE_ID" ]] && CURL_ARGS+=(-H "X-Workspace-ID: $WORKSPACE_ID")
CURL_ARGS+=(-X POST --data-raw "$BODY" "$URL")

HTTP=$(curl "${CURL_ARGS[@]}" || echo "000")

if [[ "$HTTP" != "201" && "$HTTP" != "200" ]]; then
  cat $TMP_DIR/resp.json >&2 || true
  rm -f $TMP_DIR/resp.json "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"
  die "POST /api/issues returned HTTP $HTTP"
fi

RESP="$(cat $TMP_DIR/resp.json)"
ID="$(echo "$RESP" | $JQ -r '.id')"
IDENT="$(echo "$RESP" | $JQ -r '.identifier')"
WS="$(echo "$RESP" | $JQ -r '.workspace_id')"
STATUS_VAL="$(echo "$RESP" | $JQ -r '.status')"
PRIORITY_VAL="$(echo "$RESP" | $JQ -r '.priority')"

# 反查 workspace 路径段（slug 优先，回退 name，再不行才回退到 id）。
# Multica web 路由使用 workspace 的 slug/name，**不**直接用 id；用 id 拼出来的 URL 在浏览器里打不开。
# 三层回退：
#   1) multica CLI 子命令 `multica workspace list`（注意：CLI 可能登录在别的 workspace，看不到当前 workspace）
#   2) HTTP `GET /api/workspaces/{id}`（用本 skill 自带的 token；不依赖 CLI）
#   3) 最终回退到 workspace_id，并在 stderr 警告
SLUG=""
# 1) CLI
if command -v multica >/dev/null 2>&1 && [[ -n "$WS" ]]; then
  SLUG=$(multica workspace list --output json 2>/dev/null \
    | $JQ -r --arg id "$WS" '
        if type == "array" then (.[] | select(.id == $id) | (.slug // .name // empty))
        elif (.workspaces // null) != null then (.workspaces[] | select(.id == $id) | (.slug // .name // empty))
        else empty end
      ' \
    | head -n1 || true)
fi
# 2) API 回退
if [[ -z "$SLUG" && -n "$WS" && -n "$TOKEN" && -n "$SERVER_URL" ]]; then
  _WS_RESP="$(curl -sS -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    "$SERVER_URL/api/workspaces/$WS" 2>/dev/null || true)"
  if [[ -n "$_WS_RESP" ]] && [[ "$(echo "$_WS_RESP" | $JQ -r '.id // empty')" == "$WS" ]]; then
    SLUG="$(echo "$_WS_RESP" | $JQ -r '.slug // .name // empty')"
  fi
  unset _WS_RESP
fi
if [[ -n "$SLUG" ]]; then
  PATH_SEG="$SLUG"
else
  PATH_SEG="$WS"
  echo "WARN: 无法从 CLI 或 API 反查 workspace slug/name，URL 将使用 workspace_id（在浏览器中可能打不开）。建议在 config.json 里加上 workspace 的 slug 或在 multica CLI 里切换到对应 workspace。" >&2
fi
WEB_URL="$APP_URL/$PATH_SEG/issues/$ID"

# ---- 7) 输出 ----
if [[ "$OUTPUT_JSON" == "true" ]]; then
  $JQ --arg url "$WEB_URL" --arg atype "$ASSIGNEE_TYPE" --arg aid "$ASSIGNEE_ID" --arg pid "$PROJECT_ID" \
     --arg config_path "$CONFIG_PATH" \
     --arg description "$DESCRIPTION" \
     --argjson uploaded_ids "$(csv_to_json_array "$(IFS=,; echo "${UPLOADED_IDS_PARTS[*]}")")" \
     --argjson pre_existing_ids "$(csv_to_json_array "$(IFS=,; echo "${PRE_EXISTING_IDS_PARTS[*]}")")" \
    '. + {
       web_url: $url,
       matched_assignee_type: $atype,
       matched_assignee_id: $aid,
       matched_project_id: $pid,
       config_path: $config_path,
       embedded_markdown: $description,
       uploaded_attachment_ids: (if $uploaded_ids == null then [] else $uploaded_ids end),
       pre_existing_attachment_ids: (if $pre_existing_ids == null then [] else $pre_existing_ids end)
     }' \
    $TMP_DIR/resp.json
else
  echo "Created $IDENT (id=$ID)"
  echo "   id:       $ID"
  echo "   status:   $STATUS_VAL"
  echo "   priority: $PRIORITY_VAL"
  [[ -n "$ASSIGNEE_TYPE" ]] && echo "   assignee: $ASSIGNEE_TYPE/$ASSIGNEE_ID"
  [[ -n "$PROJECT_ID"     ]] && echo "   project:  $PROJECT_ID"
  if [[ ${#UPLOADED_IDS_PARTS[@]} -gt 0 || ${#PRE_EXISTING_IDS_PARTS[@]} -gt 0 ]]; then
    _joined=""
    for id in "${UPLOADED_IDS_PARTS[@]}" "${PRE_EXISTING_IDS_PARTS[@]}"; do
      [[ -z "$id" ]] && continue
      if [[ -z "$_joined" ]]; then _joined="$id"; else _joined="${_joined}, ${id}"; fi
    done
    echo "   attachments: ${#UPLOADED_IDS_PARTS[@]} uploaded + ${#PRE_EXISTING_IDS_PARTS[@]} pre-existing → $_joined"
  fi
  echo "   url:      $WEB_URL"
fi

rm -f $TMP_DIR/resp.json "$SQUADS_FILE" "$AGENTS_FILE" "$MEMBERS_FILE" "$PROJECTS_FILE"