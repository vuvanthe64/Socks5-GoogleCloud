#!/bin/bash

# Dừng lại ngay nếu có lỗi
set -e

echo "=========================================================="
echo "Bắt đầu cài đặt SOCKS5 Proxy với thông số ngẫu nhiên..."
echo "=========================================================="

# 1. TẠO THÔNG SỐ NGẪU NHIÊN
echo "[1/6] Đang tạo thông tin đăng nhập và port ngẫu nhiên..."
PROXY_USER="user$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
PROXY_PORT=$((RANDOM % 55535 + 10000)) # Port ngẫu nhiên từ 10000-65535
echo "Đã tạo thông tin ngẫu nhiên."

# 2. CÀI ĐẶT DANTE
echo "[2/6] Đang cài đặt các gói cần thiết (dante-server)..."
sudo apt-get update > /dev/null
sudo apt-get install dante-server -y > /dev/null
echo "Cài đặt Dante hoàn tất."

# 3. CẤU HÌNH DANTE
echo "[3/6] Đang cấu hình Dante..."
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

# 4. KHỞI ĐỘNG DANTE
echo "[4/6] Đang khởi động dịch vụ proxy..."
sudo systemctl restart danted
sudo systemctl enable danted > /dev/null
echo "Dịch vụ đã khởi động."

# 5. TỰ ĐỘNG MỞ FIREWALL (Yêu cầu gcloud và quyền)
echo "[5/6] Đang cố gắng tự động mở Firewall trên Google Cloud..."
if ! command -v gcloud &> /dev/null; then
    echo "gcloud CLI chưa được cài đặt. Đang tiến hành cài đặt..."
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    sudo apt-get install apt-transport-https ca-certificates gnupg -y > /dev/null
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - > /dev/null
    sudo apt-get update > /dev/null && sudo apt-get install google-cloud-cli -y > /dev/null
fi

FIREWALL_RULE_NAME="allow-socks-auto-$PROXY_PORT"
NETWORK_TAGS=$(curl -s "http://metadata.google.internal/computeMetadata/v1/instance/tags" -H "Metadata-Flavor: Google" | jq -r 'join(",")' 2>/dev/null)

# Lệnh tạo firewall
FIREWALL_CMD="gcloud compute firewall-rules create $FIREWALL_RULE_NAME --allow tcp:$PROXY_PORT --description 'Auto-generated rule for SOCKS5' --direction INGRESS"

# Thêm target-tags nếu có
if [ -n "$NETWORK_TAGS" ] && [ "$NETWORK_TAGS" != "null" ]; then
    FIREWALL_CMD="$FIREWALL_CMD --target-tags $NETWORK_TAGS"
fi

if $FIREWALL_CMD > /dev/null 2>&1; then
    echo "✅ TỰ ĐỘNG MỞ FIREWALL THÀNH CÔNG!"
else
    echo "❌ KHÔNG THỂ TỰ ĐỘNG MỞ FIREWALL."
    echo "Lý do phổ biến nhất là do máy ảo chưa được cấp đủ quyền."
    echo "Vui lòng làm theo hướng dẫn ở Bước 1 hoặc mở port $PROXY_PORT thủ công."
fi

# 6. HIỂN THỊ THÔNG TIN
echo "[6/6] Hoàn tất quá trình."
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
