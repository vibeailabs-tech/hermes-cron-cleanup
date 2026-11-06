#!/usr/bin/env bash
# Hermes nightly cleanup — chạy bằng cron no-agent của Hermes (23:00 hằng ngày).
#   1. Xoá session còn mở (Desktop không tự đóng session) đã idle >= IDLE_HOURS; giữ session pin và Bot Chat.
#   2. Xoá mọi session đã kết thúc, kể cả archived (giữ session pin) qua `hermes sessions prune`.
#   3. Xoá file tạm/artifacts trong các thư mục cache do Hermes quản lý (giữ lại thư mục gốc).
#      Mục nào có file sửa trong MIN_AGE_MINUTES phút gần đây được giữ lại (session đang dùng);
#      file ẩn (.locks, .last_prune...) là dữ liệu nội bộ của Hermes nên không đụng tới.
# Chạy thử, không xoá gì:  bash ~/.hermes/scripts/hermes-nightly-cleanup.sh --dry-run
set -uo pipefail

IDLE_HOURS=2
MIN_AGE_MINUTES=60

TEMP_DIRS=(
  cache/documents cache/images cache/audio cache/videos cache/screenshots cache/web
  cache/delegation cache/spillover cache/exec cache/generated cache/scratch cache/terminal
  cache/browser-use/workspace images attachments composer-pastes
  document_cache image_cache audio_cache video_cache browser_screenshots web_cache
  delegation_cache exec_spill
)

dry_run=0
[[ "${1:-}" == "--dry-run" ]] && dry_run=1
home="${HERMES_HOME:-$HOME/.hermes}"
hermes_bin="$(command -v hermes || echo "$HOME/.local/bin/hermes")"
db_uri="file:$home/state.db?mode=ro"
failures=0

echo "== Hermes nightly cleanup $(date '+%Y-%m-%d %H:%M')$( ((dry_run)) && echo ' [DRY RUN]')"

echo "-- 1. Session còn mở, idle >= ${IDLE_HOURS}h"
cutoff=$(( $(date +%s) - IDLE_HOURS * 3600 ))
open_ids=$(sqlite3 -readonly "$db_uri" "
  WITH RECURSIVE kept(id) AS (
    SELECT id FROM sessions WHERE COALESCE(pinned, 0) = 1
    UNION SELECT c.id FROM sessions c JOIN kept k ON c.parent_session_id = k.id)
  SELECT s.id FROM sessions s
  WHERE s.ended_at IS NULL
    AND s.id NOT IN (SELECT id FROM kept)
    AND NOT (COALESCE(s.hidden, 0) = 1 AND COALESCE(s.title, '') = 'Bot Chat')
    AND MAX(COALESCE(s.last_activity_at, 0), COALESCE(s.started_at, 0),
            COALESCE((SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id), 0)) < $cutoff
  ORDER BY s.started_at;") || { echo "Không đọc được $home/state.db"; failures=$((failures + 1)); open_ids=""; }
deleted=0
while IFS= read -r id; do
  [[ -n "$id" ]] || continue
  if ((dry_run)); then echo "  sẽ xoá: $id"; continue; fi
  # Xoá session cha cũng xoá luôn session con (subagent), nên bỏ qua id đã biến mất.
  [[ -n "$(sqlite3 -readonly "$db_uri" "SELECT 1 FROM sessions WHERE id = '${id//\'/\'\'}';")" ]] || continue
  if "$hermes_bin" sessions delete --yes "$id"; then deleted=$((deleted + 1)); else failures=$((failures + 1)); fi
done <<< "$open_ids"
((dry_run)) || echo "Đã xoá $deleted session mở."

echo "-- 2. Session đã kết thúc"
if ((dry_run)); then
  "$hermes_bin" sessions prune --older-than 0 --include-archived --dry-run
else
  "$hermes_bin" sessions prune --older-than 0 --include-archived --yes
fi || failures=$((failures + 1))

echo "-- 3. File tạm / artifacts"
total_files=0
total_kb=0
for rel in "${TEMP_DIRS[@]}"; do
  dir="$home/$rel"
  [[ -d "$dir" && ! -L "$dir" ]] || continue
  dir_files=0
  dir_kb=0
  while IFS= read -r -d '' entry; do
    [[ -z "$(find "$entry" -mmin -"$MIN_AGE_MINUTES" -print -quit 2>/dev/null)" ]] || continue
    dir_files=$((dir_files + $(find "$entry" ! -type d 2>/dev/null | wc -l)))
    kb=$(du -sk "$entry" 2>/dev/null | cut -f1)
    dir_kb=$((dir_kb + ${kb:-0}))
    ((dry_run)) || rm -rf -- "$entry" || failures=$((failures + 1))
  done < <(find "$dir" -mindepth 1 -maxdepth 1 ! -name '.*' -print0)
  ((dir_files)) || continue
  echo "  $rel: $dir_files file (~${dir_kb} KB)"
  total_files=$((total_files + dir_files))
  total_kb=$((total_kb + dir_kb))
done
echo "Tổng: $total_files file (~$((total_kb / 1024)) MB)$( ((dry_run)) && echo ' — chưa xoá (dry run)')"

exit $((failures > 0))
