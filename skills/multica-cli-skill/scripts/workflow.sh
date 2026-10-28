#!/usr/bin/env bash
# multica-cli-skill / workflow.sh — 项目工作流（project workflows，MUL-7420，multica v0.7.x 新增）
#
# 背景：
#   multica v0.7.1 给项目引入了「工作流」：一个 workflow 由一列 status 列组成，
#   每列（step）可以配置一个 handler（agent / squad / member / 项目负责人 / 创建者）、
#   指令（instructions）和 next/back 状态。issue 进入一个配置了 handler 的列时，
#   会被自动转派给 handler 并以其 instructions 启动一次 run（handoff）。
#   - project 用哪个 workflow：Default（接收一切状态）或某个 named workflow
#   - named workflow 的项目里，issue 的 status 只能取 workflow 列出的值
#   - 读 / 建 workflow 所有成员都可以；改 / 删是 workflow owner 或 workspace admin；
#     切换项目 workflow 是 admin 或项目负责人
#
# 子命令：
#   list                                        列 workspace 的所有 workflow
#   get <workflow-id>                           取单个 workflow 详情
#   preview <issue-id-or-identifier>            预览把 issue 移到某状态会发生什么
#        [--status KEY] [--project-id UUID]        （handoff / previous runs / brief，只读不写）
#   set-project <project-id-or-title>           切换项目使用的 workflow（admin / 项目 lead）
#        (--workflow-id UUID | --default)
#        [--dry-run] [--status-mapping '{"old":"new",...}']
#   handoff <workflow-id> <status-key>          配置某列的 handoff（owner / admin）
#        [--handler-type agent|squad|member|project_lead|creator|none]
#        [--handler-id UUID] [--instructions TEXT]
#        [--next-status-key KEY] [--back-status-key KEY]
#        [--copy-for-project-id UUID] [--yes]
#   create --name NAME [--description TEXT] --steps-json JSON [--dry-run]
#   update <workflow-id> [--name N] [--description D] [--steps-json JSON]
#          [--status-mapping JSON] [--dry-run]
#   delete <workflow-id> [--yes]
#
# steps-json 格式（IssueWorkflowStepInput[]，与 PATCH/POST body 的 steps 字段一致）：
#   [
#     {"status_key":"todo"},
#     {"status_key":"in_progress","handler":{"type":"agent","id":"<uuid>"},
#      "instructions":"实现并自测","next_status_key":"in_review"},
#     {"status_key":"in_review"},
#     {"status_key":"done"}
#   ]
#   handler.type ∈ agent|squad|member|project_lead|creator|none（"" 同 none）
#   steps 会整体替换 workflow 的列；todo/done/cancelled 缺失时自动补回固定位置。
#
# 用法示例：
#   workflow.sh list --json
#   workflow.sh get <workflow-uuid>
#   workflow.sh preview LRO-52 --status in_review
#   workflow.sh set-project "支付重构" --default --dry-run
#   workflow.sh handoff <uuid> in_progress --handler-type agent --handler-id <uuid> \
#     --instructions "请实现并附截图" --next-status-key in_review
#   workflow.sh create --name "发布流水线" --steps-json '[{"status_key":"todo"},{"status_key":"done"}]'
#
# 通用选项（所有子命令）：
#   --config <path> / --server-url URL / --app-url URL / --workspace-id UUID
#   --json    输出完整 JSON
#   --yes     跳过 handoff / delete 的默认确认
#
# 前置依赖: curl, jq, uname
# 凭证来源: --config > <skill_dir>/config.json > $MULTICA_CLI_ORDER_CONFIG > ~/.multica/config.json
#           $MULTICA_TOKEN 覆盖 token

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

usage() { sed -n '2,59p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }

SUBCMD="${1:-list}"
shift || true
case "$SUBCMD" in
  list|get|preview|set-project|handoff|create|update|delete) ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown subcommand: $SUBCMD" ;;
esac

umask 077
TMP_DIR="$(mktemp -d /tmp/multica-cli-skill.XXXXXX)" || die "failed to create private temp directory"
cleanup() { rm -rf -- "$TMP_DIR"; }
trap cleanup EXIT INT TERM

SKILL_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
else
  SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
fi
SKILL_DIR_CONFIG="$SKILL_DIR/config.json"

CONFIG_PATH_IS_DEFAULT="false"
resolve_config_path() {
  [[ -n "$CONFIG_PATH" ]] && return
  if [[ -f "$SKILL_DIR_CONFIG" ]]; then
    CONFIG_PATH="$SKILL_DIR_CONFIG"
    CONFIG_PATH_IS_DEFAULT="true"
    return
  fi
  if [[ -n "${MULTICA_CLI_ORDER_CONFIG:-}" ]]; then
    CONFIG_PATH="$MULTICA_CLI_ORDER_CONFIG"
    return
  fi
  local home="${HOME:-${USERPROFILE:-}}"
  [[ -n "$home" ]] || die "HOME is not set. Set HOME (or USERPROFILE on Windows), or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  home="$(printf '%s' "$home" | tr '\134' '/')"
  CONFIG_PATH="$home/.multica/config.json"
  CONFIG_PATH_IS_DEFAULT="true"
}

# ---- 全局 flag（子命令前后都认）----
OUTPUT_JSON="false"
ASSUME_YES="false"
CONFIG_PATH=""
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""

ARGS=("$@")
i=0
GLOBAL_FLAGS=(--config --server-url --app-url --workspace-id --json --yes)

while [[ $i -lt ${#ARGS[@]} ]]; do
  a="${ARGS[$i]}"
  case "$a" in
    --config)       CONFIG_PATH="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --server-url)   SERVER_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --app-url)      APP_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --workspace-id) WORKSPACE_ID_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --json)         OUTPUT_JSON="true"; i=$((i+1)); continue ;;
    --yes|-y)       ASSUME_YES="true"; i=$((i+1)); continue ;;
    -h|--help)      usage; exit 0 ;;
    *) break ;;
  esac
done
REST=("${ARGS[@]:$i}")

# ---- 子命令参数 ----
POSITIONAL=()
WF_ID=""
WF_STATUS_KEY=""
ISSUE_TARGET=""
PROJECT_TARGET=""
STATUS_KEY=""
PROJECT_ID_OPT=""
HANDLER_TYPE=""
HANDLER_ID=""
INSTRUCTIONS=""
NEXT_STATUS_KEY=""
BACK_STATUS_KEY=""
COPY_FOR_PROJECT_ID=""
WF_NAME=""
WF_DESC=""
STEPS_JSON=""
STATUS_MAPPING_JSON=""
DRY_RUN="false"
USE_DEFAULT="false"

i=0
N=${#REST[@]}
while [[ $i -lt $N ]]; do
  a="${REST[$i]}"
  case "$a" in
    --status)               STATUS_KEY="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --status-key)           WF_STATUS_KEY="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --project-id)           PROJECT_ID_OPT="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --handler-type)         HANDLER_TYPE="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --handler-id)           HANDLER_ID="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --instructions)         INSTRUCTIONS="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --next-status-key)      NEXT_STATUS_KEY="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --back-status-key)      BACK_STATUS_KEY="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --copy-for-project-id)  COPY_FOR_PROJECT_ID="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --name)                 WF_NAME="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --description)          WF_DESC="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --steps-json)           STEPS_JSON="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --status-mapping)       STATUS_MAPPING_JSON="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --dry-run)              DRY_RUN="true"; i=$((i+1)); continue ;;
    --default)              USE_DEFAULT="true"; i=$((i+1)); continue ;;
    --workflow-id)          WF_ID="${REST[$((i+1))]}"; i=$((i+2)); continue ;;
    --config|--server-url|--app-url|--workspace-id|--json|--yes|-h|--help)
      # 已在第一遍处理过 / 帮助；跳过（含其值）
      if [[ "$a" == "--config" || "$a" == "--server-url" || "$a" == "--app-url" || "$a" == "--workspace-id" ]]; then
        i=$((i+2))
      else
        i=$((i+1))
      fi
      continue ;;
    --*) die "unknown flag: $a" ;;
    *)  POSITIONAL+=("$a"); i=$((i+1)); continue ;;
  esac
done

# ---- 凭证 ----
resolve_config_path
if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$CONFIG_PATH_IS_DEFAULT" == "true" ]]; then
    die "Multica CLI config not found: $CONFIG_PATH. Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  fi
  die "config file not found: $CONFIG_PATH"
fi
command -v jq >/dev/null 2>&1 || die "jq is required. Install jq first."
JQ="jq"
TOKEN="$($JQ -r '.token       // empty' "$CONFIG_PATH")"
SERVER_URL="$($JQ -r '.server_url // empty' "$CONFIG_PATH")"
APP_URL="$($JQ   -r '.app_url    // empty' "$CONFIG_PATH")"
WORKSPACE_ID="$($JQ -r '.workspace_id // empty' "$CONFIG_PATH")"
[[ -n "${MULTICA_TOKEN:-}" ]] && TOKEN="$MULTICA_TOKEN"
[[ -n "$SERVER_URL_OVERRIDE"   ]] && SERVER_URL="$SERVER_URL_OVERRIDE"
[[ -n "$APP_URL_OVERRIDE"      ]] && APP_URL="$APP_URL_OVERRIDE"
[[ -n "$WORKSPACE_ID_OVERRIDE" ]] && WORKSPACE_ID="$WORKSPACE_ID_OVERRIDE"
[[ -z "$TOKEN"      ]] && die "missing token. Set MULTICA_TOKEN env, or write token into $CONFIG_PATH, or pass --config"
[[ -z "$SERVER_URL" ]] && die "missing server_url. Set server_url in $CONFIG_PATH or pass --server-url"
SERVER_URL="${SERVER_URL%/}"
[[ -z "$WORKSPACE_ID" ]] && die "missing workspace_id. Set workspace_id in $CONFIG_PATH or pass --workspace-id. Workflows are workspace-scoped."

AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"

# ---- HTTP 工具 ----
api_req() {
  # api_req <method> <path> [body-file]
  local method="$1" path="$2" body="${3:-}"
  local url="$SERVER_URL$path"
  local args=(
    -sS -o "$TMP_DIR/resp.json" -w "%{http_code}"
    -X "$method"
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.13.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
    -H "X-Workspace-ID: $WORKSPACE_ID"
  )
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data-binary "@$body")
  curl "${args[@]}" "$url" || echo "000"
}

resolve_issue_to_uuid() {
  # identifier (LRO-N / UUID) → UUID
  local id="$1"
  if [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo -n "$id"; return
  fi
  local out="$TMP_DIR/resolve.json" code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$SERVER_URL/api/issues/$id?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true; rm -f "$out"
    die "resolve issue '$id' → HTTP $code"
  fi
  local uuid; uuid=$($JQ -r '.id // empty' "$out"); rm -f "$out"
  [[ -n "$uuid" ]] || die "resolve issue '$id': empty id in response"
  echo -n "$uuid"
}

resolve_project_to_uuid() {
  # 项目名 fuzzy match /api/projects（与 order.sh 一致的打分）；UUID 原样通过
  local input="$1"
  if [[ "$input" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo -n "$input"; return
  fi
  local out="$TMP_DIR/projects.json" code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$SERVER_URL/api/projects?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true; rm -f "$out"
    die "GET /api/projects → HTTP $code"
  fi
  local id
  id=$($JQ -r --arg n "$input" '
    [ (.projects // .)[]? ] as $rows
    | [ range(0; ($rows | length)) as $i
        | { idx: $i, name: (($rows[$i].title // "") as $t | $t), id: ($rows[$i].id // "") }
        | . + { score:
            ( if .name == $n then 100
              elif (.name | ascii_downcase) == ($n | ascii_downcase) then 90
              elif (.name | ascii_downcase | test($n | ascii_downcase)) then 70
              elif ((.name | ascii_downcase | gsub("[ \\-_]"; "")) | test($n | ascii_downcase | gsub("[ \\-_]"; ""))) then 50
              else 0 end ) }
        | select(.score > 0) ]
    | sort_by(-.score, .idx)
    | if length == 0 then empty else .[0].id end
  ' "$out" | head -n1)
  rm -f "$out"
  [[ -n "$id" ]] || die "no project matched \"$input\""
  echo -n "$id"
}

# 结构化 workflow 错误 → 人话
print_workflow_error() {
  # 服务端可能返回 {"error","code"} 或 writeError 的 {"error"}
  local code msg
  code=$($JQ -r '.code // ""' "$TMP_DIR/resp.json" 2>/dev/null || echo "")
  msg=$($JQ -r '.error // ""' "$TMP_DIR/resp.json" 2>/dev/null || echo "")
  case "$code" in
    status_not_in_workflow)
      echo "ERROR: $msg" >&2
      echo "       该项目使用了 named workflow，status 必须取 workflow 列出的值之一。" >&2
      ;;
    workflow_step_moved)
      echo "ERROR: $msg" >&2
      echo "       这个 issue 在你的 run 工作期间被别人移动了；不要在本 run 里再改状态，需要时留评论。" >&2
      ;;
    invalid_handoff)
      echo "ERROR: handoff 无效: $msg" >&2
      ;;
    *)
      [[ -n "$msg" ]] && echo "ERROR: $msg" >&2 || cat "$TMP_DIR/resp.json" >&2 || true
      ;;
  esac
}

require_yes() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  if [[ -t 0 ]]; then
    local ans
    read -r -p "$1 [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) return 0 ;;
      *) echo "Aborted."; exit 130 ;;
    esac
  else
    echo "(non-interactive stdin; pass --yes to confirm)" >&2
    exit 64
  fi
}

# ---- 子命令分发 ----
case "$SUBCMD" in
  list)
    WS_Q="workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
    HTTP=$(api_req GET "/api/issue-workflows?$WS_Q")
    [[ "$HTTP" == "200" ]] || { print_workflow_error; die "GET /api/issue-workflows → HTTP $HTTP"; }
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      cat "$TMP_DIR/resp.json"
    else
      $JQ -r '(.workflows // []) | "Workspace has \(length) workflow(s):\n",
        (.[] |
          "  ● " + .name + (if .is_default then "  [DEFAULT]" else "" end) +
          "\n      id:          " + .id +
          "\n      description: " + ((.description // "-") | tostring) +
          "\n      steps:       " + ([.steps[].status_key] | join(" → ")) +
          "\n      handoffs:    " + ([.steps[] | select(((.handler.type // "") != "") and ((.handler.type // "") != "none")) | .status_key + "→" + .handler.type] | if length > 0 then join(", ") else "-" end) +
          "\n      projects:    " + (.project_ids | if length > 0 then join(", ") else "-" end) + "\n"
        )' "$TMP_DIR/resp.json"
    fi
    ;;

  get)
    [[ ${#POSITIONAL[@]} -ge 1 || -n "$WF_ID" ]] || die "get: missing <workflow-id>"
    [[ ${#POSITIONAL[@]} -ge 1 ]] && WF_ID="${POSITIONAL[0]}"
    HTTP=$(api_req GET "/api/issue-workflows/$WF_ID?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')")
    [[ "$HTTP" == "200" ]] || { print_workflow_error; die "GET /api/issue-workflows/$WF_ID → HTTP $HTTP"; }
    if [[ "$OUTPUT_JSON" == "true" ]]; then cat "$TMP_DIR/resp.json"; else $JQ . "$TMP_DIR/resp.json"; fi
    ;;

  preview)
    [[ ${#POSITIONAL[@]} -ge 1 ]] || die "preview: missing <issue-id-or-identifier>"
    ISSUE_TARGET="${POSITIONAL[0]}"
    [[ -z "$STATUS_KEY" && -z "$PROJECT_ID_OPT" ]] && die "preview: pass --status KEY and/or --project-id UUID"
    ISSUE_UUID="$(resolve_issue_to_uuid "$ISSUE_TARGET")"
    Q="workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
    [[ -n "$STATUS_KEY"     ]] && Q+="&status=$($JQ -rn --arg v "$STATUS_KEY" '$v|@uri')"
    [[ -n "$PROJECT_ID_OPT" ]] && Q+="&project_id=$($JQ -rn --arg v "$PROJECT_ID_OPT" '$v|@uri')"
    HTTP=$(api_req GET "/api/issues/$ISSUE_UUID/workflow-handoff?$Q")
    [[ "$HTTP" == "200" ]] || { print_workflow_error; die "GET workflow-handoff → HTTP $HTTP"; }
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      cat "$TMP_DIR/resp.json"
    else
      $JQ -r '
        "Workflow handoff preview (nothing was written):",
        "  from_status:        \(.from_status)",
        "  to_status:          \(.to_status)",
        (if .handoff then
          "  handoff:            YES",
          "  workflow:           \(.workflow_name)",
          "  handler:            \(.handler_type) \(.handler_id)",
          (if .brief and .brief != "" then "  brief:\n" + (.brief | split("\n") | map("    " + .) | join("\n")) else empty end),
          "  previous_runs:      " + ((.previous_runs // []) | if length > 0 then (map("\(.task_id)(\(.status))") | join(", ")) else "none" end)
        else
          "  handoff:            NO（这次移动不会触发转派）"
        end)
      ' "$TMP_DIR/resp.json"
    fi
    ;;

  set-project)
    [[ ${#POSITIONAL[@]} -ge 1 ]] || die "set-project: missing <project-id-or-title>"
    PROJECT_TARGET="${POSITIONAL[0]}"
    [[ -n "$WF_ID" || "$USE_DEFAULT" == "true" ]] || die "set-project: pass --workflow-id UUID or --default"
    [[ -n "$WF_ID" && "$USE_DEFAULT" == "true" ]] && die "set-project: --workflow-id and --default are mutually exclusive"
    PROJECT_UUID="$(resolve_project_to_uuid "$PROJECT_TARGET")"
    BODY_FILE="$TMP_DIR/body.json"
    if [[ "$USE_DEFAULT" == "true" ]]; then
      echo '{"workflow_id": null}' > "$BODY_FILE"
    else
      $JQ -n --arg w "$WF_ID" '{workflow_id: $w}' > "$BODY_FILE"
    fi
    [[ -n "$STATUS_MAPPING_JSON" ]] && $JQ --argjson m "$STATUS_MAPPING_JSON" '. + {status_mapping: $m}' "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"
    [[ "$DRY_RUN" == "true" ]] && $JQ '. + {dry_run: true}' "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"
    HTTP=$(api_req POST "/api/projects/$PROJECT_UUID/workflow?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" "$BODY_FILE")
    [[ "$HTTP" == "200" ]] || { print_workflow_error; die "POST /api/projects/$PROJECT_UUID/workflow → HTTP $HTTP"; }
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      cat "$TMP_DIR/resp.json"
    else
      $JQ -r '
        (if .dry_run == true then "Dry run plan (nothing was written):" else "Project workflow changed:" end),
        "  updated_issues: \(.updated_issues // 0)",
        (if .project then "  project:        \(.project.title // .project.id)  workflow_id=\(.project.workflow_id // "default")" else empty end),
        ((.plan.required // []) | if length > 0 then
          "  required mappings:\n" + (map("    " + .status_key + " (" + (.issue_count|tostring) + " issues) → " + .suggested_status_key) | join("\n"))
        else empty end)
      ' "$TMP_DIR/resp.json"
    fi
    ;;

  handoff)
    [[ ${#POSITIONAL[@]} -ge 2 ]] || die "handoff: missing <workflow-id> and/or <status-key>"
    WF_ID="${POSITIONAL[0]}"
    WF_STATUS_KEY="${POSITIONAL[1]}"
    STEP_FILE="$TMP_DIR/step.json"
    $JQ -n --arg sk "$WF_STATUS_KEY" '{status_key: $sk}' > "$STEP_FILE"
    add_step_field() {
      # add_step_field <jq-args...>  — 把字段合并进 step.json
      $JQ "$@" "$STEP_FILE" > "$STEP_FILE.tmp" && mv "$STEP_FILE.tmp" "$STEP_FILE"
    }
    if [[ -n "$HANDLER_TYPE" ]]; then
      case "$HANDLER_TYPE" in
        agent|squad|member) [[ -n "$HANDLER_ID" ]] || die "handoff: --handler-type $HANDLER_TYPE requires --handler-id UUID";;
        project_lead|creator|none|"") ;;
        *) die "handoff: --handler-type must be agent|squad|member|project_lead|creator|none";;
      esac
      if [[ "$HANDLER_TYPE" == "none" || -z "$HANDLER_TYPE" ]]; then
        add_step_field '{handler: {type: "", id: ""}}'
      else
        $JQ -n --arg t "$HANDLER_TYPE" --arg i "$HANDLER_ID" '{handler: {type: $t, id: $i}}' > "$TMP_DIR/h.json"
        $JQ -s '.[0] + .[1]' "$STEP_FILE" "$TMP_DIR/h.json" > "$STEP_FILE.tmp" && mv "$STEP_FILE.tmp" "$STEP_FILE"
      fi
    elif [[ -n "$HANDLER_ID" ]]; then
      die "handoff: --handler-id requires --handler-type agent|squad|member"
    fi
    [[ -n "$INSTRUCTIONS"    ]] && add_step_field --arg i "$INSTRUCTIONS"    '{. + {instructions: $i}}'
    [[ -n "$NEXT_STATUS_KEY" ]] && add_step_field --arg n "$NEXT_STATUS_KEY" '{. + {next_status_key: $n}}'
    [[ -n "$BACK_STATUS_KEY" ]] && add_step_field --arg b "$BACK_STATUS_KEY" '{. + {back_status_key: $b}}'
    [[ -n "$COPY_FOR_PROJECT_ID" ]] && add_step_field --arg p "$COPY_FOR_PROJECT_ID" '{. + {copy_for_project_id: $p}}'

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "==== DRY RUN: would PUT /api/issue-workflows/$WF_ID/handoffs/$WF_STATUS_KEY ===="
      $JQ . "$STEP_FILE"
      exit 0
    fi
    require_yes "Save handoff for step \"$WF_STATUS_KEY\" of workflow $WF_ID?"
    HTTP=$(api_req PUT "/api/issue-workflows/$WF_ID/handoffs/$WF_STATUS_KEY?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" "$STEP_FILE")
    [[ "$HTTP" == "200" || "$HTTP" == "201" ]] || { print_workflow_error; die "PUT handoffs/$WF_STATUS_KEY → HTTP $HTTP"; }
    if [[ "$OUTPUT_JSON" == "true" ]]; then cat "$TMP_DIR/resp.json"; else
      echo "Handoff saved."
      $JQ -r '.steps[] | select(.status_key == $k) | "  step \(.status_key): handler=\(.handler.type // "none") instructions=\((.instructions // "") | tostring) next=\(.next_status_key // "-") back=\(.back_status_key // "-")"' --arg k "$WF_STATUS_KEY" "$TMP_DIR/resp.json"
    fi
    ;;

  create|update)
    BODY_FILE="$TMP_DIR/body.json"
    if [[ "$SUBCMD" == "create" ]]; then
      [[ -n "$WF_NAME" ]] || die "create: --name is required"
      [[ -n "$STEPS_JSON" ]] || die "create: --steps-json is required (use e.g. '[{\"status_key\":\"todo\"},{\"status_key\":\"done\"}]')"
      echo '{}' > "$BODY_FILE"
    else
      [[ ${#POSITIONAL[@]} -ge 1 || -n "$WF_ID" ]] || die "update: missing <workflow-id>"
      [[ ${#POSITIONAL[@]} -ge 1 ]] && WF_ID="${POSITIONAL[0]}"
      echo '{}' > "$BODY_FILE"
    fi
    [[ -n "$WF_NAME"  ]] && $JQ --arg n "$WF_NAME"   '. + {name: $n}'             "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"
    [[ -n "$WF_DESC"  ]] && $JQ --arg d "$WF_DESC"   '. + {description: $d}'      "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"
    [[ -n "$STEPS_JSON" ]] && { echo "$STEPS_JSON" | $JQ -e 'type == "array"' >/dev/null 2>&1 \
                                  || die "--steps-json must be a JSON array of step objects"; \
                                 $JQ --argjson s "$STEPS_JSON" '. + {steps: $s}' "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"; }
    [[ -n "$STATUS_MAPPING_JSON" ]] && $JQ --argjson m "$STATUS_MAPPING_JSON" '. + {status_mapping: $m}' "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"
    [[ "$DRY_RUN" == "true" ]] && $JQ '. + {dry_run: true}' "$BODY_FILE" > "$BODY_FILE.tmp" && mv "$BODY_FILE.tmp" "$BODY_FILE"

    if [[ "$SUBCMD" == "create" ]]; then
      [[ "$DRY_RUN" == "true" ]] && { echo "==== DRY RUN: would POST /api/issue-workflows ===="; $JQ . "$BODY_FILE"; exit 0; }
      HTTP=$(api_req POST "/api/issue-workflows?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" "$BODY_FILE")
      [[ "$HTTP" == "200" || "$HTTP" == "201" ]] || { print_workflow_error; die "POST /api/issue-workflows → HTTP $HTTP"; }
    else
      [[ "$DRY_RUN" == "true" ]] && { echo "==== DRY RUN: would PATCH /api/issue-workflows/$WF_ID ===="; $JQ . "$BODY_FILE"; exit 0; }
      HTTP=$(api_req PATCH "/api/issue-workflows/$WF_ID?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" "$BODY_FILE")
      [[ "$HTTP" == "200" ]] || { print_workflow_error; die "PATCH /api/issue-workflows/$WF_ID → HTTP $HTTP"; }
    fi
    if [[ "$OUTPUT_JSON" == "true" ]]; then cat "$TMP_DIR/resp.json"; else
      $JQ -r '"Workflow saved: " + .name + (if .is_default then " [DEFAULT]" else "" end) + "  (id: " + .id + ")", ([.steps[].status_key] | "  steps: " + join(" → "))' "$TMP_DIR/resp.json"
    fi
    ;;

  delete)
    [[ ${#POSITIONAL[@]} -ge 1 || -n "$WF_ID" ]] || die "delete: missing <workflow-id>"
    [[ ${#POSITIONAL[@]} -ge 1 ]] && WF_ID="${POSITIONAL[0]}"
    require_yes "Delete workflow $WF_ID? (project 用它的会回退到 Default)"
    HTTP=$(api_req DELETE "/api/issue-workflows/$WF_ID?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')")
    [[ "$HTTP" == "200" || "$HTTP" == "204" ]] || { print_workflow_error; die "DELETE /api/issue-workflows/$WF_ID → HTTP $HTTP"; }
    echo "Deleted workflow $WF_ID (HTTP $HTTP)"
    ;;
esac

rm -f "$TMP_DIR/resp.json"
