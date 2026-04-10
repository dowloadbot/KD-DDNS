#!/bin/bash

# ================= 动态对接配置区 =================
PANEL_URL="${1}"
PANEL_KEY="${2}"
NODE_ID="${3}"

if [ -z "$PANEL_URL" ] || [ -z "$PANEL_KEY" ] || [ -z "$NODE_ID" ]; then
    echo "用法: bash deploy.sh <面板地址> <通信密钥> <节点ID>"
    exit 1
fi

# 1. 清理环境
systemctl stop v2bx 2>/dev/null
rm -rf /etc/V2bX && mkdir -p /etc/V2bX
apt-get update -y && apt-get install -y wget curl unzip jq tar ca-certificates

# 2. 更加健壮的下载逻辑
cd /etc/V2bX

# 尝试获取最新版本号 (例如 v0.5.0)
TAG=$(curl -s https://api.github.com/repos/Shannon-x/V2bX/releases/v1.1.202604040547| jq -r .tag_name)

# 如果 API 挂了或被限流，我们手动指定一个已知的稳定版（防止变量为空）
if [ -z "$TAG" ] || [ "$TAG" == "null" ]; then
    echo "警告：GitHub API 请求失败，尝试使用硬编码地址..."
    # 你可以在这里填入一个确定的版本号，或者直接尝试 release/latest
    DOWNLOAD_URL="https://github.com/Shannon-x/V2bX/releases/download/v1.1.202604040547/V2bX-linux-64.zip"
else
    echo "检测到最新版本: $TAG"
    DOWNLOAD_URL="https://github.com/Shannon-x/V2bX/releases/download/${TAG}/V2bX-linux-64.zip"
fi

echo "开始下载: $DOWNLOAD_URL"

# 使用 curl -L (跟随重定向) 并且设置重试
curl -L -f -O "$DOWNLOAD_URL" --retry 3 --connect-timeout 10

# 检查文件是否下载成功
if [ ! -f "V2bX-linux-64.zip" ]; then
    echo "错误：下载失败，请检查 VPS 到 GitHub 的网络连接！"
    exit 1
fi

# 检查文件大小 (如果小于 1MB，肯定是下载错了)
FILE_SIZE=$(stat -c%s "V2bX-linux-64.zip")
if [ "$FILE_SIZE" -lt 1000000 ]; then
    echo "错误：下载的文件太小 ($FILE_SIZE bytes)，可能是 API 报错页面而非压缩包。"
    echo "文件内容前几行为："
    head -n 5 V2bX-linux-64.zip
    exit 1
fi

# 3. 解压并寻找执行文件
unzip -o V2bX-linux-64.zip
V2BX_BIN=$(find . -name "V2bX" -type f | head -n 1)

if [ -n "$V2BX_BIN" ]; then
    mv "$V2BX_BIN" /etc/V2bX/V2bX
    chmod +x /etc/V2bX/V2bX
else
    echo "错误：压缩包内未找到执行文件！"
    exit 1
fi

# 4. 生成配置文件 (Vless)
cat <<EOF > /etc/V2bX/config.json
{
  "Log": { "Level": "error", "Output": "/etc/V2bX/log" },
  "Cores": [ { "Type": "xray", "Log": { "Level": "none" } } ],
  "Nodes": [
    {
      "Core": "xray",
      "ApiHost": "${PANEL_URL}",
      "ApiKey": "${PANEL_KEY}",
      "NodeID": ${NODE_ID},
      "NodeType": "vless",
      "Timeout": 30,
      "ApiVersion": 1,
      "ListenIP": "0.0.0.0",
      "SendIP": "0.0.0.0",
      "DeviceOnlineMinTraffic": 200,
      "ReportMinTraffic": 0,
      "EnableProxyProtocol": false,
      "EnableUot": true,
      "EnableTFO": false,
      "DNSType": "UseIPv4",
      "DisableSniffing": false
    }
  ]
}
EOF
# 5. 更改custom_outbound.json文件
curl -L -o /etc/V2bX/custom_outbound.json https://file.giegie.cloud/Others/v2bx/custom_outbound.json
# 6.更改route.json文件
cat <<EOF > /etc/V2bX/route.json
{
    "domainStrategy": "IPIfNonMatch", 
    "rules": [
        {
            "type": "field",
            "outboundTag": "dmm",
            "domain": [
                "domain:dmm.com",
                "domain:dmm.co.jp"
            ]
        },
        {
            "type": "field",
            "outboundTag": "javdb",
            "domain": [
                "domain:javdb.com",
                "domain:jdbstatic.com"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "ip": [
                "geoip:private"
            ]
        },
        {
            "type": "field",
            "outboundTag": "block",
            "protocol": [
                "bittorrent"
            ]
        },
        {
            "type": "field",
            "outboundTag": "IPv6_out",
            "domain": [
                "geosite:netflix"
            ]
        }
    ]
}
EOF
# 7. 写入 Systemd 服务
cat <<EOF > /etc/systemd/system/v2bx.service
[Unit]
Description=V2bX Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/etc/V2bX
ExecStart=/etc/V2bX/V2bX server -c /etc/V2bX/config.json
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

# 6. 启动
systemctl daemon-reload
systemctl enable v2bx
systemctl restart v2bx

echo "================ 部署执行完毕 ================"
sleep 2
systemctl status v2bx --no-pager -n 20
