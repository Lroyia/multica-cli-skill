#!/usr/bin/env bash
# multica-cli-skill / status.sh — 工位状态目录（workspace issue status catalog，v0.13 新增）
#
# 背景（multica v0.7.x，MUL-6243）：
#   issue 的 status 不再只是 7 个内建值。workspace 可以自定义状态（`/api/issue-statuses`），
#   写路径（POST /api/issues、PUT /api/issues/{id}）都按 workspace 的 catalog 校验：
#   内建 7 个（backlog todo in_progress in_review done blocked cancelled）永远可用，
#   自定义状态用它的 key（大小写不敏感、去首尾空格）。本脚本用于发现当前 workspace
#   有哪些合法 status——在 order.sh / update.sh 里传 `--status` 之前先查一眼。
#
# 子命令：
#   list [--include-archived]     列出 workspace 的状态目录（显示顺序）
#   keys [--include-archived]     只输出 status key 列表（一行一个，便于脚本消费）
#
# 用法示例：
#   status.sh list
#   status.sh list --include-archived --json
#   status.sh keys
#
# 通用选项：
#   --config <path>                  显式指定 config.json
#   --server-url URL                 覆盖 config 里的 server_url
#   --app-url URL                    覆盖 config 里的 app_url（本脚本基本用不到）
#   --workspace-id UUID              覆盖 config 里的 workspace_id
#   --json                           输出完整 JSON
#
# 前置依赖: curl, jq, uname
# 凭证来源: --config > <skill_dir>/config.json > $MULTICA_CLI_ORDER_CONFIG > ~/.multica/config.json
#           $MULTICA_TOKEN 覆盖 token
#
# 权限：读 catalog 任何 workspace 成员都可以；创建 / 改 / 删 / 排序状态是 owner/admin
# 的 UI 操作，本 skill 只读不写（配置变更请走 Multica Web）。

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

INCLUDE_ARCHIVED="false"
OUTPUT_JSON="false"
CONFIG_PATH=""
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""

usage() { sed -n '2,32p' "$0"; }
die() { echo "ERROR: $*" >&2; exit 1; }

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

# ---- 子命令 ----
SUBCMD="${1:-list}"
shift || true
case "$SUBCMD" in
  list|keys) ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown subcommand: $SUBCMD (use list / keys)" ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-archived) INCLUDE_ARCHIVED="true"; shift;;
    --json)             OUTPUT_JSON="true"; shift;;
    --config)           CONFIG_PATH="$2"; shift 2;;
    --server-url)       SERVER_URL_OVERRIDE="$2"; shift 2;;
    --app-url)          APP_URL_OVERRIDE="$2"; shift 2;;
    --workspace-id)     WORKSPACE_ID_OVERRIDE="$2"; shift 2;;
    -h|--help)          usage; exit 0;;
    *) die "unknown arg: $1";;
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
[[ -z "$WORKSPACE_ID" ]] && die "missing workspace_id. Set workspace_id in $CONFIG_PATH or pass --workspace-id. The status catalog is workspace-scoped."

AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"

# ---- 请求 ----
URL="$SERVER_URL/api/issue-statuses?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')"
[[ "$INCLUDE_ARCHIVED" == "true" ]] && URL+="&include_archived=true"

HTTP=$(curl -sS -o "$TMP_DIR/resp.json" -w "%{http_code}" \
  -H "@$AUTH_HEADER_FILE" \
  -H "X-Client-Platform: multica-cli-skill" \
  -H "X-Client-Version: 0.13.0" \
  -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')" \
  -H "X-Client-Capabilities: stable_attachment_urls" \
  -H "X-Workspace-ID: $WORKSPACE_ID" \
  "$URL" || echo "000")
if [[ "$HTTP" != "200" ]]; then
  cat "$TMP_DIR/resp.json" >&2 || true
  die "GET /api/issue-statuses returned HTTP $HTTP"
fi

# 服务端可能返回两种形状：
#   1) 裸数组 []IssueStatusResponse（脚本原始假设，multica v0.7.x）
#   2) 包裹对象 {"categories":[...], "statuses":[...]}（部分部署版本）
# 统一解包成裸数组再往下走。
if $JQ -e 'type == "array"' "$TMP_DIR/resp.json" >/dev/null 2>&1; then
  :
elif $JQ -e '.statuses | type == "array"' "$TMP_DIR/resp.json" >/dev/null 2>&1; then
  $JQ '.statuses' "$TMP_DIR/resp.json" > "$TMP_DIR/resp.unwrapped" \
    && mv "$TMP_DIR/resp.unwrapped" "$TMP_DIR/resp.json"
else
  die "GET /api/issue-statuses returned an unexpected shape (expected a bare array or {\"statuses\":[...]})"
fi

case "$SUBCMD" in
  keys)
    $JQ -r '.[].key' "$TMP_DIR/resp.json"
    ;;
  list)
    if [[ "$OUTPUT_JSON" == "true" ]]; then
      cat "$TMP_DIR/resp.json"
    else
      COUNT=$($JQ 'length' "$TMP_DIR/resp.json")
      echo "Workspace $WORKSPACE_ID has $COUNT status(es) (display order):"
      echo ""
      $JQ -r '.[] |
        "  " +
        (if .is_system then "[builtin] " else "[custom]  " end) +
        .key + "  (" + (.name // "-") + ")" +
        "  category=" + (.category // "-") +
        (if .description and .description != "" then "  — " + .description else "" end)
      ' "$TMP_DIR/resp.json"
      echo ""
      echo "Pass any key above to order.sh / update.sh --status (case-insensitive)."
    fi
    ;;
esac

rm -f "$TMP_DIR/resp.json"
