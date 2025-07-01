#!/bin/bash
# Script All-in-One v9 - Dùng port ngẫu nhiên và tự động kiểm tra chống trùng lặp.
set -e

# --- Biến toàn cục ---
SETUP_FLAG_FILE="/etc/multi_proxy_setup_complete_v8" # Dùng lại cờ của v8

# --- PHẦN 1: KIỂM TRA VÀ CÀI ĐẶT/CẬP NHẬT NỀN TẢNG ---
if [ ! -f "$SETUP_FLAG_FILE" ]; then
    echo ">>> Lần chạy đầu tiên (hoặc cần cập nhật): Đang cài đặt/cập nhật nền tảng..."
    echo "=========================================================="
    sleep 1
    # 1.1. Cài đặt các gói
    echo "[SETUP 1/4] Cài đặt các gói..."
    export DEBIAN_FRONTEND=noninteractive
    sudo apt-get update > /dev/null
    sudo apt-get install dante-server squid apache2-utils jq -y > /dev/null
    # 1.2. Tạo thư mục
    echo "[SETUP 2/4] Tạo các thư mục cấu hình..."
    sudo mkdir -p /etc/dante/instances /etc/squid/instances /etc/squid/passwords
    # 1.3. Vô hiệu hóa dịch vụ gốc
    echo "[SETUP 3/4] Vô hiệu hóa các dịch vụ gốc..."
    sudo systemctl disable --now danted > /dev/null 2>&1 || true
    sudo systemctl disable --now squid > /dev/null 2>&1 || true
    # 1.4. Tạo file khuôn mẫu
    echo "[SETUP 4/4] Tạo các file khuôn mẫu dịch vụ systemd..."
    sudo tee /etc/systemd/system/danted-inst@.service > /dev/null <<'EOF'
[Unit]
Description=Dante SOCKS Proxy Instance %I
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/danted -N -f /etc/dante/instances/danted-%i.conf
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
Type=simple
ExecStart=/usr/sbin/squid -N -f /etc/squid/instances/squid-%i.conf
ExecReload=/usr/sbin/squid -k reconfigure -f /etc/squid/instances/squid-%i.conf
Restart=always
RestartSec=5s
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo rm -f /etc/multi_proxy_setup_complete_*
    sudo touch "$SETUP_FLAG_FILE"
    echo "✅ CÀI ĐẶT/CẬP NHẬT NỀN TẢNG HOÀN TẤT!"
    echo "=========================================================="
else
    echo ">>> Nền tảng đã ổn. Bắt đầu tạo proxy mới..."
fi

# --- PHẦN 2: TẠO PROXY MỚI ---
INSTANCE_ID=$(($(find /etc/squid/instances/ -type f -name "squid-*.conf" 2>/dev/null | wc -l) + 1))
echo "[CREATE 1/6] Đang tạo cặp Proxy số: $INSTANCE_ID"

PROXY_USER="user${INSTANCE_ID}_$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)"
PROXY_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

echo "[CREATE 2/6] Đang tìm kiếm port ngẫu nhiên còn trống..."
# Vòng lặp tìm port SOCKS5 ngẫu nhiên và còn trống
while true; do
    SOCKS_PORT=$((RANDOM % 55535 + 10000))
    # Nếu lệnh 'ss' không tìm thấy port thì port đó còn trống -> thoát vòng lặp
    if ! sudo ss -lntu | grep -q ":${SOCKS_PORT}\b"; then
        break
    fi
done

# Vòng lặp tìm port HTTP ngẫu nhiên, còn trống và không trùng port SOCKS5
while true; do
    HTTP_PORT=$((RANDOM % 55535 + 10000))
    if ! sudo ss -lntu | grep -q ":${HTTP_PORT}\b" && [ "$HTTP_PORT" -ne "$SOCKS_PORT" ]; then
        break
    fi
done
echo "Đã tìm thấy các port phù hợp: SOCKS5 ($SOCKS_PORT), HTTP ($HTTP_PORT)"

echo "[CREATE 3/6] Đang tạo các file cấu hình riêng cho Instance #$INSTANCE_ID..."
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
SQUID_CONF_PATH="/etc/squid/instances/squid-$INSTANCE_ID.conf"
sudo tee "$SQUID_CONF_PATH" > /dev/null <<EOF
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords/passwd-$INSTANCE_ID
auth_param basic realm "Squid Proxy Instance $INSTANCE_ID"
acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all
http_port $HTTP_PORT
via off
forwarded_for off
EOF

echo "[CREATE 4/6] Đang khởi tạo cache cho Squid Instance #$INSTANCE_ID..."
sudo /usr/sbin/squid -z -f "$SQUID_CONF_PATH" > /dev/null 2>&1 || echo "Squid cache đã tồn tại, bỏ qua."

echo "[CREATE 5/6] Đang khởi động và kích hoạt Instance #$INSTANCE_ID..."
sudo systemctl enable --now danted-inst@$INSTANCE_ID
sudo systemctl enable --now squid-inst@$INSTANCE_ID

echo "[CREATE 6/6] Đang tự động mở port $SOCKS_PORT và $HTTP_PORT trên Firewall..."
if ! command -v gcloud &> /dev/null; then sudo apt-get install google-cloud-cli -y > /dev/null; fi
FIREWALL_RULE_NAME="allow-proxies-inst-$INSTANCE_ID"
gcloud compute firewall-rules delete "$FIREWALL_RULE_NAME" --quiet > /dev/null 2>&1 || true
gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network=default \
    --allow=tcp:$SOCKS_PORT,tcp:$HTTP_PORT \
    --source-ranges=0.0.0.0/0 \
    --description="Rule for Proxy Instance #$INSTANCE_ID" > /dev/null 2>&1 || true
echo "Firewall đã được cấu hình."

EXTERNAL_IP=$(curl -s ifconfig.me)
echo ""
echo "=========================================================="
echo "✅ ĐÃ TẠO THÀNH CÔNG PROXY INSTANCE #$INSTANCE_ID ✅"
echo "=========================================================="
echo "(Các proxy cũ của bạn (nếu có) vẫn đang hoạt động bình thường)"
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
