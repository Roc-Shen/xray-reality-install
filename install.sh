#!/usr/bin/env bash
# Xray VLESS + Reality + Vision 一键部署，输出各客户端的订阅链接
# 对应教程：https://blog.roc.plus/posts/xray-reality-selfhost/
#
# 两种模式（root 执行，Debian 12 / Ubuntu 22.04 / 24.04）：
#   有域名（推荐）：self-steal + HTTPS 订阅链接 + 可选 Cloudflare CDN 备用链路
#     bash install.sh --domain www.example.com [--cdn-domain cdn.example.com] [--email you@example.com]
#   无域名：借用第三方站点做 Reality 目标，只输出分享链接、二维码和本地订阅文件
#     bash install.sh [--target www.nvidia.com]
#   加 --clash：额外生成 Clash 订阅（会安装兼容 Clash 的旧版 Xray，见 CLASH_XRAY_VERSION）
set -euo pipefail

DOMAIN=""
CDN_DOMAIN=""
EMAIL=""
TARGET="www.nvidia.com"
FORCE=0
CLASH=0
# 新版 Xray（v26.9 起）的 REALITY 服务端不再接受 Clash 内核（mihomo）连接，
# 需要 Clash 订阅时固定安装这个版本。等 mihomo 跟进后去掉 --clash 重跑即可升级。
CLASH_XRAY_VERSION="v26.7.11"

usage() {
  cat <<'EOF'
用法：
  bash install.sh --domain www.example.com [--cdn-domain cdn.example.com] [--email you@example.com]
  bash install.sh [--target www.nvidia.com]

  --domain      回落站点域名，需已解析到本机（Cloudflare 灰色云朵）。提供后启用 self-steal 和 HTTPS 订阅
  --cdn-domain  可选，CDN 备用链路域名（Cloudflare 橙色云朵），需同时提供 --domain
  --email       可选，Let's Encrypt 到期提醒邮箱
  --target      无域名模式下借用的站点，默认 www.nvidia.com
  --clash       额外生成 Clash 订阅（Clash Verge / Clash Meta / Stash），会安装兼容 Clash 的旧版 Xray
  --force       443 已被占用时也继续（需自行处理原有服务）
EOF
  exit 1
}
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m错误：\033[0m%s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --cdn-domain) CDN_DOMAIN="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --clash) CLASH=1; shift ;;
    -h|--help) usage ;;
    *) die "未知参数：$1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
[ -z "$CDN_DOMAIN" ] || [ -n "$DOMAIN" ] || die "--cdn-domain 需要和 --domain 一起使用"
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) die "只支持 Debian / Ubuntu，当前是 $ID" ;; esac

# ---------- 1. 前置检查 ----------
log "检查环境"
# 返回监听某端口的进程的可执行文件路径（没人监听则为空）
port_owner() {
  local pid
  pid=$(ss -ltnpH "( sport = :$1 )" | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  [ -n "$pid" ] && readlink -f "/proc/$pid/exe" || true
}
owner443=$(port_owner 443)
# 443 被本脚本装的 Xray 占用时视为重跑，允许继续
if [ -n "$owner443" ] && [ "$owner443" != /usr/local/bin/xray ] && [ "$FORCE" -eq 0 ]; then
  die "443 端口已被 $owner443 占用。
已有网站的机器请先按教程把它们改成 listen 127.0.0.1:8443，或加 --force 跳过此检查。"
fi
if [ -n "$DOMAIN" ]; then
  owner80=$(port_owner 80)
  if [ -n "$owner80" ] && [ "$owner80" != /usr/sbin/nginx ]; then
    die "80 端口已被 $owner80 占用（常见于宝塔等面板自带的 Nginx）。
本脚本会安装系统自带的 Nginx 来申请证书，请先停用原来的 Web 服务，或按教程手动配置。"
  fi
fi

apt-get update -qq
PKGS="curl openssl dnsutils qrencode"
[ -n "$DOMAIN" ] && PKGS="$PKGS nginx certbot"
# shellcheck disable=SC2086
# 已有同名配置文件（比如面板留下的 /etc/init.d/nginx）时保留原文件，不弹交互提示
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
DEBIAN_FRONTEND=noninteractive dpkg --force-confdef --force-confold --configure -a >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install "${APT_OPTS[@]}" $PKGS >/dev/null

SERVER_IP=$(curl -fsS4 --max-time 10 https://api.ipify.org || true)
[ -n "$SERVER_IP" ] || die "获取不到本机公网 IPv4"

if [ -n "$DOMAIN" ]; then
  resolved=$(dig +short A "$DOMAIN" @1.1.1.1 | tail -1)
  [ "$resolved" = "$SERVER_IP" ] || die "$DOMAIN 解析到 ${resolved:-（无记录）}，不是本机 $SERVER_IP。请先改 DNS（灰色云朵），等生效后再运行。"
  if [ -n "$CDN_DOMAIN" ]; then
    [ -n "$(dig +short A "$CDN_DOMAIN" @1.1.1.1)" ] || die "$CDN_DOMAIN 没有 A 记录"
  fi
  SNI="$DOMAIN"
  DEST="127.0.0.1:8443"
else
  SNI="$TARGET"
  DEST="$TARGET:443"
  curl -fsS -o /dev/null --max-time 10 --tlsv1.3 --http2 "https://$TARGET/" \
    || die "$TARGET 不支持 TLS 1.3 + HTTP/2 或无法访问，换一个 --target"
fi

# ---------- 2. BBR ----------
log "启用 BBR"
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -q --system

# ---------- 3. Xray ----------
XRAY_ARGS=()
if [ "$CLASH" -eq 1 ]; then XRAY_ARGS=(--version "$CLASH_XRAY_VERSION"); fi
log "安装 Xray ${XRAY_ARGS[1]:-（最新版）}"
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install "${XRAY_ARGS[@]}" \
  >/var/log/xray-install.log 2>&1 || die "Xray 安装失败，详见 /var/log/xray-install.log"
XRAY=/usr/local/bin/xray

UUID=$($XRAY uuid)
KEYS=$($XRAY x25519)
# 不同版本的输出格式不同："Private key / Public key"、"PrivateKey / Password"、"PrivateKey / Password (PublicKey)"
PRIV=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /^private ?key/ {print $2}')
PUB=$(printf '%s\n' "$KEYS" | awk -F': *' 'tolower($1) ~ /^(public ?key|password)/ {print $2}')
[ -n "$PRIV" ] && [ -n "$PUB" ] || die "无法解析 xray x25519 的输出：$KEYS"
SID=$(openssl rand -hex 8)
WS_PATH="/$(openssl rand -hex 6)"
SUB_TOKEN=$(openssl rand -hex 16)

# ---------- 4. 证书与回落站点（仅有域名时） ----------
if [ -n "$DOMAIN" ]; then
  log "申请证书"
  mkdir -p /var/www/letsencrypt /var/www/site
  [ -s /var/www/site/index.html ] || cat > /var/www/site/index.html <<EOF
<!doctype html><meta charset="utf-8"><title>$DOMAIN</title><h1>Hello from $DOMAIN</h1>
EOF
  rm -f /etc/nginx/sites-enabled/default
  NAMES="$DOMAIN${CDN_DOMAIN:+ $CDN_DOMAIN}"
  cat > /etc/nginx/conf.d/acme.conf <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $NAMES;
    location ^~ /.well-known/acme-challenge/ { root /var/www/letsencrypt; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
  rm -f /etc/nginx/conf.d/site.conf
  nginx -t -q && systemctl restart nginx

  CERT_ARGS=(-d "$DOMAIN")
  [ -n "$CDN_DOMAIN" ] && CERT_ARGS+=(-d "$CDN_DOMAIN")
  if [ -n "$EMAIL" ]; then CERT_ARGS+=(-m "$EMAIL"); else CERT_ARGS+=(--register-unsafely-without-email); fi
  certbot certonly --webroot -w /var/www/letsencrypt --agree-tos --non-interactive \
    --keep-until-expiring --cert-name "$DOMAIN" "${CERT_ARGS[@]}"
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  printf '#!/bin/sh\nsystemctl reload nginx\n' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  log "配置 Nginx 回落站点（127.0.0.1:8443）"
  # nginx 1.25.1 起用 "http2 on;"，更早的版本（如 Debian 12 自带的 1.22）要写在 listen 里
  NGINX_VER=$(nginx -v 2>&1 | grep -o '[0-9.]*$')
  if [ "$(printf '%s\n%s\n' "$NGINX_VER" 1.25.1 | sort -V | head -1)" = 1.25.1 ]; then
    LISTEN_LINE="listen 127.0.0.1:8443 ssl;
    http2 on;"
  else
    LISTEN_LINE="listen 127.0.0.1:8443 ssl http2;"
  fi
  cat > /etc/nginx/conf.d/site.conf <<EOF
server {
    $LISTEN_LINE
    server_name $NAMES;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /var/www/site;

    # 订阅文件放在随机路径下，不列目录
    location /sub/ {
        autoindex off;
        default_type text/plain;
        charset utf-8;
        add_header Cache-Control "no-store";
    }

    location $WS_PATH {
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 1h;
    }
}
EOF
  nginx -t -q
fi

# ---------- 5. Xray 配置 ----------
# 路由规则里屏蔽了 geosite:cn / geoip:cn：境外服务器替你访问国内站点（「回国」流量）
# 是很典型的异常特征，国内网站本就应该由客户端直连。
log "写入 Xray 配置"
# Clash 兼容模式下放宽客户端版本限制，否则 mihomo 会被拒绝
MIN_VER=""
if [ "$CLASH" -eq 1 ]; then MIN_VER=',
          "minClientVer": "0.0.0"'; fi
CDN_INBOUND=""
if [ -n "$CDN_DOMAIN" ]; then
  CDN_INBOUND=$(cat <<EOF
,
    {
      "tag": "cdn",
      "listen": "127.0.0.1",
      "port": 10001,
      "protocol": "vless",
      "settings": { "clients": [{ "id": "$UUID", "email": "cdn@me" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "$WS_PATH" } }
    }
EOF
)
fi
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision", "email": "direct@me" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$DEST",
          "serverNames": ["$SNI"],
          "privateKey": "$PRIV",
          "shortIds": ["$SID"]$MIN_VER
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }$CDN_INBOUND
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "block" },
      { "protocol": ["bittorrent"], "outboundTag": "block" },
      { "domain": ["geosite:category-ads-all"], "outboundTag": "block" },
      { "domain": ["geosite:cn"], "outboundTag": "block" },
      { "ip": ["geoip:cn"], "outboundTag": "block" }
    ]
  }
}
EOF
$XRAY run -test -c /usr/local/etc/xray/config.json >/dev/null

if [ -n "$DOMAIN" ]; then systemctl restart nginx; systemctl enable -q nginx; fi
systemctl restart xray
systemctl enable -q xray
sleep 1
systemctl is-active -q xray || die "Xray 没有启动：journalctl -u xray -e"

# ---------- 6. 生成订阅 ----------
log "生成订阅"
NAME_R="Reality-${SERVER_IP}"
LINK_R="vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUB&sid=$SID&type=tcp#$NAME_R"
LINKS="$LINK_R"
if [ -n "$CDN_DOMAIN" ]; then
  NAME_C="CDN-${CDN_DOMAIN}"
  WS_ENC=$(printf '%s' "$WS_PATH" | sed 's#/#%2F#g')
  LINK_C="vless://$UUID@$CDN_DOMAIN:443?encryption=none&security=tls&sni=$CDN_DOMAIN&type=ws&host=$CDN_DOMAIN&path=$WS_ENC#$NAME_C"
  LINKS="$LINKS
$LINK_C"
fi

if [ -n "$DOMAIN" ]; then SUB_DIR="/var/www/site/sub/$SUB_TOKEN"; else SUB_DIR="/root/xray-sub"; fi
mkdir -p "$SUB_DIR"

# v2rayN / v2rayNG / Shadowrocket：Base64 编码的分享链接列表
printf '%s\n' "$LINKS" | base64 -w0 > "$SUB_DIR/v2ray.txt"

# Clash Verge / Clash Meta for Android / Stash：mihomo 配置（仅 --clash）
if [ "$CLASH" -eq 1 ]; then
{
  cat <<EOF
# 由 install.sh 生成。分流规则数据来自 MetaCubeX/meta-rules-dat
# （整合了 Loyalsoldier/v2ray-rules-dat、v2fly/domain-list-community、felixonmars/dnsmasq-china-list）
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
unified-delay: true
tcp-concurrent: true
geo-auto-update: true
geo-update-interval: 72
geox-url:
  geoip: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.dat
  geosite: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.dat
  mmdb: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter: ['*.lan', '+.local', '+.msftconnecttest.com', '+.msftncsi.com', 'time.*.com', '+.ntp.org', '+.stun.*.*']
  default-nameserver: [223.5.5.5, 119.29.29.29]
  nameserver: [https://dns.alidns.com/dns-query, https://doh.pub/dns-query]
proxies:
  - name: $NAME_R
    type: vless
    server: $SERVER_IP
    port: 443
    uuid: $UUID
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: $SNI
    client-fingerprint: chrome
    reality-opts:
      public-key: $PUB
      short-id: $SID
EOF
  if [ -n "$CDN_DOMAIN" ]; then
    cat <<EOF
  - name: $NAME_C
    type: vless
    server: $CDN_DOMAIN
    port: 443
    uuid: $UUID
    network: ws
    udp: true
    tls: true
    servername: $CDN_DOMAIN
    client-fingerprint: chrome
    ws-opts:
      path: $WS_PATH
      headers:
        Host: $CDN_DOMAIN
EOF
    MEMBERS="[$NAME_R, $NAME_C]"
  else
    MEMBERS="[$NAME_R]"
  fi
  cat <<EOF
proxy-groups:
  - name: 节点选择
    type: select
    proxies: [自动回退, DIRECT]
  # fallback 只在主节点不可用时才切换，不会像 url-test 那样随延迟来回跳，出口 IP 保持稳定
  # lazy：只有在用这个组时才做健康检查，减少无意义的周期性探测流量
  - name: 自动回退
    type: fallback
    url: https://www.gstatic.com/generate_204
    interval: 600
    lazy: true
    proxies: $MEMBERS
rules:
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  - GEOSITE,category-ads-all,REJECT
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  # 禁用境外 QUIC（UDP 443）：浏览器会自动退回 TCP，避免 UDP 走代理带来的不稳定和异常特征
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - GEOSITE,geolocation-!cn,节点选择
  - GEOIP,CN,DIRECT
  - MATCH,节点选择
EOF
} > "$SUB_DIR/clash.yaml"
fi
chmod 644 "$SUB_DIR"/*

# ---------- 7. 自检 ----------
if [ -n "$DOMAIN" ]; then
  log "自检：经 Reality 回落访问伪装站和订阅"
  # 先经公网 IP 访问（和外部访客看到的一致），不通再试本机回环；curl 失败不能让 set -e 静默退出
  # 刚重启的 Xray 可能还没就绪，最多重试约 15 秒
  probe() {
    local ip c i
    for i in 1 2 3 4 5; do
      for ip in "$SERVER_IP" 127.0.0.1; do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$DOMAIN:443:$ip" "https://$DOMAIN$1" || true)
        [ "$c" = 200 ] && { echo 200; return; }
      done
      sleep 2
    done
    echo "${c:-000}"
  }
  code=$(probe /)
  [ "$code" = "200" ] || die "回落站点返回 $code，预期 200。检查：nginx -t、ss -ltnp | grep 8443、journalctl -u xray -e"
  code=$(probe "/sub/$SUB_TOKEN/v2ray.txt")
  [ "$code" = "200" ] || die "订阅地址返回 $code，预期 200"
fi

# ---------- 8. 输出 ----------
{
  echo
  echo "============ 节点信息 ============"
  echo "地址:        $SERVER_IP:443"
  echo "UUID:        $UUID"
  echo "Public key:  $PUB"
  echo "Short ID:    $SID"
  echo "SNI:         $SNI"
  echo
  echo "------------ 分享链接（单个节点，可直接导入） ------------"
  printf '%s\n' "$LINKS"
  echo
  if [ -n "$DOMAIN" ]; then
    BASE="https://$DOMAIN/sub/$SUB_TOKEN"
    echo "------------ 订阅链接（客户端里「从 URL 导入」） ------------"
    echo "v2rayN / v2rayNG / Shadowrocket:   $BASE/v2ray.txt"
    echo "（只含节点，请在客户端把路由设为「绕过大陆」）"
    if [ "$CLASH" -eq 1 ]; then
      echo "Clash Verge / Clash Meta / Stash:  $BASE/clash.yaml"
      echo "（已含国内直连、广告拦截和自动回退规则）"
      echo "Clash Verge 一键导入：clash://install-config?url=$(printf '%s' "$BASE/clash.yaml" | sed 's#:#%3A#g; s#/#%2F#g')"
    fi
    echo
    echo "订阅地址等同于密码，不要公开；要作废就删掉 $SUB_DIR 并重跑脚本。"
  else
    echo "------------ 订阅文件（无域名，未对外提供） ------------"
    echo "$SUB_DIR/v2ray.txt    内容可直接粘贴到 v2rayN「从剪贴板导入」"
    if [ "$CLASH" -eq 1 ]; then
      echo "$SUB_DIR/clash.yaml   用 scp 下载后在 Clash Verge 里「导入本地文件」"
    fi
  fi
  if [ -n "$CDN_DOMAIN" ]; then
    echo
    echo "备用链路需在 Cloudflare 把 $CDN_DOMAIN 设为已代理，SSL/TLS 设为完整（严格）。"
  fi
  echo
  if [ "$CLASH" -eq 1 ]; then
    echo "------------ Clash 兼容模式说明 ------------"
    echo "已安装 Xray $CLASH_XRAY_VERSION 并放宽客户端版本限制，Clash 系客户端才能连接。"
    echo "Xray 官方提示放宽版本限制会增加服务器 IP 被识别的风险，能用 v2rayN / v2rayNG 的设备建议优先使用。"
    echo "在此期间不要用 Xray 官方安装命令升级，否则 Clash 会连不上。"
    echo "等 Clash 内核（mihomo）支持新版 Xray 后，去掉 --clash 重跑本脚本即可升级到最新版。"
  else
    echo "提示：新版 Xray 暂不支持 Clash 系客户端（Clash Verge / Clash Meta / Stash），本次未生成 Clash 订阅。"
    echo "推荐使用 v2rayN（Windows / macOS / Linux）或 v2rayNG（Android）；确实需要 Clash，可加 --clash 重跑。"
  fi
} | tee /root/xray-info.txt
chmod 600 /root/xray-info.txt

echo
echo "手机扫码导入主链路："
qrencode -t ansiutf8 "$LINK_R"
log "完成。以上信息已保存到 /root/xray-info.txt"
