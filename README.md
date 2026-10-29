# xray-reality-install

Xray VLESS + Reality + Vision 一键部署脚本。部署完成后输出 Clash / v2rayN / Shadowrocket 等客户端的订阅链接和二维码。

完整原理与手动配置步骤见教程：<https://blog.roc.plus/posts/xray-reality-selfhost/>

## 用法

在一台干净的 Debian 12 / Ubuntu 22.04 / 24.04 服务器上，以 root 运行。

有域名（推荐，self-steal + HTTPS 订阅，可选 Cloudflare CDN 备用链路）：

```bash
bash <(curl -fsSL https://roc-shen.github.io/xray-reality-install/install.sh) \
  --domain www.example.com --cdn-domain cdn.example.com
```

无域名（借用第三方站点，只输出分享链接、二维码和本地订阅文件）：

```bash
bash <(curl -fsSL https://roc-shen.github.io/xray-reality-install/install.sh)
```

| 参数 | 说明 |
| --- | --- |
| `--domain` | 回落站点域名，需已解析到本机（Cloudflare 灰色云朵） |
| `--cdn-domain` | 可选，CDN 备用链路域名（Cloudflare 橙色云朵） |
| `--email` | 可选，Let's Encrypt 到期提醒邮箱 |
| `--target` | 无域名模式借用的站点，默认 `www.microsoft.com` |
| `--force` | 443 已被占用时仍继续 |

脚本会占用 443 端口，并改写 Nginx 配置。已有网站的服务器请先阅读教程，不要直接运行。

## 免责声明

本脚本仅用于技术学习与研究。请遵守所在地法律法规和服务商条款，风险自负。
