#!/bin/bash

################################################################################
# GWS to GCS Backup Script (Base + Incremental + Cumulative Deletion)
# Version: 7.14
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
# Version 7.14 (2025-10-26)
# - 重複コードを統合してexecute_rclone_backup()関数を作成
# - 初回バックアップと増分バックアップの重複処理を削除
# - コードの保守性と可読性を大幅に改善
# - 約100行の重複コードを削除
#
# Version 7.13 (2025-10-26)
# - 初回バックアップ判別ロジックを統一化
# - マイドライブと共有ドライブの両方でファイル数による判別を使用
# - is_first_backup() 関数を削除し、統一ロジックに統合
#
# Version 7.12 (2025-10-26)
# - テストモードのファイル数制限を --max-duration 30s で実現
# - --max-transfer ではファイル数制限にならないため時間制限に変更
# - 共有ドライブアクセスを管理者アカウントのimpersonationで修正
#
# Version 7.11 (2025-10-26)
# - テストモードの処理を本番モードを基本に修正
# - 除外パターンはテスト・本番共通で適用
# - テストモードでは転送量制限（10MB）のみ追加
# - テストが本番の動作を正しく反映するように改善
#
# Version 7.10 (2025-10-26)
# - --max-files オプションが存在しないため、--max-transfer で転送量制限を実現
# - テストモードでは100MBの転送量制限でファイル数制限を代替
# - テストモードと本番モードの両方で --exclude のみを使用
#
# Version 7.9 (2025-10-26)
# - テストモードと本番モードの両方で --exclude のみを使用するように統一
# - --files-from を完全に削除し、--max-files でファイル数制限を実現
# - テストモードでも本番と同じ除外パターンが適用されるように修正
#
# Version 7.8 (2025-10-26)
# - テストモードでも除外パターンを適用するように修正
# - 初回バックアップと増分バックアップの両方で除外パターンを適用
# - テストモードと本番モードの動作を完全に統一
#
# Version 7.7 (2025-10-26)
# - テストモードで共有ドライブのファイルが0件になる問題を修正
# - rclone lsf で除外パターンを適用せず、ファイル数制限のみ実行
# - 共有ドライブでも正常にファイルが処理されるように改善
#
# Version 7.6 (2025-10-26)
# - テストモードでも本番と同じ除外パターンを適用するように修正
# - 除外パターン適用後にファイル数制限を実行（本番と同じ動作をテスト）
# - テストモードと本番モードの動作を統一
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
FORCE_FULL=false
MAX_FILES_PER_USER=100

# 引数なしチェック
if [ $# -eq 0 ]; then
  echo "Error: No arguments provided"
  echo "Usage: $0 [--production] [--test] [--dry-run] [--force-full]"
  echo "  --production: 本番モード（実際のバックアップ実行）"
  echo "  --test: テストモード（ファイル数制限）"
  echo "  --dry-run: Dry-runモード（実際の転送なし）"
  echo "  --force-full: 全ドライブを初回バックアップとして強制実行"
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
    --force-full)
      FORCE_FULL=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--production] [--test] [--dry-run] [--force-full]"
      exit 1
      ;;
  esac
done

# 引数の矛盾チェック
if [ "$PRODUCTION_MODE" = true ] && [ "$TEST_MODE" = true ]; then
  echo "Error: --production and --test cannot be used together"
  echo "Usage: $0 [--production] [--test] [--dry-run] [--force-full]"
  echo "  --production: 本番モード（実際のバックアップ実行）"
  echo "  --test: テストモード（ファイル数制限）"
  echo "  --dry-run: Dry-runモード（実際の転送なし）"
  exit 1
fi

if [ "$PRODUCTION_MODE" = true ] && [ "$DRY_RUN" = true ]; then
  echo "Error: --production and --dry-run cannot be used together"
  echo "Usage: $0 [--production] [--test] [--dry-run] [--force-full]"
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
RCLONE_TRANSFERS=8
RCLONE_CHECKERS=8
RCLONE_CHUNK_SIZE="128M"
RCLONE_TPS_LIMIT=150
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
# rclone実行関数（重複コード統合）
#==============================================================================

execute_rclone_backup() {
  local source_path="$1"
  local dest_path="$2"
  local backup_type="$3"  # "initial" or "incremental"
  local drive_type="$4"
  local drive_name="$5"
  local drive_id="$6"
  local last_backup_time="${7:-}"  # 前回バックアップ時刻（増分バックアップ用）
  
  # 基本オプション
  local rclone_opts=(
    "${RCLONE_REMOTE_NAME}:"
    "$dest_path"
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
  
  # 増分バックアップの場合の時刻制限オプション
  if [ "$backup_type" = "incremental" ]; then
    if [ -n "$last_backup_time" ]; then
      # 前回バックアップ時刻以降の変更を対象
      rclone_opts+=(--min-age "$last_backup_time")
    fi
    # 前回時刻が取得できない場合はフルバックアップにフォールバックするため、
    # ここでは時刻制限オプションを追加しない
  fi
  
  # ドライブタイプ別のオプション
  if [ "$drive_type" = "mydrive" ]; then
    rclone_opts+=("--drive-impersonate" "$drive_name")
  else
    # 共有ドライブ: 管理者アカウントでimpersonateしてアクセス
    rclone_opts+=("--drive-impersonate" "ytagami@ycomps.co.jp" "--drive-root-folder-id" "$drive_id")
  fi
  
  # 除外パターンを適用（テスト・本番共通）
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    rclone_opts+=(--exclude "$pattern")
  done
  
  # テストモード: 時間制限でファイル数制限を実現
  if [ "$TEST_MODE" = true ]; then
    log "🧪 テストモード: 時間制限（10秒）でファイル数制限を実現"
    rclone_opts+=(--max-duration 10s)
  fi
  
  # Dry-runモード
  if [ "$DRY_RUN" = true ]; then
    rclone_opts+=(--dry-run)
  fi
  
  # rclone copy実行
  log "Executing: rclone copy ${rclone_opts[*]}"
  rclone copy "${rclone_opts[@]}"
  local result=$?
  
  # エラーチェック
  if [ $result -ne 0 ]; then
    if [ "$TEST_MODE" = true ] && [ $result -eq 10 ]; then
      log "✅ SUCCESS: テストモード時間制限により正常終了 for ${drive_type} $drive_name"
    else
      log "❌ ERROR: ${backup_type^} backup failed for ${drive_type} $drive_name (exit code: $result)"
      return 1
    fi
  else
    log "✅ SUCCESS: ${backup_type^}バックアップ完了 for ${drive_type} $drive_name"
  fi
  
  return 0
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
    # 共有ドライブ名をBase64エンコード（以前の仕様）
    safe_name=$(echo "$drive_name" | base64 | sed 's/=//g' | sed 's/K$//')
  fi
  
  # パス設定
  local base_path incr_path cumulative_deleted_path last_backup_time_path
  if [ "$drive_type" = "mydrive" ]; then
    base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/base/"
    incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/incremental/${BACKUP_DATE}/"
    cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/${safe_name}/CUMULATIVE_DELETED.txt"
    last_backup_time_path="/home/ytagami/backup_times/${safe_name}_LAST_BACKUP_TIME.txt"
  else
    base_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/base/"
    incr_path="gcs_backup:${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/incremental/${BACKUP_DATE}/"
    cumulative_deleted_path="gs://${GCS_BUCKET}/${GCS_BACKUP_ROOT}/shared_drives/${safe_name}/CUMULATIVE_DELETED.txt"
    last_backup_time_path="/home/ytagami/backup_times/shared_${safe_name}_LAST_BACKUP_TIME.txt"
  fi
  
  log "📁 保存先: $base_path"
  
  # 初回判定（統一ロジック：ファイル数で判別）
  local is_first=false
  local file_count=$(rclone lsf "$base_path" --files-only -R 2>/dev/null | wc -l)
  if [ "$file_count" -eq 0 ]; then
    is_first=true
  fi
  
  # --force-full オプションが指定された場合は強制的に初回バックアップとして実行
  if [ "$FORCE_FULL" = true ]; then
    is_first=true
    log "🔄 FORCE-FULL: 全ドライブを初回バックアップとして強制実行"
  fi
  
  # 前回バックアップ時刻を読み込み（増分バックアップ用）
  local last_backup_time=""
  if [ "$is_first" = false ]; then
    last_backup_time=$(cat "$last_backup_time_path" 2>/dev/null || echo "")
    if [ -n "$last_backup_time" ]; then
      log "📅 前回バックアップ時刻: $last_backup_time"
    else
      log "⚠️  前回バックアップ時刻が取得できません。フルバックアップを実行します"
      is_first=true
    fi
  fi
  
  if [ "$is_first" = true ]; then
    log "📦 初回バックアップ: フルバックアップを base/ に保存"
    log "Backup destination: $base_path"
    
    # 統合されたrclone実行関数を呼び出し
    execute_rclone_backup "" "$base_path" "initial" "$drive_type" "$drive_name" "$drive_id"
    
    # バックアップ成功後、現在時刻を記録（本番モードのみ）
    if [ $? -eq 0 ] && [ "$PRODUCTION_MODE" = true ]; then
      # backup_timesディレクトリを作成
      mkdir -p "/home/ytagami/backup_times"
      current_time=$(date -u +%Y-%m-%dT%H:%M:%S)
      echo "$current_time" > "$last_backup_time_path"
      log "📅 バックアップ時刻記録: $current_time"
    fi
    
    # 累積削除リストを初期化（空ファイル）
    if [ "$PRODUCTION_MODE" = true ]; then
      echo "" | gsutil cp - "$cumulative_deleted_path" 2>/dev/null || true
      log "📝 累積削除リスト初期化"
    fi
    
  else
    if [ -n "$last_backup_time" ]; then
      log "🔄 増分バックアップ: 前回バックアップ時刻以降の変更 ($last_backup_time)"
    else
      log "🔄 増分バックアップ: 過去24時間の変更のみ"
    fi
    log "Backup destination: $incr_path"
    
    # 統合されたrclone実行関数を呼び出し
    execute_rclone_backup "" "$incr_path" "incremental" "$drive_type" "$drive_name" "$drive_id" "$last_backup_time"
    
    # バックアップ成功後、現在時刻を記録（本番モードのみ）
    if [ $? -eq 0 ] && [ "$PRODUCTION_MODE" = true ]; then
      # backup_timesディレクトリを作成
      mkdir -p "/home/ytagami/backup_times"
      current_time=$(date -u +%Y-%m-%dT%H:%M:%S)
      echo "$current_time" > "$last_backup_time_path"
      log "📅 バックアップ時刻記録: $current_time"
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

log ""
log ""
log ""
log "=========================================="
log "GWS to GCS Backup Started"
log "Date: $(TZ='Asia/Tokyo' date)"
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