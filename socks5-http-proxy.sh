#!/bin/bash

# Dừng lại ngay nếu có lỗi
set -e

echo "==================================================================="
echo "Bắt đầu cài đặt song song SOCKS5 (Dante) & HTTP (Squid)..."
echo "==================================================================="

# 1. TẠO THÔNG SỐ NGẪU NHIÊN
echo "[1/7] Đang tạo thông tin đăng nhập và port ngẫu nhiên..."
PROXY_USER="user$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
SOCKS_PORT=$((RANDOM % 25000 + 10000))  # Port cho SOCKS5 (10000-34999)
HTTP_PORT=$((RANDOM % 25000 + 40000))   # Port cho HTTP (40000-64999)
echo "Đã tạo thông tin ngẫu nhiên."

# 2. CÀI ĐẶT CÁC GÓI CẦN THIẾT
echo "[2/7] Đang cài đặt các gói cần thiết (Dante, Squid, Apache Utils)..."
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update > /dev/null
sudo apt-get install dante-server squid apache2-utils -y > /dev/null
echo "Cài đặt hoàn tất."

# 3. CẤU HÌNH USERNAME/PASSWORD CHUNG
echo "[3/7] Đang tạo người dùng và mật khẩu chung..."
# Tạo user cho Dante
sudo useradd --shell /usr/sbin/nologin "$PROXY_USER" > /dev/null 2>&1 || true
echo "$PROXY_USER:$PROXY_PASS" | sudo chpasswd
# Tạo file mật khẩu cho Squid
sudo htpasswd -cb /etc/squid/passwd "$PROXY_USER" "$PROXY_PASS" > /dev/null
echo "Tạo mật khẩu chung hoàn tất."

# 4. CẤU HÌNH SOCKS5 (DANTE)
echo "[4/7] Đang cấu hình SOCKS5 trên port $SOCKS_PORT..."
INTERFACE_DANTE=$(ip -o -4 route show to default | awk '{print $5}')
sudo tee /etc/danted.conf > /dev/null <<EOF
logoutput: syslog
internal: $INTERFACE_DANTE port = $SOCKS_PORT
external: $INTERFACE_DANTE
method: username
user.privileged: root
user.notprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
echo "Cấu hình Dante hoàn tất."

# 5. CẤU HÌNH HTTP (SQUID)
echo "[5/7] Đang cấu hình HTTP Proxy trên port $HTTP_PORT..."
sudo mv /etc/squid/squid.conf /etc/squid/squid.conf.original > /dev/null 2>&1 || true
sudo tee /etc/squid/squid.conf > /dev/null <<EOF
# --- Cấu hình xác thực ---
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwd
auth_param basic realm "Squid Proxy"
acl authenticated proxy_auth REQUIRED

# --- Cấu hình truy cập ---
http_access allow authenticated
http_access deny all
http_port $HTTP_PORT

# --- Cấu hình ẩn danh (High Anonymity) ---
via off
forwarded_for off
request_header_access From deny all
request_header_access Server deny all
request_header_access WWW-Authenticate deny all
request_header_access Link deny all
request_header_access X-Forwarded-For deny all
request_header_access Via deny all
request_header_access Cache-Control deny all
EOF
echo "Cấu hình Squid hoàn tất."

# 6. KHỞI ĐỘNG CÁC DỊCH VỤ
echo "[6/7] Đang khởi động và kích hoạt Dante & Squid..."
sudo systemctl restart danted
sudo systemctl enable danted > /dev/null
sudo systemctl restart squid
sudo systemctl enable squid > /dev/null
echo "Các dịch vụ đã khởi động."

# 7. TỰ ĐỘNG MỞ FIREWALL CHO CẢ 2 PORT
echo "[7/7] Đang tự động mở 2 port ($SOCKS_PORT, $HTTP_PORT) trên Firewall..."
# Cài đặt gcloud nếu chưa có
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI chưa được cài đặt. Đang tiến hành cài đặt..."
    sudo apt-get install apt-transport-https ca-certificates gnupg -y > /dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - > /dev/null 2>&1
    sudo apt-get update > /dev/null && sudo apt-get install google-cloud-cli -y > /dev/null
fi

FIREWALL_RULE_NAME="allow-proxies-auto-$(date +%s)"
# Chạy lệnh tạo firewall, mở cả 2 port cùng lúc
gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network=default \
    --allow=tcp:$SOCKS_PORT,tcp:$HTTP_PORT \
    --source-ranges=0.0.0.0/0 \
    --description="Auto-rule for SOCKS5 and HTTP proxies"

if [ $? -eq 0 ]; then
    echo "✅ TỰ ĐỘNG MỞ FIREWALL THÀNH CÔNG!"
else
    echo "❌ LỖI: Không thể tạo rule firewall. Vui lòng kiểm tra lại lỗi chi tiết ở trên."
    exit 1
fi

# HIỂN THỊ THÔNG TIN
EXTERNAL_IP=$(curl -s ifconfig.me)
echo ""
echo "=========================================================="
echo "✅ CÀI ĐẶT SONG SONG HOÀN TẤT! ✅"
echo "=========================================================="
echo ""
echo "--- [ SOCKS5 PROXY ] -----------------------------------"
echo "IP Máy chủ      : $EXTERNAL_IP"
echo "Port SOCKS5     : $SOCKS_PORT"
echo "Username        : $PROXY_USER"
echo "Password        : $PROXY_PASS"
echo "Chuỗi kết nối   : $PROXY_USER:$PROXY_PASS@$EXTERNAL_IP:$SOCKS_PORT"
echo "--------------------------------------------------------"
echo ""
echo "--- [ HTTP PROXY ] -------------------------------------"
echo "IP Máy chủ      : $EXTERNAL_IP"
echo "Port HTTP       : $HTTP_PORT"
echo "Username        : $PROXY_USER"
echo "Password        : $PROXY_PASS"
echo "Chuỗi kết nối   : http://$PROXY_USER:$PROXY_PASS@$EXTERNAL_IP:$HTTP_PORT"
echo "--------------------------------------------------------"
echo ""
