#!/bin/bash
# ============================================================
# onekey-vps_dns — 海外 VPS DNS 转发服务一键安装/卸载
# 适用环境: Debian / Ubuntu (VPS, tailnet 成员, root)
# 功能: 部署 dnsmasq 监听本机 tailnet IP(100.x):53, 转发公共 DNS
#       ——作为 PVE mosdns_oci 的远程 DNS 上游(替代 daed 劫持链路)
# 用法: bash onekey-vps_dns.sh
# 说明: 监听 IP 自动取本机 tailscale IP, 无需交互输入
#       (三台 VPS 跑同一脚本, 各自监听自己的 100.x)
# ============================================================
set -e

# ---------- 配置 ----------
CONF_FILE="/etc/dnsmasq.d/exit-dns.conf"
UPSTREAMS="8.8.8.8 1.1.1.1 8.8.4.4 1.0.0.1"
SVC="dnsmasq"

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测已安装 ----------
is_installed() {
  dpkg -l dnsmasq 2>/dev/null | grep -q "^ii"
}

# ---------- 取本机 tailnet IPv4 ----------
get_tailscale_ip() {
  local ip
  ip=$(tailscale ip -4 2>/dev/null | head -1)
  [ -n "$ip" ] || return 1
  echo "$ip"
}

# ---------- 环境预检 ----------
precheck() {
  echo ""
  echo "========== 环境预检 =========="
  local PASS=0 FAIL=0

  # 1. root
  if [ "$(id -u)" -eq 0 ]; then
    echo -e "  [1/5] root 权限 ........... ${GREEN}✅${NC}"; PASS=$((PASS+1))
  else
    echo -e "  [1/5] root 权限 ........... ${RED}❌ 请以 root 运行${NC}"; FAIL=$((FAIL+1))
  fi

  # 2. 系统 Debian/Ubuntu
  if [ -f /etc/debian_version ] || grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    echo -e "  [2/5] 系统发行版 ......... ${GREEN}✅${NC}"; PASS=$((PASS+1))
  else
    echo -e "  [2/5] 系统发行版 ......... ${RED}❌ 仅支持 Debian/Ubuntu${NC}"; FAIL=$((FAIL+1))
  fi

  # 3. tailscale 已安装
  if command -v tailscale >/dev/null 2>&1; then
    echo -e "  [3/5] tailscale .......... ${GREEN}✅${NC}"; PASS=$((PASS+1))
  else
    echo -e "  [3/5] tailscale .......... ${RED}❌ 未安装 (apt install tailscale)${NC}"; FAIL=$((FAIL+1))
  fi

  # 4. tailnet IP 可获取且非 MagicDNS
  local tip=""
  tip=$(get_tailscale_ip || true)
  if [ -n "$tip" ] && [ "$tip" != "100.100.100.100" ]; then
    echo -e "  [4/5] tailnet IP ......... ${GREEN}✅ ${tip}${NC}"; PASS=$((PASS+1))
  else
    echo -e "  [4/5] tailnet IP ......... ${RED}❌ 未在 tailnet / tailscale up 未完成${NC}"; FAIL=$((FAIL+1))
  fi

  # 5. 目标 IP:53 未被占用(dnsmasq 自身占用视为已装, 通过)
  if is_installed; then
    echo -e "  [5/5] :53 端口 ........... ${YELLOW}⏭ dnsmasq 已装(升级/重配模式)${NC}"; PASS=$((PASS+1))
  else
    local holder
    holder=$(ss -ulnp 2>/dev/null | grep -E "$(get_tailscale_ip 2>/dev/null):53\b" | grep -oP 'users:\(\("\K[^"]+' | head -1 || true)
    if [ -z "$holder" ]; then
      echo -e "  [5/5] 100.x:53 端口 ...... ${GREEN}✅ 空闲${NC}"; PASS=$((PASS+1))
    else
      echo -e "  [5/5] 100.x:53 端口 ...... ${RED}❌ 被 ${holder} 占用${NC}"; FAIL=$((FAIL+1))
    fi
  fi

  echo ""
  if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}  ✅ 环境检查通过 (${PASS}/${PASS})${NC}"
    return 0
  else
    echo -e "${RED}  ❌ 环境检查未通过 (${FAIL} 项失败), 请修复后重试${NC}"
    return 1
  fi
}

# ---------- 安装/升级 ----------
do_install() {
  local tip
  tip=$(get_tailscale_ip) || err "无法获取 tailnet IP, 请确认 tailscale 已登录"

  echo ""
  info "=== 1/4 安装 dnsmasq ==="
  if is_installed; then
    info "  dnsmasq 已安装, 跳过 (重配模式)"
  else
    apt-get update -qq 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y dnsmasq 2>&1 | tail -1
    # apt postinst 会用默认配置自动启动 dnsmasq——立即停掉,
    # 避免旧实例占用 :53 导致稍后 restart 竞态失败 (Address already in use)
    systemctl stop dnsmasq 2>/dev/null || true
    sleep 1
  fi

  info "=== 2/4 写入配置 (监听 ${tip}:53) ==="
  cat > "$CONF_FILE" << CONF
# onekey-vps_dns 生成 (安装日期: $(date +%Y-%m-%d))
# 回滚: rm $CONF_FILE && apt-get purge -y dnsmasq dnsmasq-base
port=53
listen-address=127.0.0.1,${tip}
# bind-dynamic: 开机时 tailscale IP 往往晚于 dnsmasq 就绪。bind-interfaces 在地址不存在时
#   直接退出(failed to create listening socket ... Cannot assign requested address),
#   bind-dynamic 语义相同(只绑上面列出的地址)但会等地址出现并自动跟踪接口变化 (2026-09-10 实测)
bind-dynamic
no-resolv
no-poll
no-hosts
no-dhcp-interface=*
# 并发查全部上游, 取先返回者(默认只挑一个, 故障切换有延迟)
all-servers
CONF
  for u in $UPSTREAMS; do
    echo "server=$u" >> "$CONF_FILE"
  done
  info "  ✓ ${CONF_FILE}"

  info "=== 3/4 重启服务 ==="
  systemctl enable dnsmasq >/dev/null 2>&1 || true
  systemctl restart dnsmasq

  info "=== 4/4 验证 ==="
  # 轮询等监听出现(最长 10 秒)——restart 后 systemd 可能需 1-2 秒拉起,
  # 单次 sleep 1 检查会误报失败
  local ok=0
  for i in $(seq 1 10); do
    if ss -ulnp 2>/dev/null | grep -q "${tip}:53\b"; then
      ok=1
      break
    fi
    sleep 1
  done
  if [ "$ok" -eq 1 ]; then
    info "  ✓ 监听确认: ${tip}:53"
  else
    err "监听失败: ${tip}:53 未出现 (journalctl -u dnsmasq 查看原因)"
  fi
  if command -v python3 >/dev/null 2>&1; then
    local ans
    ans=$(python3 - "$tip" << 'PYEOF' 2>/dev/null || true
import socket, struct, random, sys
def q(domain):
    tid = random.randint(0, 0xffff)
    h = struct.pack('>HHHHHH', tid, 0x0100, 1, 0, 0, 0)
    qn = b''.join(bytes([len(p)]) + p.encode() for p in domain.split('.')) + b'\x00'
    return h + qn + struct.pack('>HH', 1, 1)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(6)
s.sendto(q('google.com'), (sys.argv[1], 53))
try:
    d, _ = s.recvfrom(4096)
    an = struct.unpack('>H', d[6:8])[0]
    print(an)
except Exception:
    print(0)
finally:
    s.close()
PYEOF
)
    if [ -n "$ans" ] && [ "$ans" -gt 0 ]; then
      info "  ✓ DNS 解析验证: google.com 返回 ${ans} 条 (经 ${tip}:53 → 公共 DNS)"
    else
      err "DNS 解析验证失败: ${tip}:53 无应答"
    fi
  else
    warn "  未找到 python3, 跳过解析验证 (手动: nslookup google.com ${tip})"
  fi

  echo ""
  info "========== 安装完成 =========="
  info "  监听地址 : ${tip}:53 (udp/tcp, 仅 tailnet + 回环)"
  info "  上游转发 : ${UPSTREAMS}"
  info "  服务管理 : systemctl {status|restart} dnsmasq"
  info "  供谁使用 : PVE mosdns_oci 的 remote upstream 填 udp://${tip}"
  info "  卸载回滚 : bash onekey-vps_dns.sh → 选 2"
}

# ---------- 卸载 ----------
do_uninstall() {
  echo ""
  info "=== 1/3 停止并禁用服务 ==="
  systemctl stop dnsmasq 2>/dev/null || true
  systemctl disable dnsmasq 2>/dev/null || true

  info "=== 2/3 删除配置 ==="
  rm -f "$CONF_FILE"
  info "  ✓ ${CONF_FILE}"

  info "=== 3/3 卸载软件包 ==="
  DEBIAN_FRONTEND=noninteractive apt-get purge -y dnsmasq dnsmasq-base 2>&1 | tail -1

  echo ""
  if dpkg -l dnsmasq 2>/dev/null | grep -q "^ii"; then
    err "卸载未完成, dnsmasq 仍存在"
  fi
  info "========== 卸载完成 =========="
  info "  dnsmasq 已完全清除 (含配置目录), 系统回到安装前状态"
}

# ---------- 主菜单 ----------
menu() {
  while true; do
    echo ""
    echo "========================================"
    echo "  onekey-vps_dns — VPS DNS 转发服务"
    echo "========================================"
    if is_installed; then
      local tip
      tip=$(get_tailscale_ip 2>/dev/null || echo "?")
      echo -e "[INFO] dnsmasq 已安装 (监听 ${tip:-未知}:53)"
    else
      echo "[INFO] dnsmasq 未安装"
    fi
    echo ""
    echo "请选择操作:"
    echo "  1. 安装 / 升级 dnsmasq"
    echo "  2. 卸载 dnsmasq"
    echo "  0. 退出"
    read -p "请输入 [0-2]: " choice </dev/tty
    case "$choice" in
      1) precheck && do_install ;;
      2) if is_installed; then do_uninstall; else warn "dnsmasq 未安装"; fi ;;
      0) info "已退出"; exit 0 ;;
      *) warn "无效选项: $choice" ;;
    esac
  done
}

menu
