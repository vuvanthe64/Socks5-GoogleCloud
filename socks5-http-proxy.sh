#!/bin/bash
set -e

# ===================================================================
# SCRIPT TẤT CẢ TRONG MỘT
# Tự động cài đặt nền tảng nếu cần, và thêm proxy mới.
# ===================================================================

# --- PHẦN 1: KIỂM TRA VÀ CÀI ĐẶT NỀN TẢNG (CHỈ CHẠY NẾU CẦN) ---

# Kiểm tra xem file khuôn mẫu đã tồn tại chưa, nếu chưa thì tiến hành cài đặt.
if [ ! -f "/etc/systemd/system/danted-inst@.service" ]; then
    echo ">>> Lần chạy đầu tiên được phát hiện. Bắt đầu cài đặt nền tảng..."
    echo "-------------------------------------------------------------------"
    
    # 1. Cài đặt các gói cần thiết
    echo "[NỀN TẢNG] Cài đặt các gói: Dante, Squid, Apache Utils..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update > /dev/null
    sudo apt-get install dante-server squid apache2-utils -y > /dev/null

    # 2. Tạo các thư mục cấu hình riêng biệt
    echo "[NỀN TẢNG] Tạo các thư mục cấu hình riêng biệt..."
    sudo mkdir -p /etc/dante/instances
    sudo mkdir -p /etc/squid/instances
    sudo mkdir -p /etc/squid/passwords

    # 3. Vô hiệu hóa dịch vụ gốc để tránh xung đột
    echo "[NỀN TẢNG] Vô hiệu hóa các dịch vụ gốc..."
    sudo systemctl disable --now danted > /dev/null 2>&1 || true
    sudo systemctl disable --now squid > /dev/null 2>&1 || true

    # 4. Tạo file khuôn mẫu (template) cho dịch vụ
    echo "[NỀN TẢNG] Tạo các file khuôn mẫu dịch vụ systemd..."
    sudo tee /etc/systemd/system/danted-inst@.service > /dev/null <<'EOF'
[Unit]
Description=Dante SOCKS Proxy Instance %I
After=network.target
[Service]
Type=forking
ExecStart=/usr/sbin/danted -f /etc/dante/instances/danted-%i.conf -p /var/run/danted-%i.pid
PIDFile=/var/run/danted-%i.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    sudo tee /etc/systemd/system/squid-inst@.service > /dev/null <<'EOF'
[Unit]
Description=Squid Proxy Instance %I
After=network.target
[Service]
Type=forking
ExecStartPre=/usr/sbin/squid -z -f /etc/squid/instances/squid-%i.conf
ExecStart=/usr/sbin/squid -f /etc/squid/instances/squid-%i.conf
PIDFile=/var/run/squid/squid-%i.pid
ExecReload=/bin/kill -HUP $MAINPID
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

    # 5. Nạp lại cấu hình systemd
    sudo systemctl daemon-reload
    echo "-------------------------------------------------------------------"
    echo "✅ Cài đặt nền tảng hoàn tất. Giờ sẽ tạo cặp proxy đầu tiên."
    echo "-------------------------------------------------------------------"
fi

# --- PHẦN 2: TẠO MỘT CẶP PROXY MỚI (LUÔN LUÔN CHẠY) ---

echo ""
echo ">>> Bắt đầu tạo một cặp Proxy mới..."

# 1. Xác định ID cho instance mới
INSTANCE_ID=$(($(ls -1 /etc/squid/instances/squid-*.conf 2>/dev/null | wc -l) + 1))
echo "[1/5] Đây là cặp Proxy số: $INSTANCE_ID"

# 2. Tạo thông số ngẫu nhiên cho instance này
echo "[2/5] Đang tạo thông tin đăng nhập và port ngẫu nhiên..."
PROXY_USER="user${INSTANCE_ID}_$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
SOCKS_PORT=$((10000 + $INSTANCE_ID * 2))
HTTP_PORT=$((40000 + $INSTANCE_ID * 2))

# 3. Tạo file cấu hình và mật khẩu riêng
echo "[3/5] Đang tạo các file cấu hình riêng cho Instance #$INSTANCE_ID..."
sudo htpasswd -cb /etc/squid/passwords/passwd-$INSTANCE_ID "$PROXY_USER" "$PROXY_PASS"
sudo tee /etc/dante/instances/danted-$INSTANCE_ID.conf > /dev/null <<EOF
logoutput: syslog
internal: $(ip -o -4 route show to default | awk '{print $5}') port = $SOCKS_PORT
external: $(ip -o -4 route show to default | awk '{print $5}')
method: username
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
sudo tee /etc/squid/instances/squid-$INSTANCE_ID.conf > /dev/null <<EOF
pid_filename /var/run/squid/squid-$INSTANCE_ID.pid
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords/passwd-$INSTANCE_ID
auth_param basic realm "Squid Proxy Instance $INSTANCE_ID"
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
http_port $HTTP_PORT
via off
forwarded_for off
EOF

# 4. Khởi động Instance dịch vụ mới
echo "[4/5] Đang khởi động và kích hoạt Instance #$INSTANCE_ID..."
sudo systemctl enable --now danted-inst@$INSTANCE_ID
sudo systemctl enable --now squid-inst@$INSTANCE_ID

# 5. Mở Firewall cho các port mới
echo "[5/5] Đang tự động mở port $SOCKS_PORT và $HTTP_PORT trên Firewall..."
FIREWALL_RULE_NAME="allow-proxies-inst-$INSTANCE_ID"
# Xóa rule cũ nếu có để tránh trùng lặp
gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" --quiet > /dev/null 2>&1 || true
# Tạo rule mới
gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network=default \
    --allow=tcp:$SOCKS_PORT,tcp:$HTTP_PORT \
    --source-ranges=0.0.0.0/0 \
    --description="Rule for Proxy Instance #$INSTANCE_ID" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Tự động mở Firewall thành công!"
else
    echo "❌ LỖI: Không thể tạo rule firewall. Vui lòng kiểm tra quyền và mở thủ công."
fi

# Hiển thị thông tin
EXTERNAL_IP=$(curl -s ifconfig.me)
echo ""
echo "=========================================================="
echo "✅ ĐÃ TẠO THÀNH CÔNG PROXY INSTANCE #$INSTANCE_ID ✅"
echo "=========================================================="
echo "(Các proxy cũ của bạn vẫn đang hoạt động bình thường)"
echo ""
echo "--- [ SOCKS5 PROXY #$INSTANCE_ID ] --------------------------------"
echo "IP Máy chủ      : $EXTERNAL_IP"
echo "Port SOCKS5     : $SOCKS_PORT"
echo "Username        : $PROXY_USER"
echo "Password        : $PROXY_PASS"
echo "Chuỗi kết nối   : $PROXY_USER:$PROXY_PASS@$EXTERNAL_IP:$SOCKS_PORT"
echo "--------------------------------------------------------"
echo ""
echo "--- [ HTTP PROXY #$INSTANCE_ID ] ----------------------------------"
echo "IP Máy chủ      : $EXTERNAL_IP"
echo "Port HTTP       : $HTTP_PORT"
echo "Username        : $PROXY_USER"
echo "Password        : $PROXY_PASS"
echo "Chuỗi kết nối   : http://$PROXY_USER:$PROXY_PASS@$EXTERNAL_IP:$HTTP_PORT"
echo "--------------------------------------------------------"
