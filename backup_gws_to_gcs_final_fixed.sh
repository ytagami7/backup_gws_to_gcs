#!/bin/bash

################################################################################
# GWS to GCS Backup Script (Base + Incremental + Shared Drives) - v7
################################################################################
#
# --- 使用方法 ---
# 通常実行:     ./backup_gws_to_gcs.sh
# テストモード:  ./backup_gws_to_gcs.sh --test
# Dry-runモード: ./backup_gws_to_gcs.sh --dry-run
# Base再構築:   ./backup_gws_to_gcs.sh --rebuild-base
#
# --- シャットダウンのキャンセル方法 ---
# 本番モード実行時、バックアップ完了後300秒でシャットダウンされます。
# キャンセルする場合は、別のターミナルで以下を実行してください:
#
#   sudo shutdown -c
#
# --- 変更履歴 ---
# v7 (2025-10-25):
#   - フォルダ名生成をBase64エンコードに変更（日本語対応）
#   - デバッグログ追加（変換後のフォルダ名を出力）
#   - 空白フォルダ名の問題を修正
#
# v6 (2025-10-25):
#   - テストモードに --cutoff-mode hard を追加（時間制限で強制停止）
#   -10秒経過で即座に停止するように改善
#
# v5 (2025-10-25):
#   - テストモードに時間制限を追加（--max-duration 10s）
#   - ファイル数の爆発を防止
#
# v4 (2025-10-25):
#   - --max-age 自動延長機能を追加（実行漏れを自動検知して延長）
#   - --rebuild-base オプションを追加（年1回のbase再構築用）
#   - 最大延長期間を30日に制限
#
################################################################################

set -euo pipefail

#==============================================================================
# 引数解析
#==============================================================================

TEST_MODE=false
DRY_RUN=false
REBUILD_BASE=false

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
    --rebuild-base)
      REBUILD_BASE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--test] [--dry-run] [--rebuild-base]"
      exit 1
      ;;
  esac
done

#==============================================================================
# 設定項目
#==============================================================================

# GCS設定
GCS_REMOTE="gcs_backup:yps-gws-backup-bucket-20251022"  
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
  # 圧縮ファイル
  "*.zip"
  "*.tar"
  "*.gz"
  "*.rar"
  "*.7z"
  "*.tar.gz"
  "*.tgz"
  
  # 実行ファイル
  "*.exe"
  "*.msi"
  "*.app"
  "*.dmg"
  
  # 動画ファイル
  "*.mp4"
  "*.avi"
  "*.mov"
  "*.mkv"
  "*.wmv"
  "*.flv"
  "*.webm"
  
  # 音声ファイル
  "*.mp3"
  "*.wav"
  "*.flac"
  "*.aac"
  "*.m4a"
  "*.ogg"
  "*.wma"
  
  # RAWファイル（修正: 再帰的マッチング）
  "**/*.nef"
  "**/*.NEF"
  
  # その他
  "www*/**"
  
  # WordPress全体除外（レベル1）
  "**/wp-content/**"
  "**/wp-includes/**"
  "**/wp-admin/**"
  "**/wp-*.php"
  "**/.htaccess"
  "**/xmlrpc.php"
  "**/.well-known/**"
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

# 無限ループ対策: 深さ制限を20に設定
RCLONE_MAX_DEPTH=20

# テストモード: 転送量制限（100MB）
TEST_MAX_TRANSFER="100M"

# テストモード: 時間制限10秒）
TEST_MAX_DURATION="10s"

# 共有ドライブアクセス用の管理者
ADMIN_USER="ytagami@ycomps.co.jp"

# --max-age 自動延長の最大日数（デフォルト: 30日）
MAX_AGE_LIMIT_DAYS=30

#==============================================================================
# モード判定
#==============================================================================

PRODUCTION_MODE=true
if [ "$TEST_MODE" = true ] || [ "$DRY_RUN" = true ]; then
  PRODUCTION_MODE=false
fi

MODE_INFO="Normal Mode"
if [ "$TEST_MODE" = true ]; then
  MODE_INFO="TEST MODE (max transfer: $TEST_MAX_TRANSFER, max duration: $TEST_MAX_DURATION [強制停止] per user/drive)"
fi
if [ "$DRY_RUN" = true ]; then
  MODE_INFO="$MODE_INFO + DRY-RUN (no actual transfer)"
fi
if [ "$REBUILD_BASE" = true ]; then
  MODE_INFO="$MODE_INFO + REBUILD-BASE (年次base再構築)"
fi

#==============================================================================
# ログ関数
#==============================================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

#==============================================================================
# フォルダ名安全化関数（Base64エンコード）
#==============================================================================

safe_folder_name() {
  local input=$1
  # Base64エンコード（パディング=を削除、+/を_-に変換）
  local encoded=$(echo -n "$input" | base64 | tr -d '=\n' | tr '+/' '_-')
  
  # 空白チェック
  if [ -z "$encoded" ]; then
    log "❌ ERROR: フォルダ名のエンコードに失敗: '$input'"
    echo "ERROR_EMPTY_FOLDER_NAME"
    return 1
  fi
  
  echo "$encoded"
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
# 最新の増分バックアップ日付を取得（マイドライブ用）
#==============================================================================

get_last_backup_date_mydrive() {
  local safe_user=$1
  local incremental_base="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/incremental/"
  
  # rclone lsd で増分フォルダの一覧を取得し、最新の日付を抽出
  local last_date=$(rclone lsd "$incremental_base" 2>/dev/null \
    | awk '{print $5}' \
    | grep -E '^[0-9]{8}$' \
    | sort -r \
    | head -n 1)
  
  echo "$last_date"
}

#==============================================================================
# 最新の増分バックアップ日付を取得（共有ドライブ用）
#==============================================================================

get_last_backup_date_shared() {
  local safe_drive_name=$1
  local incremental_base="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/incremental/"
  
  # rclone lsd で増分フォルダの一覧を取得し、最新の日付を抽出
  local last_date=$(rclone lsd "$incremental_base" 2>/dev/null \
    | awk '{print $5}' \
    | grep -E '^[0-9]{8}$' \
    | sort -r \
    | head -n 1)
  
  echo "$last_date"
}

#==============================================================================
# --max-age を自動計算
#==============================================================================

calculate_max_age() {
  local last_backup_date=$1
  local current_date=$(date +%Y%m%d)
  
  if [ -z "$last_backup_date" ]; then
    # 増分バックアップが存在しない場合（初回バックアップ後の初回増分）
    echo "24h"
    return 0
  fi
  
  # 日付の差分を計算
  local last_epoch=$(date -d "$last_backup_date" +%s 2>/dev/null || echo 0)
  local current_epoch=$(date -d "$current_date" +%s 2>/dev/null || echo 0)
  
  if [ "$last_epoch" -eq 0 ] || [ "$current_epoch" -eq 0 ]; then
    # 日付変換エラー
    log "⚠️  WARNING: 日付変換エラー、デフォルトの24hを使用"
    echo "24h"
    return 0
  fi
  
  local diff_seconds=$((current_epoch - last_epoch))
  local diff_days=$((diff_seconds / 86400))
  
  # 差分日数+1日分（余裕を持たせる）
  local max_age_hours=$(( (diff_days + 1) * 24 ))
  
  # 最低24時間
  if [ $max_age_hours -lt 24 ]; then
    max_age_hours=24
  fi
  
  # 最大を制限（デフォルト: 30日分まで）
  local max_limit_hours=$((MAX_AGE_LIMIT_DAYS * 24))
  if [ $max_age_hours -gt $max_limit_hours ]; then
    log "⚠️  WARNING: 実行漏れが${MAX_AGE_LIMIT_DAYS}日を超えています。${MAX_AGE_LIMIT_DAYS}日分に制限します。"
    max_age_hours=$max_limit_hours
  fi
  
  echo "${max_age_hours}h"
}

#==============================================================================
# 初回判定関数（マイドライブ用）
#==============================================================================

is_first_backup_mydrive() {
  local user=$1
  local safe_user=$2
  #local base_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base/"
  local base_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base/"
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
  local base_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/base/"
  
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
  
  # Base64エンコードでフォルダ名を生成
  local safe_user=$(safe_folder_name "$user")
  
  if [ "$safe_user" = "ERROR_EMPTY_FOLDER_NAME" ]; then
    log "❌ ERROR: ユーザーフォルダ名の生成に失敗: $user"
    return 1
  fi
  
  log "📁 GCSフォルダ名: $safe_user (元: $user)"
  
  local base_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base/"
  local incr_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/incremental/${BACKUP_DATE}/"
  local cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/CUMULATIVE_DELETED.txt"
  
  # base再構築モードの場合、既存baseをリネーム
  if [ "$REBUILD_BASE" = true ]; then
    log "🔄 Base再構築モード: 既存baseを base_archive_${BACKUP_DATE} にリネーム"
    local archive_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/mydrive/${safe_user}/base_archive_${BACKUP_DATE}/"
    rclone moveto "$base_path" "$archive_path" 2>/dev/null || true
  fi
  
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
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER, 最大実行時間 $TEST_MAX_DURATION (強制停止)"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
      rclone_opts+=(--max-duration "$TEST_MAX_DURATION")
      rclone_opts+=(--cutoff-mode hard)
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
    

#    if [ "$PRODUCTION_MODE" = true ]; then
    if false; then
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    # --max-age 自動計算
    local last_backup_date=$(get_last_backup_date_mydrive "$safe_user")
    local max_age=$(calculate_max_age "$last_backup_date")
    
    log "🔄 増分バックアップ: 最後のバックアップ日付 = $last_backup_date"
    log "📅 自動計算された --max-age = $max_age"
    log "Backup destination: $incr_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$incr_path"
      --drive-impersonate "$user"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age "$max_age"
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
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER, 最大実行時間 $TEST_MAX_DURATION (強制停止)"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
      rclone_opts+=(--max-duration "$TEST_MAX_DURATION")
      rclone_opts+=(--cutoff-mode hard)
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
    
    #if [ "$PRODUCTION_MODE" = true ]; then
    if false; then  # 削除ファイル検知を無効化

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
  
  # Base64エンコードでフォルダ名を生成
  local safe_drive_name=$(safe_folder_name "$drive_name")
  
  if [ "$safe_drive_name" = "ERROR_EMPTY_FOLDER_NAME" ]; then
    log "❌ ERROR: 共有ドライブフォルダ名の生成に失敗: $drive_name"
    return 1
  fi
  
  log "📁 GCSフォルダ名: $safe_drive_name (元: $drive_name)"
  
  local base_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/base/"
  local incr_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/incremental/${BACKUP_DATE}/"
  local cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/CUMULATIVE_DELETED.txt"
  
  # base再構築モードの場合、既存baseをリネーム
  if [ "$REBUILD_BASE" = true ]; then
    log "🔄 Base再構築モード: 既存baseを base_archive_${BACKUP_DATE} にリネーム"
    local archive_path="${GCS_REMOTE}/${GCS_BACKUP_ROOT}/shared_drives/${safe_drive_name}/base_archive_${BACKUP_DATE}/"
    rclone moveto "$base_path" "$archive_path" 2>/dev/null || true
  fi
  
  if is_first_backup_shared "$safe_drive_name"; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$base_path"
      --drive-impersonate "$ADMIN_USER"
      --drive-shared-with-me
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
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER, 最大実行時間 $TEST_MAX_DURATION (強制停止)"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
      rclone_opts+=(--max-duration "$TEST_MAX_DURATION")
      rclone_opts+=(--cutoff-mode hard)
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
    
    #if [ "$PRODUCTION_MODE" = true ]; then
    if false; then  # 削除ファイル検知を無効化
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    # --max-age 自動計算
    local last_backup_date=$(get_last_backup_date_shared "$safe_drive_name")
    local max_age=$(calculate_max_age "$last_backup_date")
    
    log "🔄 増分バックアップ: 最後のバックアップ日付 = $last_backup_date"
    log "📅 自動計算された --max-age = $max_age"
    log "Backup destination: $incr_path"
    
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:/"
      "$incr_path"
      --drive-impersonate "$ADMIN_USER"
      --drive-shared-with-me
      --drive-root-folder-id "$drive_id"
      --log-file="$LOG_FILE"
      --log-level INFO
      --gcs-bucket-policy-only
      --gcs-storage-class ARCHIVE
      --max-age "$max_age"
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
      log "🧪 テストモード: 最大転送量 $TEST_MAX_TRANSFER, 最大実行時間 $TEST_MAX_DURATION (強制停止)"
      rclone_opts+=(--max-transfer "$TEST_MAX_TRANSFER")
      rclone_opts+=(--max-duration "$TEST_MAX_DURATION")
      rclone_opts+=(--cutoff-mode hard)
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
    
    #if [ "$PRODUCTION_MODE" = true ]; then
    if false; then  # 削除ファイル検知を無効化
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
        --drive-shared-with-me \
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
log "GWS to GCS Backup Started (MyDrive + Shared Drives) v7"
log "Date: $(date)"
log "Mode: $MODE_INFO"
log "フォルダ名エンコード: Base64 (日本語対応)"
log "無限ループ対策: --skip-links --max-depth $RCLONE_MAX_DEPTH"
log "除外フォルダ: ${LOOP_PREVENTION_EXCLUDES[*]}"
log "NEFファイル除外: 有効 (**/*.nef, **/*.NEF)"
log "WordPress除外: 有効（レベル1: 全体除外）"
log "--max-age 自動延長: 有効（最大${MAX_AGE_LIMIT_DAYS}日）"
log "=========================================="

#if [ "$PRODUCTION_MODE" = true ]; then
if false; then  # 削除ファイル検知を無効化
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
log "GWS to GCS Backup Completed (MyDrive + Shared Drives) v7"
log "Date: $(date)"
log "Mode: $MODE_INFO"
log "=========================================="

#==============================================================================
# バックアップ完了後の処理
#==============================================================================

#if [ "$PRODUCTION_MODE" = true ]; then
if false; then  # 削除ファイル検知を無効化
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
