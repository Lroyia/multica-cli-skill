#!/usr/bin/env bash
# multica-cli-skill / attachments.sh — 管附件（v0.10 新增；v0.13 加 download）
#
# 子命令（互斥）：
#   upload <file> [--issue LRO-45] [--comment <uuid>]   上传文件，绑到 issue/comment
#   list   <issue-id-or-uuid>                          列某个 issue 的附件
#   get    <attachment-id-or-uuid>                     取单个附件的元信息
#   download <attachment-id-or-uuid> [-o <output>]     下载附件到本地文件（v0.13）
#   delete <attachment-id-or-uuid>                     删除附件
#
# 设计依据（探查 server 源码）：
#   - POST /api/upload-file   multipart/form-data，file 字段必填，可选 issue_id/comment_id/chat_session_id/task_id
#     （task_id 路径需要 X-Actor-Source=task_token 头，agent 内部才用；mul_ PAT 走不了，只能走 issue/comment 上下文）
#   - max upload size = 100 MB (handler/file.go: maxUploadSize = 100 << 20)
#   - 响应 AttachmentResponse: id / url / download_url / markdown_url / filename / content_type / size_bytes / ...
#   - markdown_url 是持久 URL（无 TTL），可安全持久化进 description
#   - 图片嵌入：![name](markdown_url)；其他文件：!file[name](url)
#   - download 走 GET /api/attachments/{id}/download-metadata（multica v0.7.x 新增路由）：
#     按附件行解析 workspace（跨 workspace 的 markdown 链接也能解析），返回新签的
#     download_url / attachment_download_url（带 TTL，不要持久化）。脚本优先用
#     attachment_download_url（强制 Content-Disposition: attachment），缺省回退 download_url。
#
# 用法示例：
#   attachments.sh upload ./需求图.png
#   attachments.sh upload ./需求图.png --issue LRO-45
#   attachments.sh list LRO-45
#   attachments.sh get <attachment-uuid>
#   attachments.sh download <attachment-uuid> -o ./out.png
#   attachments.sh delete <attachment-uuid>

set -euo pipefail
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:+$MSYS2_ARG_CONV_EXCL;}/note;/uploads;/api"

# ---- 默认 / 帮助 ----
usage() {
  cat <<EOF
Usage:
  attachments.sh upload <file> [--issue <id-or-uuid>] [--comment <uuid>]
  attachments.sh list   <issue-id-or-uuid>
  attachments.sh get    <attachment-id-or-uuid>
  attachments.sh download <attachment-id-or-uuid> [-o <output-path>]
  attachments.sh delete <attachment-id-or-uuid>

Common flags:
  --config <path>                  override config.json path
  --server-url URL                 override server_url
  --app-url URL                    override app_url
  --workspace-id UUID              override workspace_id
  --json                           output full JSON instead of human format

Env:
  MULTICA_TOKEN                    override token
  MULTICA_CLI_ORDER_CONFIG         override config path (priority: --config > <skill_dir>/config.json > MULTICA_CLI_ORDER_CONFIG > ~/.multica/config.json)
EOF
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

command -v jq >/dev/null 2>&1 || die "jq is required. Install jq first."
JQ="jq"

# ---- 参数解析 ----
CONFIG_PATH=""
SERVER_URL_OVERRIDE=""
APP_URL_OVERRIDE=""
WORKSPACE_ID_OVERRIDE=""
OUTPUT_JSON=false

SUBCMD=""
FILE_PATH=""
ISSUE_ID=""
COMMENT_ID=""
ATT_ID=""
DOWNLOAD_OUT=""

# 先把全局 flag（可出现在子命令前后）抽出来：先两遍扫
# 第一遍：从前往后，先识别"全局 flag + 子命令"的位置
# 第二遍：从 subcmd 后面再扫一次，把子命令后置的全局 flag 拾起来
ARGS=("$@")
i=0
# 第一遍：扫到第一个不是全局 flag 的位置，那个就是子命令
while [[ $i -lt $# ]]; do
  a="${ARGS[$i]}"
  case "$a" in
    --config)       CONFIG_PATH="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --server-url)   SERVER_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --app-url)      APP_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --workspace-id) WORKSPACE_ID_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --json)         OUTPUT_JSON=true; i=$((i+1)); continue ;;
    -h|--help)      usage; exit 0 ;;
    *) break ;;
  esac
done

if [[ $i -ge $# ]]; then
  usage; exit 1
fi
SUBCMD="${ARGS[$i]}"
i=$((i+1))

# 第二遍：在剩余 arg 里再扫一次全局 flag（允许 --json 等出现在子命令之后）
REMAINING=()
while [[ $i -lt $# ]]; do
  a="${ARGS[$i]}"
  case "$a" in
    --config)       CONFIG_PATH="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --server-url)   SERVER_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --app-url)      APP_URL_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --workspace-id) WORKSPACE_ID_OVERRIDE="${ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
    --json)         OUTPUT_JSON=true; i=$((i+1)); continue ;;
    *) REMAINING+=("$a"); i=$((i+1)) ;;
  esac
done

# 后续子命令解析改用 REMAINING
set -- "${REMAINING[@]+"${REMAINING[@]}"}"
# 重新计数（用 "$#" 不准因为前面改了）
NEW_ARGS=("${REMAINING[@]:-}")
N="${#NEW_ARGS[@]}"

# 决定 config 文件路径
resolve_config_path

# 读 config.json
if [[ ! -f "$CONFIG_PATH" ]]; then
  if [[ "$CONFIG_PATH_IS_DEFAULT" == "true" ]]; then
    die "Multica CLI config not found: $CONFIG_PATH. Run 'multica login' first, or pass --config / MULTICA_CLI_ORDER_CONFIG, or drop a config.json into $SKILL_DIR."
  fi
  die "config file not found: $CONFIG_PATH"
fi
TOKEN="$($JQ -r '.token       // empty' "$CONFIG_PATH")"
SERVER_URL="$($JQ -r '.server_url // empty' "$CONFIG_PATH")"
APP_URL="$($JQ   -r '.app_url    // empty' "$CONFIG_PATH")"
WORKSPACE_ID="$($JQ -r '.workspace_id // empty' "$CONFIG_PATH")"

# $MULTICA_TOKEN 永远最高优先级
[[ -n "${MULTICA_TOKEN:-}" ]] && TOKEN="$MULTICA_TOKEN"

# 命令行覆盖
[[ -n "$SERVER_URL_OVERRIDE"   ]] && SERVER_URL="$SERVER_URL_OVERRIDE"
[[ -n "$APP_URL_OVERRIDE"      ]] && APP_URL="$APP_URL_OVERRIDE"
[[ -n "$WORKSPACE_ID_OVERRIDE" ]] && WORKSPACE_ID="$WORKSPACE_ID_OVERRIDE"

# 校验
[[ -z "$TOKEN"      ]] && die "missing token. Set MULTICA_TOKEN env, or write token into $CONFIG_PATH, or pass --config"
[[ -z "$SERVER_URL" ]] && die "missing server_url. Set server_url in $CONFIG_PATH or pass --server-url"
[[ -z "$WORKSPACE_ID" ]] && die "missing workspace_id. Set workspace_id in $CONFIG_PATH or pass --workspace-id. Attachment operations always require a workspace context."
SERVER_URL="${SERVER_URL%/}"
[[ -z "$APP_URL" ]] && APP_URL="$SERVER_URL"
AUTH_HEADER_FILE="$TMP_DIR/auth-header"
printf 'Authorization: Bearer %s\n' "$TOKEN" > "$AUTH_HEADER_FILE"

# ---- 解析子命令参数 ----
case "$SUBCMD" in
  upload)
    if [[ $N -eq 0 ]]; then die "upload: missing <file>"; fi
    FILE_PATH="${NEW_ARGS[0]}"; i=1
    while [[ $i -lt $N ]]; do
      a="${NEW_ARGS[$i]}"
      case "$a" in
        --issue)   ISSUE_ID="${NEW_ARGS[$((i+1))]}";   i=$((i+2)); continue ;;
        --comment) COMMENT_ID="${NEW_ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
        *) die "upload: unknown flag $a" ;;
      esac
    done
    [[ -n "$FILE_PATH" ]] || die "upload: <file> required"
    [[ -f "$FILE_PATH" ]] || die "upload: file not found: $FILE_PATH"
    # 允许 upload 不绑 issue/comment（拿到的 ID 后续可在创建 issue 时塞进 attachment_ids）
    ;;
  list)
    if [[ $N -eq 0 ]]; then die "list: missing <issue-id-or-uuid>"; fi
    ISSUE_ID="${NEW_ARGS[0]}"
    ;;
  get|delete)
    if [[ $N -eq 0 ]]; then die "$SUBCMD: missing <attachment-id-or-uuid>"; fi
    ATT_ID="${NEW_ARGS[0]}"
    ;;
  download)
    if [[ $N -eq 0 ]]; then die "download: missing <attachment-id-or-uuid>"; fi
    ATT_ID="${NEW_ARGS[0]}"; i=1
    while [[ $i -lt $N ]]; do
      a="${NEW_ARGS[$i]}"
      case "$a" in
        -o|--output) DOWNLOAD_OUT="${NEW_ARGS[$((i+1))]}"; i=$((i+2)); continue ;;
        *) die "download: unknown flag $a" ;;
      esac
    done
    ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown subcommand: $SUBCMD. Try --help." ;;
esac

# ---- /api/me 校验 ----
ME_HTTP=$(curl -sS -o $TMP_DIR/me.json -w "%{http_code}" \
  -H "@$AUTH_HEADER_FILE" \
  -H "X-Client-Platform: multica-cli-skill" \
  -H "X-Client-Version: 0.13.0" \
  -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')" \
  -H "X-Client-Capabilities: stable_attachment_urls" \
  -H "X-Workspace-ID: $WORKSPACE_ID" \
  "$SERVER_URL/api/me?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')" || echo "000")
if [[ "$ME_HTTP" != "200" ]]; then
  cat $TMP_DIR/me.json >&2 || true
  rm -f $TMP_DIR/me.json
  die "/api/me HTTP $ME_HTTP — token invalid or expired."
fi
rm -f $TMP_DIR/me.json

# ---- 工具函数 ----
ws_url() {
  # ws_url <path> [<query>]  → 加 ?workspace_id= 的完整 URL
  local path="$1" q="${2:-}"
  local sep="?"
  if [[ -n "$q" ]]; then
    sep="&"
  fi
  echo -n "$SERVER_URL$path?workspace_id=$($JQ -rn --arg v "$WORKSPACE_ID" '$v|@uri')${q:+&$q}"
}

# resolve_issue_id <id-or-uuid>  → 解析成 UUID（如果是 LRO-N 这种 identifier，调 GET 拿真 UUID）
resolve_id_to_uuid() {
  local kind="$1" id="$2"  # kind=issue/attachment
  if [[ -z "$id" ]]; then echo -n ""; return; fi
  if [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo -n "$id"; return
  fi
  # identifier (LRO-N) → GET /api/issues/<identifier> 拿 id
  local out="$TMP_DIR/resolve.json"
  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$(ws_url "/api/issues/$id")" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "resolve $kind '$id' → HTTP $code"
  fi
  local uuid
  uuid=$($JQ -r '.id // empty' "$out")
  rm -f "$out"
  [[ -n "$uuid" ]] || die "resolve $kind '$id': empty id in response"
  echo -n "$uuid"
}

# ---- 子命令实现 ----
cmd_upload() {
  local issue_uuid="" comment_uuid=""
  [[ -n "$ISSUE_ID"   ]] && issue_uuid="$(resolve_id_to_uuid issue "$ISSUE_ID")"
  [[ -n "$COMMENT_ID" ]] && comment_uuid="$COMMENT_ID"  # comment ID 通常就是 UUID，不做 LRO-style 解析

  # multipart POST /api/upload-file
  local out="$TMP_DIR/upload.json"
  local args=(
    -sS -o "$out" -w "%{http_code}"
    -X POST
    -H "@$AUTH_HEADER_FILE"
    -H "X-Client-Platform: multica-cli-skill"
    -H "X-Client-Version: 0.13.0"
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')"
    -H "X-Client-Capabilities: stable_attachment_urls"
    -H "X-Workspace-ID: $WORKSPACE_ID"
    -F "file=@${FILE_PATH}"
  )
  [[ -n "$issue_uuid"   ]] && args+=(-F "issue_id=${issue_uuid}")
  [[ -n "$comment_uuid" ]] && args+=(-F "comment_id=${comment_uuid}")

  local url code
  url="$(ws_url "/api/upload-file")"
  code=$(curl "${args[@]}" "$url" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "POST /api/upload-file HTTP $code"
  fi

  # 取响应
  local id ctype filename md_url url_field size
  id=$($JQ -r '.id // ""' "$out")
  ctype=$($JQ -r '.content_type // ""' "$out")
  filename=$($JQ -r '.filename // ""' "$out")
  md_url=$($JQ -r '.markdown_url // ""' "$out")
  url_field=$($JQ -r '.url // ""' "$out")
  size=$($JQ -r '.size_bytes // 0' "$out")
  rm -f "$out"

  # markdown snippet（图片 vs 文件）
  local label md_snippet
  label="$filename"
  # 转义 markdown label 里的 [ ] ( ) \
  label=$(echo "$label" | sed -e 's/\\/\\\\/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/(/\\(/g' -e 's/)/\\)/g')
  if [[ "$ctype" == image/* ]]; then
    md_snippet="![${label}](${md_url})"
  else
    md_snippet="!file[${label}](${md_url})"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    $JQ -n --arg id "$id" --arg filename "$filename" --arg content_type "$ctype" \
          --arg markdown_url "$md_url" --arg url "$url_field" \
          --argjson size_bytes "$size" --arg markdown "$md_snippet" \
          --arg issue_id "${issue_uuid:-}" --arg comment_id "${comment_uuid:-}" \
          '{id:$id, filename:$filename, content_type:$content_type, markdown_url:$markdown_url, url:$url, size_bytes:$size_bytes, markdown:$markdown, issue_id:$issue_id, comment_id:$comment_id}'
  else
    cat <<EOF
Uploaded: $filename
  id:           $id
  content_type: $ctype
  size:         $size bytes
  markdown_url: $md_url
  markdown:     $md_snippet
$([ -n "$issue_uuid"   ] && echo "  bound issue:   $issue_uuid")$([ -n "$comment_uuid" ] && echo "  bound comment: $comment_uuid")

# 在 issue description 里嵌入这张图片 / 文件：
$md_snippet
EOF
  fi
}

cmd_list() {
  local uuid
  uuid="$(resolve_id_to_uuid issue "$ISSUE_ID")"
  local out="$TMP_DIR/list.json"
  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$(ws_url "/api/issues/$uuid/attachments")" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "GET /api/issues/$uuid/attachments HTTP $code"
  fi

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$out"
  else
    local n
    n=$($JQ 'length' "$out")
    echo "Issue $ISSUE_ID ($uuid): $n attachment(s)"
    if [[ "$n" -gt 0 ]]; then
      $JQ -r '.[] | "  [\(.id[0:8])…] \(.filename) (\(.content_type), \(.size_bytes) B)\n    markdown_url: \(.markdown_url)"' "$out"
    fi
  fi
  rm -f "$out"
}

cmd_get() {
  local out="$TMP_DIR/get.json"
  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$(ws_url "/api/attachments/$ATT_ID")" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "GET /api/attachments/$ATT_ID HTTP $code"
  fi
  if [[ "$OUTPUT_JSON" == "true" ]]; then
    cat "$out"
  else
    $JQ . "$out"
  fi
  rm -f "$out"
}

cmd_delete() {
  local out="$TMP_DIR/del.json"
  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -X DELETE \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    -H "X-Workspace-ID: $WORKSPACE_ID" \
    "$(ws_url "/api/attachments/$ATT_ID")" || echo "000")
  if [[ "$code" != "200" && "$code" != "204" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "DELETE /api/attachments/$ATT_ID HTTP $code"
  fi
  echo "Deleted attachment $ATT_ID (HTTP $code)"
  rm -f "$out"
}

cmd_download() {
  # 1) 元信息 + 新签的下载 URL（GET /api/attachments/{id}/download-metadata）
  #    路由按附件行自解析 workspace（与 /download 同款），跨 workspace 引用也能解析。
  local out="$TMP_DIR/meta.json"
  local code
  code=$(curl -sS -o "$out" -w "%{http_code}" \
    -H "@$AUTH_HEADER_FILE" \
    -H "X-Client-Platform: multica-cli-skill" \
    -H "X-Client-Version: 0.13.0" \
    -H "X-Client-OS: $(uname -s | tr '[:upper:]' '[:lower:]')" \
    -H "X-Client-Capabilities: stable_attachment_urls" \
    "$SERVER_URL/api/attachments/$ATT_ID/download-metadata" || echo "000")
  if [[ "$code" != "200" ]]; then
    cat "$out" >&2 || true
    rm -f "$out"
    die "GET /api/attachments/$ATT_ID/download-metadata HTTP $code"
  fi

  local filename signed_url
  filename=$($JQ -r '.filename // "attachment"' "$out")
  # attachment_download_url 强制 Content-Disposition: attachment；缺省回退 download_url
  signed_url=$($JQ -r '.attachment_download_url // .download_url // empty' "$out")
  if [[ -z "$signed_url" ]]; then
    rm -f "$out"
    die "no downloadable URL in metadata response (empty attachment_download_url/download_url)"
  fi
  # 相对路径 → 绝对（挂在 server 上）
  if [[ "$signed_url" == /* ]]; then
    signed_url="$SERVER_URL$signed_url"
  fi

  # 2) 默认输出文件名 = 附件名（防止路径穿越：取 basename）
  local target="${DOWNLOAD_OUT:-$filename}"
  target="${target//\\//}"
  target="${target##*/}"
  [[ -z "$target" ]] && target="attachment"

  # 3) 下载（签名 URL 不带 Authorization）
  local dl_code
  dl_code=$(curl -sS -L -o "$target" -w "%{http_code}" "$signed_url" || echo "000")
  if [[ "$dl_code" != "200" ]]; then
    rm -f "$target"
    die "download failed: HTTP $dl_code"
  fi

  local size ctype
  size=$($JQ -r '.size_bytes // 0' "$out")
  ctype=$($JQ -r '.content_type // ""' "$out")
  rm -f "$out"

  if [[ "$OUTPUT_JSON" == "true" ]]; then
    $JQ -n --arg id "$ATT_ID" --arg file "$target" --arg name "$filename" \
      --arg ctype "$ctype" --argjson size "$size" \
      '{id:$id, saved_to:$file, filename:$name, content_type:$ctype, size_bytes:$size}'
  else
    cat <<EOF
Downloaded: $filename
  saved_to:     $target
  content_type: $ctype
  size:         $size bytes
EOF
  fi
}

# ---- dispatch ----
case "$SUBCMD" in
  upload)   cmd_upload ;;
  list)     cmd_list ;;
  get)      cmd_get ;;
  download) cmd_download ;;
  delete)   cmd_delete ;;
esac