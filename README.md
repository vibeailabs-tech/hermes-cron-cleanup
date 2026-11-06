# hermes-cron-cleanup

Cron job dọn dẹp hằng đêm cho [Hermes Agent](https://hermes-agent.nousresearch.com) (Nous Research).
Đúng 23:00 mỗi ngày, job xoá các session chat và file tạm/artifacts sinh ra trong quá trình dùng Hermes,
giúp `~/.hermes` gọn nhẹ.

Job chạy ở **no-agent mode**: chỉ là một script bash, không gọi LLM, không tốn token.

## Job xoá gì

| Bước | Nội dung | Cách làm |
|---|---|---|
| 1 | Session chat **còn mở** đã idle ≥ `IDLE_HOURS` (mặc định 2h) | `hermes sessions delete --yes <id>` |
| 2 | Mọi session chat **đã kết thúc**, kể cả archived | `hermes sessions prune --older-than 0 --include-archived --yes` |
| 3 | File tạm / artifacts trong các thư mục cache do Hermes quản lý | `rm -rf` từng mục bên trong thư mục |

Bước 1 cần thiết vì `hermes sessions prune` chỉ xoá session đã kết thúc, trong khi session của
Hermes Desktop không bao giờ tự kết thúc.

Thư mục được dọn ở bước 3 (tính từ `$HERMES_HOME`, mặc định `~/.hermes`):

```
cache/documents  cache/images  cache/audio  cache/videos  cache/screenshots  cache/web
cache/delegation cache/spillover cache/exec cache/generated cache/scratch    cache/terminal
cache/browser-use/workspace  images  attachments  composer-pastes
# và các tên cũ: document_cache image_cache audio_cache video_cache browser_screenshots
#                web_cache delegation_cache exec_spill
```

## Job giữ lại gì

- Session đã **pin**, cùng các session con/nối tiếp của nó.
- Session **Bot Chat** chính của Bot Mode khi nó còn mở.
- Session còn mở có hoạt động trong `IDLE_HOURS` gần nhất. Session đang chạy dở thì Hermes tự từ chối xoá.
- Mục trong thư mục cache có file được sửa trong `MIN_AGE_MINUTES` phút gần nhất (mặc định 60), để không phá session đang dùng.
- File/thư mục ẩn (`.locks`, `.last_prune`, ...): dữ liệu nội bộ của Hermes.
- Bản thân các thư mục cache (chỉ xoá nội dung bên trong).
- Toàn bộ phần còn lại: `config.yaml`, `.env`, `auth.json`, memories, skills, `kanban.db`, các job cron và file trong project của bạn.

Hai thư mục được **cố ý bỏ qua**:

- `cron/output/`: tính năng `context_from` đọc thư mục này để nối kết quả giữa các job, và Hermes đã tự giữ
  tối đa `cron.output_retention` (mặc định 50) lần chạy.
- `cache/partials/`: phần tải về dở và file khoá của trình quản lý gói, không phải artifacts chat.

## Yêu cầu

- Hermes Agent đã cài và **gateway đang chạy** (`hermes gateway start`). Job cron chỉ được kích hoạt bởi gateway.
- macOS hoặc Linux, có `bash` và `sqlite3`.
- Đã kiểm thử với Hermes Agent v0.23.0 trên macOS.

## Cài đặt

```bash
git clone https://github.com/vibeailabs-tech/hermes-cron-cleanup.git
cd hermes-cron-cleanup

# Hermes chỉ chạy script nằm trong ~/.hermes/scripts/
mkdir -p ~/.hermes/scripts
cp hermes-nightly-cleanup.sh ~/.hermes/scripts/
chmod +x ~/.hermes/scripts/hermes-nightly-cleanup.sh
```

Chạy thử trước. Chế độ `--dry-run` chỉ liệt kê, không xoá gì:

```bash
bash ~/.hermes/scripts/hermes-nightly-cleanup.sh --dry-run
```

```
== Hermes nightly cleanup 2026-11-06 13:18 [DRY RUN]
-- 1. Session còn mở, idle >= 2h
-- 2. Session đã kết thúc
2 session(s) match (last active before 2026-11-06 13:18; ...):
  20261014_232243_5b9579  2026-10-14 23:22  desktop    welcome     0 msgs  Bot Chat
  local-6a7d...c205       2026-10-24 02:39  local      claude-opus 0 msgs
Dry run — nothing deleted.
-- 3. File tạm / artifacts
  composer-pastes: 14 file (~168 KB)
Tổng: 14 file (~0 MB) — chưa xoá (dry run)
```

Tạo job chạy lúc 23:00 hằng ngày:

```bash
hermes cron create "0 23 * * *" \
  --no-agent \
  --script hermes-nightly-cleanup.sh \
  --deliver local \
  --timezone Asia/Ho_Chi_Minh \
  --name nightly-cleanup
```

Đổi `--timezone` theo múi giờ của bạn (tên IANA, ví dụ `Asia/Tokyo`, `Europe/Berlin`).

## Quản lý job

```bash
hermes cron list                          # xem job và lần chạy kế tiếp
hermes cron runs                          # lịch sử các lần chạy
hermes cron run nightly-cleanup           # chạy ngay ở tick kế tiếp (sẽ XOÁ thật)
hermes cron pause nightly-cleanup         # tạm dừng
hermes cron resume nightly-cleanup        # chạy lại
hermes cron edit nightly-cleanup --schedule "0 2 * * *"   # đổi giờ chạy
hermes cron remove nightly-cleanup        # gỡ job
```

## Nhận thông báo

Với `--deliver local`, job chạy im lặng và **thông báo lỗi cũng bị tắt**. Kết quả xem bằng `hermes cron runs`.

- Chỉ muốn được báo khi lỗi: thêm `--failure-deliver telegram` (hoặc `discord`, `slack`, ...).
- Muốn nhận báo cáo mỗi đêm: dùng `--deliver telegram` thay cho `--deliver local`.

Nền tảng nhắn tin phải được cấu hình trước trong Hermes (ví dụ `TELEGRAM_BOT_TOKEN` trong `~/.hermes/.env`).
Script trả exit code khác 0 khi có bước nào lỗi, nên Hermes sẽ đánh dấu lần chạy đó là thất bại.

## Tuỳ chỉnh

Sửa trực tiếp ở đầu `~/.hermes/scripts/hermes-nightly-cleanup.sh`:

| Biến | Mặc định | Ý nghĩa |
|---|---|---|
| `IDLE_HOURS` | `2` | Session còn mở phải idle ít nhất chừng này giờ mới bị xoá |
| `MIN_AGE_MINUTES` | `60` | Mục trong cache có file sửa gần hơn mốc này được giữ lại |
| `TEMP_DIRS` | xem trên | Danh sách thư mục cache được dọn |

## Lưu ý

- **Không thể khôi phục.** Session đã xoá là mất hẳn. Muốn giữ session nào thì pin nó trước
  (`hermes sessions pin <id>`) hoặc export ra file (`hermes sessions export`).
- **Dung lượng giải phóng thường nhỏ.** Phần nặng nhất của `~/.hermes` là bản thân Hermes
  (`hermes-agent/`, `installs/`, `tools/`, `cache/uv`). Đừng xoá các thư mục này.
- **`state.db` không co lại ngay.** Lệnh `hermes sessions optimize` (VACUUM) bị từ chối khi gateway đang chạy
  nên script không dùng nó. Hermes sẽ tự VACUUM khi số trang trống đủ lớn.
- **Máy ngủ/tắt lúc 23:00:** với cấu hình mặc định (`cron.catch_up_missed: true`), job chạy bù **một lần** ngay khi
  gateway hoạt động lại, có thể là giữa ban ngày. Nếu không muốn dọn dẹp lúc đang làm việc, tạo job với `--catch-up off`
  (hoặc `hermes cron edit nightly-cleanup --catch-up off`) để bỏ qua lần bị lỡ.
- **Bước 1 đọc thẳng schema của `state.db`** (chỉ đọc). Nếu một bản cập nhật Hermes đổi schema, bước này sẽ báo
  `Không đọc được state.db` và job được đánh dấu thất bại. Khi đó hãy chạy lại `--dry-run` để kiểm tra.
- Profile khác của Hermes: chạy với `HERMES_HOME` trỏ tới profile đó.
