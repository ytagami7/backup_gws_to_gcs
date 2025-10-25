#!/bin/bash

################################################################################
# GWS to GCS Backup Script (Base + Incremental + Shared Drives) - NO LOOP v2
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
# --- 変更履歴 ---
# v2 (2025-10-25):
#   - *.nefファイルを除外パターンに追加
#   - 無限ループ対策を強化（問題フォルダを直接除外）
#   - --max-depthを100から20に変更
#
################################################################################

set -euo pipefail

#==============================================================================
# 引数解析
#==============================================================================

TEST_MODE=false
DRY_RUN=false

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

# バックアップ対象のユーザーメールアドレス（マイドライブ）
USERS=(
  "a.ohsaki@ycomps.co.jp"
  "a.tanaka@ycomps.co.jp"
  "aikawa@ycomps.co.jp"
  "k.koyama@ycomps.co.jp"
  "tutida@ycomps.co.jp"
  "ytagami@ycomps.co.jp"
)

# 共有ドライブ設定
SHARED_DRIVES=(
#  "Archive"
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

# 共有ドライブIDマッピングファイル
SHARED_DRIVE_MAPPING_FILE="/home/ytagami/shared_drive_mapping.txt"

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
  "www*/**"
)

# 無限ループ防止: 問題のあるフォルダを直接除外
LOOP_PREVENTION_EXCLUDES=(
  "**/仁村gdriveファイル/**"
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

# 無限ループ対策: 深さ制限を20に設定（旧: 100）
RCLONE_MAX_DEPTH=20

 # テストモード: 転送量制限（100MB）
TEST_MAX_TRANSFER="100M"

 # 共有ドライブアクセス用の管理者
 ADMIN_USER="ytagami@ycomps.co.jp"

#==============================================================================
# モード判定
#==============================================================================

PRODUCTION_MODE=true
if [ "$TEST_MODE" = true ] || [ "$DRY_RUN" = true ]; then
  PRODUCTION_MODE=false
fi

MODE_INFO="Normal Mode"
if [ "$TEST_MODE" = true ]; then
  MODE_INFO="TEST MODE (max transfer: $TEST_MAX_TRANSFER per user/drive)"
fi
if [ "$DRY_RUN" = true ]; then
  MODE_INFO="$MODE_INFO + DRY-RUN (no actual transfer)"
fi

#==============================================================================





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
  
  # 通常の除外パターン
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    flags+=(--exclude "$pattern")
  done
  
  # 無限ループ防止の除外パターン
  for pattern in "${LOOP_PREVENTION_EXCLUDES[@]}"; do
    flags+=(--exclude "$pattern")
  done
  
  echo "${flags[@]}"
}

EXCLUDE_FLAGS=($(build_exclude_flags))

#==============================================================================
# 共有ドライブID取得・マッピング関数
#==============================================================================

get_shared_drive_id() {
  local drive_name=$1
  
  # マッピングファイルから既存のIDを検索
  if [ -f "$SHARED_DRIVE_MAPPING_FILE" ]; then
    local existing_id=$(grep "^${drive_name}:" "$SHARED_DRIVE_MAPPING_FILE" 2>/dev/null | cut -d':' -f2)
    if [ -n "$existing_id" ]; then
      echo "$existing_id"
      return 0
    fi
  fi
  
  # IDが見つからない場合、rcloneで取得
  log "🔍 共有ドライブIDを取得中: $drive_name"
  
  local drive_list=$(rclone backend drives "${RCLONE_REMOTE_NAME}:" \
    --drive-impersonate "$ADMIN_USER" 2>/dev/null)
  
  # JSONから該当する名前のIDを抽出
  local drive_id=$(echo "$drive_list" | grep -B1 "\"name\": \"${drive_name}\"" | grep "\"id\"" | sed 's/.*"id": "\([^"]*\)".*/\1/')
  
  if [ -z "$drive_id" ]; then
    log "❌ ERROR: 共有ドライブが見つかりません: $drive_name"
    return 1
  fi
  
  # マッピングファイルに保存
  echo "${drive_name}:${drive_id}" >> "$SHARED_DRIVE_MAPPING_FILE"
  log "✅ 共有ドライブID取得成功: $drive_name = $drive_id"
  
  echo "$drive_id"
  return 0
}

#==============================================================================
# 初回判定関数（マイドライブ用）
#==============================================================================

is_first_backup_mydrive() {
  local user=$1
  local safe_user=$2
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base/"
  
  if rclone lsf "$base_path" --max-depth 1 2>/dev/null | grep -q .; then
    return 1
  else
    return 0
  fi
}

#==============================================================================
# 初回判定関数（共有ドライブ用）
#==============================================================================

is_first_backup_shared() {
  local safe_drive_name=$1
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/base/"
  
  if rclone lsf "$base_path" --max-depth 1 2>/dev/null | grep -q .; then
    return 1
  else
    return 0
  fi
}

#==============================================================================
# マイドライブバックアップ関数
#==============================================================================

backup_user_mydrive() {
  local user=$1
  
  log "=========================================="
  log "Processing MyDrive: $user"
  log "=========================================="
  
  local safe_user=$(echo "$user" | sed 's/@/_AT_/g' | sed 's/\./_DOT_/g')
  
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base/"
  local incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/incremental/${BACKUP_DATE}/"
  local cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/CUMULATIVE_DELETED.txt"
  
  if is_first_backup_mydrive "$user" "$safe_user"; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$base_path"
      --drive-impersonate "$user"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --skip-links
      --max-depth $RCLONE_MAX_DEPTH
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
      "${EXCLUDE_FLAGS[@]}"
    )
    
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
    fi
    
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    log "Executing: rclone copy (無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH + 問題フォルダ除外)"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Backup failed for user $user (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 初回バックアップ完了 for user $user"
    fi
    
    if [ "$PRODUCTION_MODE" = true ]; then
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    log "🔄 増分バックアップ: 過去24時間の変更のみ"
    log "Backup destination: $incr_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$incr_path"
      --drive-impersonate "$user"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age 24h
      --skip-links
      --max-depth $RCLONE_MAX_DEPTH
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
      "${EXCLUDE_FLAGS[@]}"
    )
    
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
    fi
    
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    log "Executing: rclone copy (無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH + 問題フォルダ除外)"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Incremental backup failed for user $user (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 増分バックアップ完了 for user $user"
    fi
    
    if [ "$PRODUCTION_MODE" = true ]; then
      log "🔍 削除ファイル検知中..."
      
      local tmp_base="/tmp/base_files_${safe_user}.txt"
      local tmp_current="/tmp/current_files_${safe_user}.txt"
      local tmp_deleted_today="/tmp/deleted_today_${safe_user}.txt"
      local tmp_cumulative_old="/tmp/cumulative_old_${safe_user}.txt"
      local tmp_cumulative_new="/tmp/cumulative_new_${safe_user}.txt"
      
      rclone lsf "$base_path" \
        --files-only \
        --recursive \
        --format "p" 2>/dev/null | sort > "$tmp_base"
      
      rclone lsf "${RCLONE_REMOTE_NAME}:/" \
        --drive-impersonate "$user" \
        --files-only \
        --recursive \
        --format "p" 2>/dev/null | sort > "$tmp_current"
      
      comm -23 "$tmp_base" "$tmp_current" > "$tmp_deleted_today"
      
      if [ -s "$tmp_deleted_today" ]; then
        local deleted_count=$(wc -l < "$tmp_deleted_today")
        log "📝 削除ファイル検出: ${deleted_count}件"
        gsutil cp "$tmp_deleted_today" "gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/incremental/${BACKUP_DATE}/DELETED_FILES.txt"
      else
        log "ℹ️  削除ファイルなし"
      fi
      
      log "📊 累積削除リスト更新中..."
      
      gsutil cp "$cumulative_deleted_path" "$tmp_cumulative_old" 2>/dev/null || touch "$tmp_cumulative_old"
      
      cat "$tmp_cumulative_old" "$tmp_deleted_today" | grep -v '^$' | sort | uniq > "$tmp_cumulative_new"
      
      comm -23 "$tmp_cumulative_new" "$tmp_current" > "${tmp_cumulative_new}.final"
      
      gsutil cp "${tmp_cumulative_new}.final" "$cumulative_deleted_path"
      
      local cumulative_count=$(wc -l < "${tmp_cumulative_new}.final" 2>/dev/null || echo 0)
      log "✅ 累積削除リスト更新完了: 合計${cumulative_count}件"
      
      rm -f "$tmp_base" "$tmp_current" "$tmp_deleted_today" "$tmp_cumulative_old" "$tmp_cumulative_new" "${tmp_cumulative_new}.final"
    fi
  fi
  
  log "✅ ユーザー処理完了: $user"
}

#==============================================================================
# 共有ドライブバックアップ関数
#==============================================================================

backup_shared_drive() {
  local drive_name=$1
  
  log "=========================================="
  log "Processing Shared Drive: $drive_name"
  log "=========================================="
  
  local drive_id=$(get_shared_drive_id "$drive_name")
  if [ -z "$drive_id" ]; then
    log "❌ ERROR: 共有ドライブIDの取得に失敗: $drive_name"
    return 1
  fi
  
  log "共有ドライブID: $drive_id"
  
  local safe_drive_name=$(echo "$drive_name" | sed 's/[^a-zA-Z0-9]/_/g')
  
  local base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/base/"
  local incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/incremental/${BACKUP_DATE}/"
  local cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/CUMULATIVE_DELETED.txt"
  
  if is_first_backup_shared "$safe_drive_name"; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$base_path"
      --drive-impersonate "$ADMIN_USER"
    #  --drive-shared-with-me
      --drive-root-folder-id "$drive_id"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --skip-links
      --max-depth $RCLONE_MAX_DEPTH
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
      "${EXCLUDE_FLAGS[@]}"
    )
    
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
    fi
    
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    log "Executing: rclone copy (無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH + 問題フォルダ除外)"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Backup failed for shared drive $drive_name (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 初回バックアップ完了 for shared drive $drive_name"
    fi
    
    if [ "$PRODUCTION_MODE" = true ]; then
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    log "🔄 増分バックアップ: 過去24時間の変更のみ"
    log "Backup destination: $incr_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$incr_path"
      --drive-impersonate "$ADMIN_USER"
    #  --drive-shared-with-me
      --drive-root-folder-id "$drive_id"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age 24h
      --skip-links
      --max-depth $RCLONE_MAX_DEPTH
      --transfers $RCLONE_TRANSFERS
      --checkers $RCLONE_CHECKERS
      --drive-chunk-size $RCLONE_CHUNK_SIZE
      --tpslimit $RCLONE_TPS_LIMIT
      --timeout $RCLONE_TIMEOUT
      --retries $RCLONE_RETRIES
      --create-empty-src-dirs
      --progress
      "${EXCLUDE_FLAGS[@]}"
    )
    
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
    fi
    
    if [ "$DRY_RUN" = true ]; then
      rclone_opts+=(--dry-run)
    fi
    
    log "Executing: rclone copy (無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH + 問題フォルダ除外)"
    rclone copy "${rclone_opts[@]}"
    local result=$?
    
    if [ $result -ne 0 ]; then
      log "❌ ERROR: Incremental backup failed for shared drive $drive_name (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 増分バックアップ完了 for shared drive $drive_name"
    fi
    
    if [ "$PRODUCTION_MODE" = true ]; then
      log "🔍 削除ファイル検知中..."
      
      local tmp_base="/tmp/base_files_shared_${safe_drive_name}.txt"
      local tmp_current="/tmp/current_files_shared_${safe_drive_name}.txt"
      local tmp_deleted_today="/tmp/deleted_today_shared_${safe_drive_name}.txt"
      local tmp_cumulative_old="/tmp/cumulative_old_shared_${safe_drive_name}.txt"
      local tmp_cumulative_new="/tmp/cumulative_new_shared_${safe_drive_name}.txt"
      
      rclone lsf "$base_path" \
        --files-only \
        --recursive \
        --format "p" 2>/dev/null | sort > "$tmp_base"
      
      rclone lsf "${RCLONE_REMOTE_NAME}:/" \
        --drive-impersonate "$ADMIN_USER" \
      #  --drive-shared-with-me \
        --drive-root-folder-id "$drive_id" \
        --files-only \
        --recursive \
        --format "p" 2>/dev/null | sort > "$tmp_current"
      
      comm -23 "$tmp_base" "$tmp_current" > "$tmp_deleted_today"
      
      if [ -s "$tmp_deleted_today" ]; then
        local deleted_count=$(wc -l < "$tmp_deleted_today")
        log "📝 削除ファイル検出: ${deleted_count}件"
        gsutil cp "$tmp_deleted_today" "gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/incremental/${BACKUP_DATE}/DELETED_FILES.txt"
      else
        log "ℹ️  削除ファイルなし"
      fi
      
      log "📊 累積削除リスト更新中..."
      
      gsutil cp "$cumulative_deleted_path" "$tmp_cumulative_old" 2>/dev/null || touch "$tmp_cumulative_old"
      
      cat "$tmp_cumulative_old" "$tmp_deleted_today" | grep -v '^$' | sort | uniq > "$tmp_cumulative_new"
      
      comm -23 "$tmp_cumulative_new" "$tmp_current" > "${tmp_cumulative_new}.final"
      
      gsutil cp "${tmp_cumulative_new}.final" "$cumulative_deleted_path"
      
      local cumulative_count=$(wc -l < "${tmp_cumulative_new}.final" 2>/dev/null || echo 0)
      log "✅ 累積削除リスト更新完了: 合計${cumulative_count}件"
      
      rm -f "$tmp_base" "$tmp_current" "$tmp_deleted_today" "$tmp_cumulative_old" "$tmp_cumulative_new" "${tmp_cumulative_new}.final"
    fi
  fi
  
  log "✅ 共有ドライブ処理完了: $drive_name"
}

#==============================================================================
# メイン処理
#==============================================================================

log "=========================================="
log "GWS to GCS Backup Started (MyDrive + Shared Drives) v2"
log "Date: $(date)"
log "Mode: $MODE_INFO"
log "無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH"
log "除外フォルダ: ${LOOP_PREVENTION_EXCLUDES[*]}"
log "NEFファイル除外: 有効"
log "=========================================="

if [ "$PRODUCTION_MODE" = true ]; then
  log "⚠️  PRODUCTION MODE: Instance will shutdown ${SHUTDOWN_DELAY}s after completion"
  log "   To cancel shutdown, run: sudo shutdown -c"
else
  log "ℹ️  TEST/DRY-RUN MODE: Auto-shutdown is DISABLED"
fi

# マイドライブバックアップ
log ""
log "=========================================="
log "Phase 1: MyDrive Backup"
log "=========================================="

for user in "${USERS[@]}"; do
  backup_user_mydrive "$user" || log "⚠️  Warning: Failed to backup MyDrive for $user, continuing..."
done

# 共有ドライブバックアップ
log ""
log "=========================================="
log "Phase 2: Shared Drives Backup"
log "=========================================="

for drive_name in "${SHARED_DRIVES[@]}"; do
  backup_shared_drive "$drive_name" || log "⚠️  Warning: Failed to backup Shared Drive $drive_name, continuing..."
done

log ""
log "=========================================="
log "GWS to GCS Backup Completed (MyDrive + Shared Drives) v2"
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
