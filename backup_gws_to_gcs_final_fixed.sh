#!/bin/bash

################################################################################
# GWS to GCS Backup Script (Base + Incremental + Cumulative Deletion)
################################################################################
#
# --- 使用方法 ---
# 通常実行:     ./backup_gws_to_gcs.sh
# テストモード:  ./backup_gws_to_gcs.sh --test
# Dry-runモード: ./backup_gws_to_gcs.sh --dry-run
# 両方:         ./backup_gws_to_gcs.sh --test --dry-run
#
# --- シャットダウンのキャンセル方法 ---
# 本番モード実行時、バックアップ完了後300秒でシャットダウンされます。
# キャンセルする場合は、別のターミナルで以下を実行してください:
#
#   sudo shutdown -c
#
# または、このスクリプトをCtrl+Cで中断してください。
#
################################################################################

set -euo pipefail

#==============================================================================
# 引数解析
#==============================================================================

TEST_MODE=false
DRY_RUN=false
MAX_FILES_PER_USER=100

while [[ $# -gt 0 ]]; do
  case $1 in
    --test)
      TEST_MODE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--test] [--dry-run]"
      exit 1
      ;;
  esac
done

#==============================================================================
# 設定項目
#==============================================================================

# GCS設定
GCS_BUCKET="yps-gws-backup-bucket-20251022"
GCS_BACKUP_ROOT="BACKUP"

# rclone設定
RCLONE_REMOTE_NAME="gdrive_service_account"

# バックアップ対象のユーザーメールアドレス
USERS=(
  "a.ohsaki@ycomps.co.jp"
  "a.tanaka@ycomps.co.jp"
  "aikawa@ycomps.co.jp"
  "k.koyama@ycomps.co.jp"
  "tutida@ycomps.co.jp"
  "ytagami@ycomps.co.jp"
)

# 共有ドライブ設定（実際に存在するドライブ）
SHARED_DRIVES=(
  "HP制作"
  "HP保守"
  "業務全般"
  "YPS共有ドライブ（新）"
  "個人ドライブ移行用"
  "管理（総務・経理）"
  "YPS Ops Guard Backup"
  "顧客とのファイル共有"
  "システム事業"
  "研修用テストドライブ"
)

# 除外ファイルパターン
EXCLUDE_PATTERNS=(
  "*.zip"
  "*.tar"
  "*.gz"
  "*.rar"
  "*.7z"
  "*.tar.gz"
  "*.tgz"
  "*.exe"
  "*.msi"
  "*.app"
  "*.dmg"
  "*.mp4"
  "*.avi"
  "*.mov"
  "*.mkv"
  "*.wmv"
  "*.flv"
  "*.webm"
  "*.mp3"
  "*.wav"
  "*.flac"
  "*.aac"
  "*.m4a"
  "*.ogg"
  "*.wma"
  "*.nef"
  "*.NEF"
  "www*/**"
  "wp-*/**"
  "wp-content/cache/**"
  "wp-content/uploads/cache/**"
  "wp-content/backup*/**"
  "wp-content/backup-*/**"
  "wp-content/upgrade/**"
  "wp-content/debug.log"
  "wp-config-sample.php"
  "wp-content/plugins/hello.php"
  "wp-content/themes/twenty*/**"
)

# ログ設定
LOG_FILE="/home/ytagami/backup_gws.log"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DATE=$(date +%Y%m%d)

# シャットダウン待機時間（秒）
SHUTDOWN_DELAY=300

# rclone転送設定
RCLONE_TRANSFERS=4
RCLONE_CHECKERS=8
RCLONE_CHUNK_SIZE="64M"
RCLONE_TPS_LIMIT=10
RCLONE_TIMEOUT="3h"
RCLONE_RETRIES=3

#==============================================================================
# モード判定
#==============================================================================

PRODUCTION_MODE=true
if [ "$TEST_MODE" = true ] || [ "$DRY_RUN" = true ]; then
  PRODUCTION_MODE=false
fi

MODE_INFO="Normal Mode"
if [ "$TEST_MODE" = true ]; then
  MODE_INFO="TEST MODE (max $MAX_FILES_PER_USER files per user)"
fi
if [ "$DRY_RUN" = true ]; then
  MODE_INFO="$MODE_INFO + DRY-RUN (no actual transfer)"
fi

#==============================================================================
# ログ関数
#==============================================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

#==============================================================================
# 除外フィルタ生成
#==============================================================================

build_exclude_flags() {
  local flags=()
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    flags+=(--exclude "$pattern")
  done
  echo "${flags[@]}"
}

EXCLUDE_FLAGS=($(build_exclude_flags))

#==============================================================================
# 共有ドライブID取得関数
#==============================================================================

get_shared_drive_id() {
  local drive_name="$1"
  
  # マッピングファイルのパス
  local mapping_file="/home/ytagami/shared_drive_mapping.txt"
  
  # マッピングファイルが存在する場合、検索
  if [ -f "$mapping_file" ]; then
    local drive_id=$(grep "^${drive_name}:" "$mapping_file" | cut -d':' -f2)
    if [ -n "$drive_id" ]; then
      echo "$drive_id"
      return 0
    fi
  fi
  
  # マッピングが見つからない場合、rcloneから取得
  log "🔍 共有ドライブID取得中: ${drive_name}"
  
  local drive_id=$(rclone lsd "${RCLONE_REMOTE_NAME}:" \
    --drive-shared-with-me \
    --drive-impersonate "ytagami@ycomps.co.jp" \
    -q 2>/dev/null | grep -F "$drive_name" | awk '{print $NF}' | head -n1)
  
  if [ -z "$drive_id" ]; then
    log "❌ 共有ドライブID取得失敗: ${drive_name}"
    return 1
  fi
  
  # マッピングファイルに保存
  mkdir -p "$(dirname "$mapping_file")"
  echo "${drive_name}:${drive_id}" >> "$mapping_file"
  log "✅ マッピング保存: ${drive_name} -> ${drive_id}"
  
  echo "$drive_id"
}

#==============================================================================
# 初回判定関数
#==============================================================================

is_first_backup() {
  local user=$1
  local safe_user=$2
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_user}/base/"
  
  # baseフォルダが存在するか確認
  if rclone lsf "$base_path" --max-depth 1 2>/dev/null | grep -q .; then
    return 1  # 既にbaseが存在（初回ではない）
  else
    return 0  # baseが存在しない（初回）
  fi
}

#==============================================================================
# バックアップ関数
#==============================================================================

backup_user() {
  local user=$1
  
  log "=========================================="
  log "Processing user: $user"
  log "=========================================="
  
  # メールアドレスを安全な文字列に変換
  local safe_user=$(echo "$user" | sed 's/@/_AT_/g' | sed 's/\./_DOT_/g')
  
  # パス設定
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_user}/base/"
  local incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_user}/incremental/${BACKUP_DATE}/"
  local cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_user}/CUMULATIVE_DELETED.txt"
  
  # 初回判定
  if is_first_backup "$user" "$safe_user"; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    # 基本オプション
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$base_path"
      --drive-impersonate "$user"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
    )
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      rclone lsf "${RCLONE_REMOTE_NAME}:/" \
        --drive-impersonate "$user" \
        --files-only -R 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      rclone_opts+=("${EXCLUDE_FLAGS[@]}")
    fi
    
    # Dry-runモード
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    # rclone copy実行
    log "Executing: rclone copy ${rclone_opts[*]}"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    # テストモードの一時ファイル削除
    if [ "$TEST_MODE" = true ]; then
      rm -f "$temp_file"
    fi
    
    # エラーチェック
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Backup failed for user $user (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 初回バックアップ完了 for user $user"
    fi
    
    # 累積削除リストを初期化（空ファイル）
    if [ "$PRODUCTION_MODE" = true ]; then
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    log "🔄 増分バックアップ: 過去24時間の変更のみ"
    log "Backup destination: $incr_path"
    
    # 基本オプション
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$incr_path"
      --drive-impersonate "$user"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age 24h
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
    )
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      rclone lsf "${RCLONE_REMOTE_NAME}:/" \
        --drive-impersonate "$user" \
        --files-only -R \
        --max-age 24h 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      rclone_opts+=("${EXCLUDE_FLAGS[@]}")
    fi
    
    # Dry-runモード
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    # rclone copy実行
    log "Executing: rclone copy ${rclone_opts[*]}"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    # テストモードの一時ファイル削除
    if [ "$TEST_MODE" = true ]; then
      rm -f "$temp_file"
    fi
    
    # エラーチェック
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Incremental backup failed for user $user (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 増分バックアップ完了 for user $user"
    fi
    
    # 削除ファイル検知（本番モードのみ）
    if [ "$PRODUCTION_MODE" = true ]; then
#      log "🔍 削除ファイル検知中..."
#      
#      # 一時ファイル
#      local tmp_base="/tmp/base_files_${safe_user}.txt"
#      local tmp_current="/tmp/current_files_${safe_user}.txt"
#      local tmp_deleted_today="/tmp/deleted_today_${safe_user}.txt"
#      local tmp_cumulative_old="/tmp/cumulative_old_${safe_user}.txt"
#      local tmp_cumulative_new="/tmp/cumulative_new_${safe_user}.txt"
#      
#      # baseのファイル一覧
#      rclone lsf "$base_path" \
#        --files-only \
#        --recursive \
#        --format "p" 2>/dev/null | sort > "$tmp_base"
#      
#      # 現在のGoogle Driveファイル一覧
#      rclone lsf "${RCLONE_REMOTE_NAME}:/" \
#        --drive-impersonate "$user" \
#        --files-only \
#        --recursive \
#        --format "p" 2>/dev/null | sort > "$tmp_current"
#      
#      # 今日削除されたファイル
#      comm -23 "$tmp_base" "$tmp_current" > "$tmp_deleted_today"
#      
#      # 今日の削除リストを保存
#      if [ -s "$tmp_deleted_today" ]; then
#        local deleted_count=$(wc -l < "$tmp_deleted_today")
#        log "📝 削除ファイル検出: ${deleted_count}件"
#        gsutil cp "$tmp_deleted_today" "gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_user}/incremental/${BACKUP_DATE}/DELETED_FILES.txt"
#      else
#        log "ℹ️  削除ファイルなし"
#      fi
#      
#      # 累積削除リスト更新
#      log "📊 累積削除リスト更新中..."
#      
#      # 既存の累積リストをダウンロード
#      gsutil cp "$cumulative_deleted_path" "$tmp_cumulative_old" 2>/dev/null || touch "$tmp_cumulative_old"
#      
#      # 今日の削除を追加してユニーク化
#      cat "$tmp_cumulative_old" "$tmp_deleted_today" | grep -v '^$' | sort | uniq > "$tmp_cumulative_new"
#      
#      # 現在存在するファイルは累積リストから除外（復活したファイル対応）
#      comm -23 "$tmp_cumulative_new" "$tmp_current" > "${tmp_cumulative_new}.final"
#      
#      # 累積リストをアップロード
#      gsutil cp "${tmp_cumulative_new}.final" "$cumulative_deleted_path"
#      
#      local cumulative_count=$(wc -l < "${tmp_cumulative_new}.final" 2>/dev/null || echo 0)
#      log "✅ 累積削除リスト更新完了: 合計${cumulative_count}件"
#      
#      # クリーンアップ
#      rm -f "$tmp_base" "$tmp_current" "$tmp_deleted_today" "$tmp_cumulative_old" "$tmp_cumulative_new" "${tmp_cumulative_new}.final"
      log "ℹ️  削除ファイル検知機能は無効化されています"
    fi
  fi
  
  log "✅ ユーザー処理完了: $user"
}

#==============================================================================
# 共有ドライブバックアップ関数
#==============================================================================

backup_shared_drive() {
  local drive_name="$1"
  local safe_name=$(echo "$drive_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
  local drive_id=$(get_shared_drive_id "$drive_name")
  
  if [ -z "$drive_id" ]; then
    log "⚠️  スキップ: ${drive_name} (ID未発見)"
    return 1
  fi
  
  log "=========================================="
  log "Processing shared drive: $drive_name"
  log "=========================================="
  
  # パス設定
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/base/"
  local incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/incremental/${BACKUP_DATE}/"
  
  # 初回判定
  if rclone lsd "$base_path" &>/dev/null; then
    log "🔄 増分バックアップ: 過去24時間の変更のみ"
    log "Backup destination: $incr_path"
    
    # 基本オプション
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:"
      "$incr_path"
      --drive-shared-with-me
      --drive-root-folder-id "$drive_id"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age 24h
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
    )
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      rclone lsf "${RCLONE_REMOTE_NAME}:" \
        --drive-shared-with-me \
        --drive-root-folder-id "$drive_id" \
        --files-only -R \
        --max-age 24h 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      rclone_opts+=("${EXCLUDE_FLAGS[@]}")
    fi
    
    # Dry-runモード
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    # rclone copy実行
    log "Executing: rclone copy ${rclone_opts[*]}"
    rclone copy "${rclone_opts[@]}"
    
    if [ $? -eq 0 ]; then
      log "✅ SUCCESS: 増分バックアップ完了 for shared drive $drive_name"
    else
      log "❌ ERROR: Incremental backup failed for shared drive $drive_name (exit code: $?)"
      return 1
    fi
    
  else
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    # 基本オプション
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:"
      "$base_path"
      --drive-shared-with-me
      --drive-root-folder-id "$drive_id"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
    )
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      rclone lsf "${RCLONE_REMOTE_NAME}:" \
        --drive-shared-with-me \
        --drive-root-folder-id "$drive_id" \
        --files-only -R 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      rclone_opts+=("${EXCLUDE_FLAGS[@]}")
    fi
    
    # Dry-runモード
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    # rclone copy実行
    log "Executing: rclone copy ${rclone_opts[*]}"
    rclone copy "${rclone_opts[@]}"
    
    if [ $? -eq 0 ]; then
      log "✅ SUCCESS: 初回バックアップ完了 for shared drive $drive_name"
    else
      log "❌ ERROR: Backup failed for shared drive $drive_name (exit code: $?)"
      return 1
    fi
  fi
  
  log "✅ 共有ドライブ処理完了: $drive_name"
}

#==============================================================================
# メイン処理
#==============================================================================

log "=========================================="
log "GWS to GCS Backup Started"
log "Date: $(date)"
log "Mode: $MODE_INFO"
log "=========================================="

if [ "$PRODUCTION_MODE" = true ]; then
  log "⚠️  PRODUCTION MODE: Instance will shutdown ${SHUTDOWN_DELAY}s after completion"
  log "   To cancel shutdown, run: sudo shutdown -c"
else
  log "ℹ️  TEST/DRY-RUN MODE: Auto-shutdown is DISABLED"
fi

# 全ユーザーをバックアップ
for user in "${USERS[@]}"; do
  backup_user "$user" || log "⚠️  Warning: Failed to backup $user, continuing..."
done

# 共有ドライブをバックアップ
log ""
log "=========================================="
log "Backing up Shared Drives"
log "=========================================="
for drive_name in "${SHARED_DRIVES[@]}"; do
  backup_shared_drive "$drive_name" || log "⚠️  Warning: Failed to backup shared drive $drive_name, continuing..."
done

log ""
log "=========================================="
log "GWS to GCS Backup Completed"
log "Date: $(date)"
log "Mode: $MODE_INFO"
log "=========================================="

#==============================================================================
# バックアップ完了後の処理
#==============================================================================

if [ "$PRODUCTION_MODE" = true ]; then
  log ""
  log "⚠️  PRODUCTION MODE: Scheduling system shutdown in ${SHUTDOWN_DELAY} seconds..."
  log "🕐 Shutdown scheduled at $(date -d "+${SHUTDOWN_DELAY} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
  log "   To cancel, run: sudo shutdown -c"
  log "   Or press Ctrl+C to interrupt this script."
  
  sleep $SHUTDOWN_DELAY
  
  log "🔌 Initiating system shutdown now..."
  sudo shutdown -h now
else
  log ""
  log "ℹ️  TEST/DRY-RUN MODE: Skipping auto-shutdown (instance remains running)"
  log "   This allows you to review results and logs."
fi

exit 0