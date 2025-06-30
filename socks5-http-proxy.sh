#!/bin/bash
# Script All-in-One: Tự động cài đặt nền tảng (nếu cần) và tạo proxy mới.
# Chạy nhiều lần sẽ tạo ra nhiều proxy hoạt động song song.
set -e

# --- Biến toàn cục ---
SETUP_FLAG_FILE="/etc/multi_proxy_setup_complete"

# --- PHẦN 1: KIỂM TRA VÀ CÀI ĐẶT NỀN TẢNG (CHỈ CHẠY 1 LẦN) ---
if [ ! -f "$SETUP_FLAG_FILE" ]; then
    echo ">>> Lần chạy đầu tiên: Đang cài đặt nền tảng Multi-Proxy..."
    echo "=========================================================="
    sleep 2

    # 1.1. Cài đặt các gói cần thiết
    echo "[SETUP 1/4] Cài đặt các gói: Dante, Squid, Apache Utils..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update > /dev/null
    sudo apt-get install dante-server squid apache2-utils -y > /dev/null

    # 1.2. Tạo các thư mục cấu hình riêng biệt
    echo "[SETUP 2/4] Tạo các thư mục cấu hình riêng biệt..."
    sudo mkdir -p /etc/dante/instances
    sudo mkdir -p /etc/squid/instances
    sudo mkdir -p /etc/squid/passwords

    # 1.3. Vô hiệu hóa dịch vụ gốc để tránh xung đột
    echo "[SETUP 3/4] Vô hiệu hóa các dịch vụ gốc..."
    sudo systemctl stop danted > /dev/null 2>&1 || true
    sudo systemctl disable danted > /dev/null 2>&1 || true
    sudo systemctl stop squid > /dev/null 2>&1 || true
    sudo systemctl disable squid > /dev/null 2>&1 || true

    # 1.4. Tạo file khuôn mẫu (template) cho dịch vụ
    echo "[SETUP 4/4] Tạo các file khuôn mẫu dịch vụ systemd..."
    # Khuôn mẫu cho Dante (SOCKS5)
    sudo tee /etc/systemd/system/danted-inst@.service > /dev/null <<'EOF'
[Unit]
Description=Dante SOCKS Proxy Instance %I
After=network.target
[Service]
Type=forking
ExecStart=/usr/sbin/danted -f /etc/dante/instances/danted-%i.conf -p /var/run/danted-%i.pid
PIDFile=/var/run/danted-%i.pid
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    # Khuôn mẫu cho Squid (HTTP)
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
    sudo systemctl daemon-reload

    # Đánh dấu đã cài đặt xong
    sudo touch "$SETUP_FLAG_FILE"
    echo "✅ CÀI ĐẶT NỀN TẢNG HOÀN TẤT!"
    echo "=========================================================="
else
    echo ">>> Nền tảng đã được cài đặt. Bắt đầu tạo proxy mới..."
fi

# --- PHẦN 2: TẠO PROXY MỚI (LUÔN LUÔN CHẠY) ---
# 2.1. Xác định ID cho instance mới
INSTANCE_ID=$(($(find /etc/squid/instances/ -type f -name "squid-*.conf" 2>/dev/null | wc -l) + 1))
echo "[CREATE 1/5] Đang tạo cặp Proxy số: $INSTANCE_ID"

# 2.2. Tạo thông số ngẫu nhiên
PROXY_USER="user${INSTANCE_ID}_$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
# Đảm bảo port không bao giờ trùng nhau giữa các instance
SOCKS_PORT=$((10000 + $INSTANCE_ID * 2))
HTTP_PORT=$((40000 + $INSTANCE_ID * 2))

# 2.3. Tạo file cấu hình và mật khẩu riêng
echo "[CREATE 2/5] Đang tạo các file cấu hình riêng cho Instance #$INSTANCE_ID..."
sudo htpasswd -cb /etc/squid/passwords/passwd-$INSTANCE_ID "$PROXY_USER" "$PROXY_PASS" > /dev/null
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
# Cấu hình Dante
sudo tee /etc/dante/instances/danted-$INSTANCE_ID.conf > /dev/null <<EOF
logoutput: syslog
internal: $INTERFACE port = $SOCKS_PORT
external: $INTERFACE
method: username
user.privileged: root
user.unprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
# Cấu hình Squid
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

# 2.4. Khởi động Instance dịch vụ mới
echo "[CREATE 3/5] Đang khởi động và kích hoạt Instance #$INSTANCE_ID..."
sudo systemctl restart danted-inst@$INSTANCE_ID > /dev/null 2>&1 || true
sudo systemctl enable --now danted-inst@$INSTANCE_ID > /dev/null
sudo systemctl restart squid-inst@$INSTANCE_ID > /dev/null 2>&1 || true
sudo systemctl enable --now squid-inst@$INSTANCE_ID > /dev/null

# 2.5. Mở Firewall
echo "[CREATE 4/5] Đang tự động mở port $SOCKS_PORT và $HTTP_PORT trên Firewall..."
# Cài đặt gcloud nếu chưa có
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI chưa được cài đặt. Đang tiến hành cài đặt..."
    sudo apt-get install apt-transport-https ca-certificates gnupg -y > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - > /dev/null 2>&1
    sudo apt-get update > /dev/null && sudo apt-get install google-cloud-cli -y > /dev/null
fi
FIREWALL_RULE_NAME="allow-proxies-inst-$INSTANCE_ID"
gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network=default \
    --allow=tcp:$SOCKS_PORT,tcp:$HTTP_PORT \
    --source-ranges=0.0.0.0/0 \
    --description="Rule for Proxy Instance #$INSTANCE_ID" > /dev/null 2>&1 || true
echo "Firewall đã được cấu hình."

# 2.6. Hiển thị thông tin
echo "[CREATE 5/5] Hoàn tất!"
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
