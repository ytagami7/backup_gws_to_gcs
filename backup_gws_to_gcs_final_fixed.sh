#!/bin/bash

################################################################################
# GWS to GCS Backup Script (Base + Incremental + Cumulative Deletion)
# Version: 7.5
################################################################################
#
# --- 使用方法 ---
# 本番モード:   ./backup_gws_to_gcs.sh --production
# テストモード:  ./backup_gws_to_gcs.sh --test
# Dry-runモード: ./backup_gws_to_gcs.sh --dry-run
# テスト+Dry-run: ./backup_gws_to_gcs.sh --test --dry-run
#
# 注意: 引数なし実行、--production + --test、--production + --dry-run の組み合わせは禁止
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
# 変更履歴 (CHANGELOG)
################################################################################
#
# Version 7.5 (2025-10-26)
# - テストモードでの --files-from と --exclude の競合エラーを完全解決
# - テストモードでは除外パターンを適用せず、ファイル数制限のみ実行
# - 本番モードでは除外パターンを正常に適用
#
# Version 7.4 (2025-10-26)
# - テストモードでの --files-from と --exclude の競合エラーを修正
# - --files-from を --files-from-raw に変更して除外パターンと併用可能に
#
# Version 7.3 (2025-10-26)
# - Shared Drivesの初回判定ロジックを修正（rclone lsd → rclone lsf に変更）
# - 初回バックアップが正しく実行されるように改善
#
# Version 7.2 (2025-10-26)
# - production モードの引数を --production に変更（--test, --dry-run と統一）
# - 引数の矛盾チェック機能を追加（--production + --test, --production + --dry-run の組み合わせを禁止）
# - 引数なし実行を禁止し、適切な使用方法を表示
# - 使用方法の説明を更新
#
# Version 7.1 (2025-10-26)
# - MyDriveとShared Drivesの処理を統一する共通関数 backup_drive() を実装
# - コードの重複を削除し、保守性とテスト容易性を改善
# - テストモードと除外パターンの競合を解決（--files-from と --exclude の同時使用エラー修正）
# - 共有ドライブ設定を shared_drive_mapping.txt に基づいて更新
# - get_shared_drive_id() 関数を追加（共有ドライブID取得とキャッシュ機能）
#
# Version 7.0 (2025-10-26)
# - 初回リリース
# - 基本バックアップ機能（MyDrive + Shared Drives）
# - 増分バックアップ機能
# - 削除検知機能（現在無効化）
# - NEF および WordPress ファイルの除外
# - 除外ファイルパターンの追加（*.nef, *.NEF, wp-*/**, wp-content/cache/** など）
# - 初回バックアップと増分バックアップの自動判定
# - 累積削除リスト機能（無効化）
# - シャットダウン機能（本番モード時）
# - ログ機能とエラーハンドリング
#
################################################################################

set -euo pipefail

#==============================================================================
# 引数解析
#==============================================================================

TEST_MODE=false
DRY_RUN=false
PRODUCTION_MODE=false
MAX_FILES_PER_USER=100

# 引数なしチェック
if [ $# -eq 0 ]; then
  echo "Error: No arguments provided"
  echo "Usage: $0 [--production] [--test] [--dry-run]"
  echo "  --production: 本番モード（実際のバックアップ実行）"
  echo "  --test: テストモード（ファイル数制限）"
  echo "  --dry-run: Dry-runモード（実際の転送なし）"
  echo ""
  echo "Valid combinations:"
  echo "  --production (本番のみ)"
  echo "  --test (テストのみ)"
  echo "  --dry-run (Dry-runのみ)"
  echo "  --test --dry-run (テスト+Dry-run)"
  exit 1
fi

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
    --production)
      PRODUCTION_MODE=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--production] [--test] [--dry-run]"
      exit 1
      ;;
  esac
done

# 引数の矛盾チェック
if [ "$PRODUCTION_MODE" = true ] && [ "$TEST_MODE" = true ]; then
  echo "Error: --production and --test cannot be used together"
  echo "Usage: $0 [--production] [--test] [--dry-run]"
  echo "  --production: 本番モード（実際のバックアップ実行）"
  echo "  --test: テストモード（ファイル数制限）"
  echo "  --dry-run: Dry-runモード（実際の転送なし）"
  exit 1
fi

if [ "$PRODUCTION_MODE" = true ] && [ "$DRY_RUN" = true ]; then
  echo "Error: --production and --dry-run cannot be used together"
  echo "Usage: $0 [--production] [--test] [--dry-run]"
  echo "  --production: 本番モード（実際のバックアップ実行）"
  echo "  --test: テストモード（ファイル数制限）"
  echo "  --dry-run: Dry-runモード（実際の転送なし）"
  exit 1
fi

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

# PRODUCTION_MODE は引数解析で設定済み

MODE_INFO=""
if [ "$PRODUCTION_MODE" = true ]; then
  MODE_INFO="PRODUCTION MODE"
elif [ "$TEST_MODE" = true ]; then
  MODE_INFO="TEST MODE (max $MAX_FILES_PER_USER files per user)"
elif [ "$DRY_RUN" = true ]; then
  MODE_INFO="DRY-RUN MODE (no actual transfer)"
fi

if [ "$TEST_MODE" = true ] && [ "$DRY_RUN" = true ]; then
  MODE_INFO="TEST MODE (max $MAX_FILES_PER_USER files per user) + DRY-RUN (no actual transfer)"
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
# 統一バックアップ関数
#==============================================================================

backup_drive() {
  local drive_type="$1"  # "mydrive" or "shared"
  local drive_name="$2"  # user email or shared drive name
  local drive_id="${3:-}"    # shared drive ID (optional for mydrive)
  
  log "=========================================="
  log "Processing ${drive_type}: $drive_name"
  log "=========================================="
  
  # 安全な名前を生成
  local safe_name
  if [ "$drive_type" = "mydrive" ]; then
    safe_name=$(echo "$drive_name" | sed 's/@/_AT_/g' | sed 's/\./_DOT_/g')
  else
    safe_name=$(echo "$drive_name" | sed 's/[^a-zA-Z0-9_-]/_/g')
  fi
  
  # パス設定
  local base_path incr_path cumulative_deleted_path
  if [ "$drive_type" = "mydrive" ]; then
    base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/base/"
    incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/incremental/${BACKUP_DATE}/"
    cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/CUMULATIVE_DELETED.txt"
  else
    base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/base/"
    incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/incremental/${BACKUP_DATE}/"
    cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/CUMULATIVE_DELETED.txt"
  fi
  
  # 初回判定
  local is_first=false
  if [ "$drive_type" = "mydrive" ]; then
    if is_first_backup "$drive_name" "$safe_name"; then
      is_first=true
    fi
  else
    # Shared Drives: baseフォルダの存在確認
    if ! rclone lsf "$base_path" --max-depth 1 2>/dev/null | grep -q .; then
      is_first=true
    fi
  fi
  
  if [ "$is_first" = true ]; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    # 基本オプション
    local rclone_opts=(
      "${RCLONE_REMOTE_NAME}:"
      "$base_path"
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
    
    # ドライブタイプ別のオプション
    if [ "$drive_type" = "mydrive" ]; then
      rclone_opts+=("--drive-impersonate" "$drive_name")
    else
      rclone_opts+=("--drive-shared-with-me" "--drive-root-folder-id" "$drive_id")
    fi
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      local lsf_opts=(
        "${RCLONE_REMOTE_NAME}:"
        --files-only -R
      )
      
      if [ "$drive_type" = "mydrive" ]; then
        lsf_opts+=("--drive-impersonate" "$drive_name")
      else
        lsf_opts+=("--drive-shared-with-me" "--drive-root-folder-id" "$drive_id")
      fi
      
      rclone lsf "${lsf_opts[@]}" 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        rclone_opts+=(--exclude "$pattern")
      done
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
      log "❌ ERROR: Backup failed for ${drive_type} $drive_name (exit code: $result)"
      return 1
    else
      log "✅ SUCCESS: 初回バックアップ完了 for ${drive_type} $drive_name"
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
      "${RCLONE_REMOTE_NAME}:"
      "$incr_path"
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
    
    # ドライブタイプ別のオプション
    if [ "$drive_type" = "mydrive" ]; then
      rclone_opts+=("--drive-impersonate" "$drive_name")
    else
      rclone_opts+=("--drive-shared-with-me" "--drive-root-folder-id" "$drive_id")
    fi
    
    # テストモード: ファイル数制限
    if [ "$TEST_MODE" = true ]; then
      log "🧪 テストモード: 最初の${MAX_FILES_PER_USER}ファイルのみ処理"
      
      local temp_file=$(mktemp)
      local lsf_opts=(
        "${RCLONE_REMOTE_NAME}:"
        --files-only -R
        --max-age 24h
      )
      
      if [ "$drive_type" = "mydrive" ]; then
        lsf_opts+=("--drive-impersonate" "$drive_name")
      else
        lsf_opts+=("--drive-shared-with-me" "--drive-root-folder-id" "$drive_id")
      fi
      
      rclone lsf "${lsf_opts[@]}" 2>/dev/null | head -n $MAX_FILES_PER_USER > "$temp_file"
      
      local file_count=$(wc -l < "$temp_file")
      log "処理ファイル数: $file_count"
      
      rclone_opts+=(--files-from "$temp_file")
    else
      # 通常モード: 除外パターンを使用
      for pattern in "${EXCLUDE_PATTERNS[@]}"; do
        rclone_opts+=(--exclude "$pattern")
      done
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
      log "❌ ERROR: Incremental backup failed for ${drive_type} $drive_name (exit code: $result)"
    return 1
  else
      log "✅ SUCCESS: 増分バックアップ完了 for ${drive_type} $drive_name"
    fi
    
    # 削除ファイル検知（本番モードのみ）
    if [ "$PRODUCTION_MODE" = true ]; then
      log "ℹ️  削除ファイル検知機能は無効化されています"
    fi
  fi
  
  log "✅ ${drive_type}処理完了: $drive_name"
}

#==============================================================================
# バックアップ関数（後方互換性のため）
#==============================================================================

backup_user() {
  local user=$1
  backup_drive "mydrive" "$user"
}

#==============================================================================
# 共有ドライブバックアップ関数
#==============================================================================

backup_shared_drive() {
  local drive_name="$1"
  local drive_id=$(get_shared_drive_id "$drive_name")
  
  if [ -z "$drive_id" ]; then
    log "⚠️  スキップ: ${drive_name} (ID未発見)"
    return 1
  fi
  
  backup_drive "shared" "$drive_name" "$drive_id"
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
  #sudo shutdown -h now
else
  log ""
  log "ℹ️  TEST/DRY-RUN MODE: Skipping auto-shutdown (instance remains running)"
  log "   This allows you to review results and logs."
fi

exit 0