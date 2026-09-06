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
- 仅绑定 tailnet IP + 回环(`bind-interfaces`),**不暴露公网**,无开放递归风险
- tailnet WireGuard 全程加密,明文 DNS 在内等效安全
- 上游固定 8.8.8.8/1.1.1.1/8.8.4.4/1.0.0.1(VPS 海外直连无墙)

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
