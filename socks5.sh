#!/bin/bash

# Dừng lại ngay nếu có lỗi
set -e

echo "==================================================================="
echo "Bắt đầu cài đặt SOCKS5 Proxy - Phiên bản Sửa lỗi (v2)..."
echo "==================================================================="

# 1. TẠO THÔNG SỐ NGẪU NHIÊN
echo "[1/5] Đang tạo thông tin đăng nhập và port ngẫu nhiên..."
PROXY_USER="user$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
PROXY_PORT=$((RANDOM % 55535 + 10000))
FIREWALL_RULE_NAME="allow-socks-auto-$PROXY_PORT"
echo "Đã tạo thông tin ngẫu nhiên."

# 2. CÀI ĐẶT VÀ CẤU HÌNH DANTE
echo "[2/5] Đang cài đặt và cấu hình dante-server..."
sudo apt-get update > /dev/null
sudo apt-get install dante-server -y > /dev/null
sudo useradd --shell /usr/sbin/nologin "$PROXY_USER" > /dev/null 2>&1 || true
echo "$PROXY_USER:$PROXY_PASS" | sudo chpasswd
INTERFACE=$(ip -o -4 route show to default | awk '{print $5}')
sudo tee /etc/danted.conf > /dev/null <<EOF
logoutput: syslog
internal: $INTERFACE port = $PROXY_PORT
external: $INTERFACE
method: username
user.privileged: root
user.notprivileged: nobody
client pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
socks pass { from: 0.0.0.0/0 to: 0.0.0.0/0 }
EOF
echo "Cấu hình Dante hoàn tất."

# 3. KHỞI ĐỘNG DANTE
echo "[3/5] Đang khởi động dịch vụ proxy..."
sudo systemctl restart danted
sudo systemctl enable danted > /dev/null
echo "Dịch vụ đã khởi động."

# 4. TỰ ĐỘNG MỞ FIREWALL (Logic đơn giản hơn)
echo "[4/5] Đang tự động mở Firewall trên Google Cloud..."
# Cài đặt gcloud nếu chưa có
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI chưa được cài đặt. Đang tiến hành cài đặt..."
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
    sudo apt-get install apt-transport-https ca-certificates gnupg -y > /dev/null
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - > /dev/null 2>&1
    sudo apt-get update > /dev/null && sudo apt-get install google-cloud-cli -y > /dev/null
fi

# Chạy lệnh tạo firewall trực tiếp, hiển thị lỗi nếu có
gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network=default \
    --allow=tcp:$PROXY_PORT \
    --source-ranges=0.0.0.0/0 \
    --description="Auto-rule for SOCKS5 proxy on port $PROXY_PORT"

# Kiểm tra xem lệnh gcloud có thành công không
if [ $? -eq 0 ]; then
    echo "✅ TỰ ĐỘNG MỞ FIREWALL THÀNH CÔNG!"
else
    echo "❌ LỖI: Không thể tạo rule firewall. Vui lòng kiểm tra lại lỗi chi tiết ở trên."
    exit 1
fi

# 5. HIỂN THỊ THÔNG TIN
echo "[5/5] Hoàn tất quá trình."
EXTERNAL_IP=$(curl -s ifconfig.me)

echo ""
echo "================================================="
echo "✅ SOCKS5 PROXY ĐÃ SẴN SÀNG! ✅"
echo "================================================="
echo "IP Máy chủ  : $EXTERNAL_IP"
echo "Port        : $PROXY_PORT"
echo "Username    : $PROXY_USER"
echo "Password    : $PROXY_PASS"
echo "================================================="
