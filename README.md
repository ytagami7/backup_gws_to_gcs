# GWS to GCS Backup Scripts

Google Workspace (旧G Suite) から Google Cloud Storage への自動バックアップスクリプト集

## ファイル説明

- `backup_gws_to_gcs_final_fixed.sh` - 最終版バックアップスクリプト（無限ループ対策済み）
- `backup_gws_to_gcs_fixed.sh` - 修正版バックアップスクリプト
- `shared_drive_mapping.txt` - 共有ドライブのIDマッピングファイル

## 使用方法

### テストモード（推奨）
```bash
sudo -u ytagami ./backup_gws_to_gcs_final_fixed.sh --test --dry-run
```

### 本番モード
```bash
sudo -u ytagami ./backup_gws_to_gcs_final_fixed.sh
```

## 機能

- マイドライブと共有ドライブの自動バックアップ
- 初回フルバックアップ + 増分バックアップ
- 削除ファイルの追跡
- 無限ループ対策
- テストモード（100MB制限）
- ドライランモード

## 作成日
2025年10月25日
