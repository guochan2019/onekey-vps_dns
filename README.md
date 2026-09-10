# onekey-vps_dns — 海外 VPS DNS 转发服务

在 tailnet 成员 VPS 上部署 dnsmasq,监听本机 tailnet IP(100.x):53,转发公共 DNS(8.8.8.8/1.1.1.1)——作为 PVE mosdns_oci 的**远程 DNS 上游**,替代 daed eBPF 劫持链路。

## 一键安装

```bash
bash <(wget -qO- https://raw.githubusercontent.com/guochan2019/onekey-vps_dns/main/onekey-vps_dns.sh)
```

或下载后运行:`bash onekey-vps_dns.sh`

## 原理

```
改前: CT104 mosdns → tls://1.1.1.1:853 →(被墙)→ daed 劫持 → 节点代理 → 出网
改后: CT104 mosdns → udp://100.x:53 →(tailnet 加密)→ VPS dnsmasq → 8.8.8.8 出网
```

- **监听 IP 自动获取**(`tailscale ip -4`),无需交互输入——三台 VPS 跑同一脚本,各自监听自己的 100.x
- 仅绑定 tailnet IP + 回环(`bind-dynamic`),**不暴露公网**,无开放递归风险——语义同 `bind-interfaces`,但容忍开机时 tailscale IP 晚就绪(见"已知坑 3")
- tailnet WireGuard 全程加密,明文 DNS 在内等效安全
- 上游 3 家厂商(全部无拦截):`9.9.9.10`(Quad9) / `1.1.1.1`(Cloudflare) / `8.8.8.8`(Google)——按 2026-09-10 三台 VPS 实测延迟排序(1-2 / 2-5 / 6-7ms),VPS 海外直连无墙
- **`all-servers` 并发**:全部上游同查,取先返回者(2026-09-06 用户决策;默认 dnsmasq 只挑一个用,故障切换有延迟)
- ⚠ 上游必须**同为无拦截**(或同为拦截):`all-servers` 抢答下混用会让同一域名结果随机(拦截方先回 = NXDOMAIN)。Quad9 三组地址官方要求不混用(`9.9.9.10` 无拦截;`9.9.9.9`/`9.9.9.11` 带恶意域名拦截)

## 实机验证(2026-09-06)

三台 VPS(新加坡/东京/西雅图)+ PVE CT104(mosdns)全链路实测通过:

```
PVE 侧: CT104 netstat → 100.123.219.68:53 / 100.98.74.89:53 / 100.115.251.80:53 三条 ESTABLISHED
DNS 三连: baidu answers=3 ✓ / google answers=8 ✓ / doubleclick NXDOMAIN ✓ (daed 零参与)
```

## 已知坑(脚本已修复,2026-09-06 / 2026-09-10)

1. **Debian dnsmasq postinst 自动启动**:`apt install dnsmasq` 后 postinst 会用默认配置自动 start,与脚本后续 `restart` 竞态 → `Address already in use` 首次失败。修复:安装后立即 `systemctl stop` + sleep 1,再写配置 + restart。
2. **验证 grep 模式**:`grep "[:.]<ip>:53"` 的 `[:.]` 前缀要求 IP 前是冒号/点,但 `ss` 输出 IP 前是空格 → 永匹配失败,误报"监听失败"。修复:去掉前缀,用 `grep "<ip>:53\b"`(预检占用检测 + 安装后验证两处同修)。
3. **🔴 开机竞态:重启后 dnsmasq 起不来(2026-09-10 实测,已修)**:`bind-interfaces` 下 VPS 重启 → dnsmasq 先于 tailscaled 给 `tailscale0` 挂 100.x → `failed to create listening socket for 100.x: Cannot assign requested address` → FAILED。服务 `enabled` ⇒ **每次开机必现**,而手动 `systemctl restart dnsmasq` 又正常 → 极易误判为偶发。**修复**:配置改 `bind-dynamic`——语义同(只绑 `listen-address` 列出的地址,不暴露公网),但会等地址出现、自动跟踪接口变化。**已装机器一次性修**:`sed -i 's/^bind-interfaces$/bind-dynamic/' /etc/dnsmasq.d/exit-dns.conf && systemctl restart dnsmasq`。⚠ 当场 restart 不复现竞态,**须真实重启验证**。

## 使用

| 操作 | 说明 |
|------|------|
| 菜单 1 | 安装/升级(dnsmasq 已装则跳过安装,仅重配) |
| 菜单 2 | 卸载:停服 → 删配置 → purge 双包,完全还原 |
| 菜单 0 | 退出 |

部署后在 PVE 侧:mosdns_oci 的 remote upstream 填 `udp://<各 VPS tailnet IP>`(三台上游并发,一台挂另两台顶)。

## 预检 5 项

root / Debian-Ubuntu / tailscale 已装 / tailnet IP 可获取(非 MagicDNS)/ 100.x:53 空闲(已装则跳过)

## 验证命令

```bash
ss -ulnp | grep :53                          # 100.x:53 监听确认
nslookup google.com <VPS-tailnet-IP>          # 本机解析测试
```

## 回滚

```bash
# 卸载(菜单 2 等价)
systemctl stop dnsmasq; systemctl disable dnsmasq
rm /etc/dnsmasq.d/exit-dns.conf
apt-get purge -y dnsmasq dnsmasq-base
```
