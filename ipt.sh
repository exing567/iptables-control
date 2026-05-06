#!/usr/bin/env bash

set -u

APP_NAME="ipt-forward-manager"
VERSION="2.0"
DEFAULT_COMMENT_PREFIX="xjj-forward"
BACKUP_DIR="/root/iptables-backup"
CONF_DIR="/root/iptables-forward-conf"
LOG_FILE="/var/log/ipt-forward-manager.log"
SELF_PATH="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"
CYAN="\033[36m"
RESET="\033[0m"

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}请使用 root 运行：sudo bash $0${RESET}"
    exit 1
  fi
}

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"
}

pause() {
  echo
  read -rp "按 Enter 返回菜单..."
}

safe_mkdirs() {
  mkdir -p "$BACKUP_DIR" "$CONF_DIR"
}

timestamp() {
  date '+%Y%m%d-%H%M%S'
}

backup_rules() {
  safe_mkdirs
  local file="$BACKUP_DIR/iptables-$(timestamp).rules"
  iptables-save > "$file"
  echo -e "${GREEN}已备份当前规则：$file${RESET}"
  log "backup created: $file"
}

save_rules() {
  echo -e "${BLUE}保存 iptables 规则...${RESET}"

  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save
    echo -e "${GREEN}规则已通过 netfilter-persistent 保存。${RESET}"
    log "rules saved by netfilter-persistent"
  else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    echo -e "${GREEN}规则已保存到 /etc/iptables/rules.v4${RESET}"
    echo -e "${YELLOW}注意：如果未安装 iptables-persistent，重启后不一定自动加载。${RESET}"
    log "rules saved to /etc/iptables/rules.v4"
  fi
}

check_iptables() {
  echo -e "${BLUE}检查 iptables...${RESET}"

  if command -v iptables >/dev/null 2>&1; then
    echo -e "${GREEN}iptables 已安装：$(iptables --version)${RESET}"
  else
    echo -e "${RED}iptables 未安装。${RESET}"
    read -rp "是否现在安装 iptables 和 iptables-persistent？[y/N]: " yn
    case "$yn" in
      y|Y)
        apt update
        apt install -y iptables iptables-persistent netfilter-persistent
        ;;
      *)
        echo "已取消安装。"
        ;;
    esac
  fi

  if command -v iptables-save >/dev/null 2>&1; then
    echo -e "${GREEN}iptables-save 可用。${RESET}"
  else
    echo -e "${RED}iptables-save 不可用，请检查 iptables 安装。${RESET}"
  fi

  if command -v netfilter-persistent >/dev/null 2>&1; then
    echo -e "${GREEN}netfilter-persistent 已安装。${RESET}"
  else
    echo -e "${YELLOW}netfilter-persistent 未安装，保存规则时会写入 /etc/iptables/rules.v4。${RESET}"
  fi
}

check_sysctl() {
  echo -e "${BLUE}检查 IPv4 转发配置...${RESET}"

  mkdir -p /etc

  if [ ! -f /etc/sysctl.conf ]; then
    echo -e "${YELLOW}/etc/sysctl.conf 不存在，正在创建...${RESET}"
    touch /etc/sysctl.conf
  fi

  local current_runtime
  current_runtime="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  echo "当前运行状态 /proc/sys/net/ipv4/ip_forward = $current_runtime"

  if grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1\s*$' /etc/sysctl.conf; then
    echo -e "${GREEN}/etc/sysctl.conf 已正确配置 net.ipv4.ip_forward=1${RESET}"
  else
    echo -e "${YELLOW}/etc/sysctl.conf 未正确配置，正在修复...${RESET}"

    if grep -qE '^\s*#?\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
      sed -i 's/^\s*#\?\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi

    echo -e "${GREEN}已写入 net.ipv4.ip_forward=1${RESET}"
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward

  if command -v sysctl >/dev/null 2>&1; then
    sysctl -p /etc/sysctl.conf >/dev/null 2>&1 || true
  fi

  local after_runtime
  after_runtime="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"

  if [ "$after_runtime" = "1" ]; then
    echo -e "${GREEN}IPv4 转发已开启。${RESET}"
    log "ip_forward enabled"
  else
    echo -e "${RED}IPv4 转发可能未成功开启，请手动检查。${RESET}"
    log "ip_forward enable failed"
  fi
}

protocols_from_choice() {
  local choice="$1"
  case "$choice" in
    1|tcp|TCP) echo "tcp" ;;
    2|udp|UDP) echo "udp" ;;
    3|both|BOTH|all|ALL) echo "tcp udp" ;;
    *) echo "" ;;
  esac
}

ask_protocols() {
  echo >&2
  echo "请选择协议：" >&2
  echo "1) TCP" >&2
  echo "2) UDP" >&2
  echo "3) TCP + UDP" >&2
  read -rp "请选择 [默认 3]: " proto_choice >&2
  proto_choice="${proto_choice:-3}"

  local protocols
  protocols="$(protocols_from_choice "$proto_choice")"

  if [ -z "$protocols" ]; then
    echo -e "${RED}协议选择无效。${RESET}" >&2
    return 1
  fi

  echo "$protocols"
}

# Extract comment from iptables-save rule line, supports both quoted and unquoted
get_rule_comment() {
  local line="$1"
  echo "$line" | awk '{for (i=1;i<=NF;i++) if ($i=="--comment") {print $(i+1); exit}}' | tr -d '"'
}

# Generate grep pattern for comment, supports --comment sunny-use and --comment "sunny-use"
comment_grep_pattern() {
  local comment="$1"
  printf '%s' "--comment \"?${comment}\"?( |$)"
}

rule_exists_nat() {
  local chain="$1"
  shift
  iptables -t nat -C "$chain" "$@" >/dev/null 2>&1
}

rule_exists_filter() {
  local chain="$1"
  shift
  iptables -C "$chain" "$@" >/dev/null 2>&1
}

add_one_forward() {
  local in_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local comment="$5"

  if rule_exists_nat PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port"; then
    echo -e "${YELLOW}已存在：$proto PREROUTING $in_port -> $target_ip:$target_port${RESET}"
  else
    iptables -t nat -A PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "$comment" -j DNAT --to-destination "$target_ip:$target_port"
    echo -e "${GREEN}已添加：$proto PREROUTING $in_port -> $target_ip:$target_port${RESET}"
  fi

  if rule_exists_nat POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE; then
    echo -e "${YELLOW}已存在：$proto POSTROUTING MASQUERADE $target_ip:$target_port${RESET}"
  else
    iptables -t nat -A POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j MASQUERADE
    echo -e "${GREEN}已添加：$proto POSTROUTING MASQUERADE $target_ip:$target_port${RESET}"
  fi

  if rule_exists_filter FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT; then
    echo -e "${YELLOW}已存在：$proto FORWARD ACCEPT $target_ip:$target_port${RESET}"
  else
    iptables -A FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "$comment" -j ACCEPT
    echo -e "${GREEN}已添加：$proto FORWARD ACCEPT $target_ip:$target_port${RESET}"
  fi

  log "add forward proto=$proto in=$in_port target=$target_ip:$target_port comment=$comment"
}

delete_one_forward_exact() {
  local in_port="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"

  iptables -t nat -D PREROUTING -p "$proto" --dport "$in_port" -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -j ACCEPT 2>/dev/null || true

  iptables -t nat -D PREROUTING -p "$proto" --dport "$in_port" -m comment --comment "${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}" -j DNAT --to-destination "$target_ip:$target_port" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -p "$proto" -d "$target_ip" --dport "$target_port" -m comment --comment "${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}" -j ACCEPT 2>/dev/null || true
}

delete_by_comment_core() {
  local comment="$1"
  local pattern
  pattern="$(comment_grep_pattern "$comment")"

  while iptables-save | grep -E -- "$pattern" | grep -q "^-A FORWARD"; do
    local rule
    rule="$(iptables-save | grep -E -- "$pattern" | grep "^-A FORWARD" | head -n 1 | sed 's/^-A /-D /')"
    # shellcheck disable=SC2086
    iptables $rule
  done

  while iptables-save -t nat | grep -E -- "$pattern" | grep -q "^-A "; do
    local rule
    rule="$(iptables-save -t nat | grep -E -- "$pattern" | grep "^-A " | head -n 1 | sed 's/^-A /-D /')"
    # shellcheck disable=SC2086
    iptables -t nat $rule
  done

  log "delete by comment: $comment"
}

add_forward_interactive() {
  echo
  echo -e "${BLUE}添加单条端口转发。${RESET}"

  read -rp "入站端口，例如 8443: " in_port
  read -rp "目标 IP，例如 1.1.1.1: " target_ip
  read -rp "目标端口，例如 443: " target_port

  protocols="$(ask_protocols)" || return

  read -rp "备注，例如 xjj-forward-8443，留空自动生成: " comment

  if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}入站端口、目标 IP、目标端口不能为空。${RESET}"
    return
  fi

  if [ -z "$comment" ]; then
    comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"
  fi

  echo
  echo -e "${CYAN}即将添加：${RESET}"
  echo "入站端口: $in_port"
  echo "目标地址: $target_ip:$target_port"
  echo "协议: $protocols"
  echo "备注: $comment"
  echo

  read -rp "确认添加？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl
      for proto in $protocols; do
        add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

batch_add_forward() {
  echo
  echo -e "${BLUE}批量添加转发。格式：入站端口 目标IP 目标端口 协议 备注${RESET}"
  echo
  echo "协议支持：tcp / udp / both"
  echo
  echo "例如："
  echo "443 1.1.1.1 443 both xjj-forward-443"
  echo "8443 1.1.1.1 443 tcp xjj-forward-8443"
  echo
  echo "输入完成后，单独输入 END 结束。"
  echo

  local lines=()

  while true; do
    read -rp "> " line

    if [ "$line" = "END" ] || [ "$line" = "end" ]; then
      break
    fi

    [ -z "$line" ] && continue
    lines+=("$line")
  done

  if [ "${#lines[@]}" -eq 0 ]; then
    echo -e "${YELLOW}没有输入任何规则。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}解析到以下配置：${RESET}"
  printf "%-8s %-18s %-10s %-10s %-30s\n" "入站" "目标IP" "目标端口" "协议" "备注"
  printf "%-8s %-18s %-10s %-10s %-30s\n" "----" "------" "--------" "----" "----"

  for line in "${lines[@]}"; do
    in_port="$(echo "$line" | awk '{print $1}')"
    target_ip="$(echo "$line" | awk '{print $2}')"
    target_port="$(echo "$line" | awk '{print $3}')"
    proto_input="$(echo "$line" | awk '{print $4}')"
    comment="$(echo "$line" | awk '{print $5}')"

    [ -z "$proto_input" ] && proto_input="both"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

    printf "%-8s %-18s %-10s %-10s %-30s\n" "$in_port" "$target_ip" "$target_port" "$proto_input" "$comment"
  done

  echo
  read -rp "确认批量添加？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl

      for line in "${lines[@]}"; do
        in_port="$(echo "$line" | awk '{print $1}')"
        target_ip="$(echo "$line" | awk '{print $2}')"
        target_port="$(echo "$line" | awk '{print $3}')"
        proto_input="$(echo "$line" | awk '{print $4}')"
        comment="$(echo "$line" | awk '{print $5}')"

        if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
          echo -e "${RED}跳过格式错误：$line${RESET}"
          continue
        fi

        [ -z "$proto_input" ] && proto_input="both"
        [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

        protocols="$(protocols_from_choice "$proto_input")"

        if [ -z "$protocols" ]; then
          echo -e "${RED}跳过协议错误：$line${RESET}"
          continue
        fi

        for proto in $protocols; do
          add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
        done
      done

      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

delete_by_comment() {
  echo
  read -rp "请输入要删除的备注 comment，例如 xjj-forward-8443: " comment

  if [ -z "$comment" ]; then
    echo -e "${RED}备注不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}将删除以下规则：${RESET}"
  pattern="$(comment_grep_pattern "$comment")"
  iptables-save | grep -E -- "$pattern" || {
    echo -e "${YELLOW}没有找到该备注对应的规则。${RESET}"
    return
  }

  echo
  read -rp "确认删除？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      delete_by_comment_core "$comment"
      echo -e "${GREEN}删除完成。${RESET}"
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

batch_delete_by_comment() {
  echo
  echo -e "${BLUE}批量按备注删除。每行输入一个 comment，输入 END 结束。${RESET}"
  echo

  local comments=()

  while true; do
    read -rp "> " comment

    if [ "$comment" = "END" ] || [ "$comment" = "end" ]; then
      break
    fi

    [ -z "$comment" ] && continue
    comments+=("$comment")
  done

  if [ "${#comments[@]}" -eq 0 ]; then
    echo -e "${YELLOW}没有输入任何备注。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}将删除以下备注对应规则：${RESET}"
  for c in "${comments[@]}"; do
    echo "---- $c ----"
    pattern="$(comment_grep_pattern "$c")"
    iptables-save | grep -E -- "$pattern" || echo "未找到"
  done

  echo
  read -rp "确认批量删除？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      for c in "${comments[@]}"; do
        delete_by_comment_core "$c"
        echo -e "${GREEN}已删除：$c${RESET}"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

delete_by_exact_forward() {
  echo
  echo -e "${BLUE}按转发参数删除。${RESET}"

  read -rp "入站端口，例如 8443: " in_port
  read -rp "目标 IP，例如 1.1.1.1: " target_ip
  read -rp "目标端口，例如 443: " target_port

  protocols="$(ask_protocols)" || return

  if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}入站端口、目标 IP、目标端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}即将按参数删除：${RESET}"
  echo "$protocols $in_port -> $target_ip:$target_port"
  echo

  read -rp "确认删除？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      for proto in $protocols; do
        delete_one_forward_exact "$in_port" "$target_ip" "$target_port" "$proto"
      done
      echo -e "${GREEN}已尝试删除对应规则。${RESET}"
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

search_rules() {
  echo
  read -rp "请输入要搜索的端口/IP/备注关键词，例如 8443 或 1.1.1.1: " keyword

  if [ -z "$keyword" ]; then
    echo -e "${RED}关键词不能为空。${RESET}"
    return
  fi

  echo -e "${BLUE}搜索结果：${RESET}"
  iptables-save | grep -E "$keyword" || echo "没有找到相关规则。"
}

show_all_rules() {
  echo -e "${BLUE}NAT 表规则：${RESET}"
  iptables -t nat -L -n -v --line-numbers

  echo
  echo -e "${BLUE}FORWARD 表规则：${RESET}"
  iptables -L FORWARD -n -v --line-numbers

  echo
  echo -e "${BLUE}iptables-save 中的备注规则：${RESET}"
  iptables-save | grep -- '--comment' || echo "没有找到带备注的规则。"
}

show_comment_rules() {
  echo -e "${BLUE}当前带备注的规则：${RESET}"
  iptables-save | grep -- '--comment' || echo "没有带备注的规则。"
}

show_summary() {
  echo -e "${BLUE}转发规则摘要：${RESET}"
  echo

  local tmp
  tmp="$(mktemp)"

  iptables-save -t nat | grep "^-A PREROUTING" | grep "DNAT" | while read -r line; do
    proto="$(echo "$line" | grep -oE -- '-p (tcp|udp)' | awk '{print $2}')"
    in_port="$(echo "$line" | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | head -n 1)"
    target="$(echo "$line" | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}')"
    comment="$(get_rule_comment "$line")"
    [ -z "$comment" ] && comment="-"
    echo "$comment|$proto|$in_port|$target" >> "$tmp"
  done

  if [ ! -s "$tmp" ]; then
    echo "没有找到 DNAT 转发规则。"
    rm -f "$tmp"
    return
  fi

  printf "%-30s %-8s %-12s %-25s\n" "备注" "协议" "入站端口" "目标"
  printf "%-30s %-8s %-12s %-25s\n" "----" "----" "--------" "----"

  sort "$tmp" | while IFS='|' read -r comment proto in_port target; do
    printf "%-30s %-8s %-12s %-25s\n" "$comment" "$proto" "$in_port" "$target"
  done

  rm -f "$tmp"
}

export_conf() {
  safe_mkdirs

  local default_file="$CONF_DIR/forwards-$(timestamp).conf"
  read -rp "请输入导出文件路径 [默认 $default_file]: " out_file
  out_file="${out_file:-$default_file}"

  echo "# iptables forward config exported by $APP_NAME $VERSION" > "$out_file"
  echo "# format: in_port target_ip target_port protocol comment" >> "$out_file"
  echo "# protocol: tcp / udp / both" >> "$out_file"
  echo >> "$out_file"

  local tmp
  tmp="$(mktemp)"

  iptables-save -t nat | grep "^-A PREROUTING" | grep "DNAT" | while read -r line; do
    proto="$(echo "$line" | grep -oE -- '-p (tcp|udp)' | awk '{print $2}')"
    in_port="$(echo "$line" | grep -oE -- '--dport [0-9]+' | awk '{print $2}' | head -n 1)"
    target="$(echo "$line" | grep -oE -- '--to-destination [^ ]+' | awk '{print $2}')"
    target_ip="${target%:*}"
    target_port="${target##*:}"
    comment="$(get_rule_comment "$line")"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"
    echo "$in_port $target_ip $target_port $proto $comment" >> "$tmp"
  done

  if [ ! -s "$tmp" ]; then
    echo -e "${YELLOW}没有可导出的 DNAT 转发规则。${RESET}"
    rm -f "$tmp"
    return
  fi

  # 简单导出，不强行合并 tcp/udp 为 both，避免误判。
  sort "$tmp" >> "$out_file"
  rm -f "$tmp"

  echo -e "${GREEN}已导出配置文件：$out_file${RESET}"
  log "config exported: $out_file"
}

parse_conf_preview() {
  local file="$1"
  local valid_count=0
  local invalid_count=0

  echo
  echo -e "${CYAN}解析到以下配置：${RESET}"
  printf "%-6s %-8s %-18s %-10s %-10s %-30s\n" "行号" "入站" "目标IP" "目标端口" "协议" "备注"
  printf "%-6s %-8s %-18s %-10s %-10s %-30s\n" "----" "----" "------" "--------" "----" "----"

  local line_no=0

  while IFS= read -r line || [ -n "$line" ]; do
    line_no=$((line_no + 1))

    line="$(echo "$line" | sed 's/#.*$//' | xargs)"
    [ -z "$line" ] && continue

    in_port="$(echo "$line" | awk '{print $1}')"
    target_ip="$(echo "$line" | awk '{print $2}')"
    target_port="$(echo "$line" | awk '{print $3}')"
    proto_input="$(echo "$line" | awk '{print $4}')"
    comment="$(echo "$line" | awk '{print $5}')"

    if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
      echo -e "${RED}第 $line_no 行格式错误：$line${RESET}"
      invalid_count=$((invalid_count + 1))
      continue
    fi

    [ -z "$proto_input" ] && proto_input="both"
    [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

    if [ -z "$(protocols_from_choice "$proto_input")" ]; then
      echo -e "${RED}第 $line_no 行协议错误：$line${RESET}"
      invalid_count=$((invalid_count + 1))
      continue
    fi

    printf "%-6s %-8s %-18s %-10s %-10s %-30s\n" "$line_no" "$in_port" "$target_ip" "$target_port" "$proto_input" "$comment"
    valid_count=$((valid_count + 1))
  done < "$file"

  echo
  echo "有效规则：$valid_count"
  echo "错误规则：$invalid_count"

  if [ "$valid_count" -eq 0 ]; then
    return 1
  fi

  return 0
}

import_conf() {
  echo
  read -rp "请输入 .conf 文件路径: " file

  if [ -z "$file" ]; then
    echo -e "${RED}文件路径不能为空。${RESET}"
    return
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}文件不存在：$file${RESET}"
    return
  fi

  parse_conf_preview "$file" || {
    echo -e "${RED}没有可导入的有效规则。${RESET}"
    return
  }

  echo
  read -rp "确认导入以上规则？[y/N]: " yn
  case "$yn" in
    y|Y)
      backup_rules
      check_sysctl

      local line_no=0

      while IFS= read -r line || [ -n "$line" ]; do
        line_no=$((line_no + 1))

        line="$(echo "$line" | sed 's/#.*$//' | xargs)"
        [ -z "$line" ] && continue

        in_port="$(echo "$line" | awk '{print $1}')"
        target_ip="$(echo "$line" | awk '{print $2}')"
        target_port="$(echo "$line" | awk '{print $3}')"
        proto_input="$(echo "$line" | awk '{print $4}')"
        comment="$(echo "$line" | awk '{print $5}')"

        if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
          echo -e "${RED}跳过第 $line_no 行：格式错误${RESET}"
          continue
        fi

        [ -z "$proto_input" ] && proto_input="both"
        [ -z "$comment" ] && comment="${DEFAULT_COMMENT_PREFIX}-${in_port}-to-${target_ip}-${target_port}"

        protocols="$(protocols_from_choice "$proto_input")"

        if [ -z "$protocols" ]; then
          echo -e "${RED}跳过第 $line_no 行：协议错误${RESET}"
          continue
        fi

        for proto in $protocols; do
          add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$comment"
        done
      done < "$file"

      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

list_backups() {
  safe_mkdirs
  echo -e "${BLUE}备份文件列表：${RESET}"
  ls -lh "$BACKUP_DIR"/*.rules 2>/dev/null || echo "没有找到备份文件。"
}

restore_backup() {
  safe_mkdirs
  list_backups
  echo
  read -rp "请输入要回滚的备份文件完整路径: " file

  if [ -z "$file" ]; then
    echo -e "${RED}路径不能为空。${RESET}"
    return
  fi

  if [ ! -f "$file" ]; then
    echo -e "${RED}备份文件不存在：$file${RESET}"
    return
  fi

  echo
  echo -e "${YELLOW}警告：这会用备份覆盖当前 iptables 规则。${RESET}"
  read -rp "确认回滚？[y/N]: " yn

  case "$yn" in
    y|Y)
      backup_rules
      iptables-restore < "$file"
      save_rules
      echo -e "${GREEN}已回滚到：$file${RESET}"
      log "restore backup: $file"
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

test_target() {
  echo
  read -rp "目标 IP，例如 1.1.1.1: " target_ip
  read -rp "目标端口，例如 443: " target_port

  if [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}目标 IP 和端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${BLUE}测试 TCP 连接：$target_ip:$target_port${RESET}"

  if command -v nc >/dev/null 2>&1; then
    nc -vz -w 3 "$target_ip" "$target_port"
  elif command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/$target_ip/$target_port" >/dev/null 2>&1 \
      && echo -e "${GREEN}TCP 可连接。${RESET}" \
      || echo -e "${RED}TCP 不可连接或超时。${RESET}"
  else
    echo -e "${YELLOW}没有 nc/timeout，无法测试。可以安装：apt install netcat-openbsd -y${RESET}"
  fi

  echo
  echo -e "${YELLOW}UDP 无法像 TCP 一样可靠判断是否打开；这里只能说明包是否能发出，不能证明服务可用。${RESET}"
}

test_forward_hit() {
  echo
  read -rp "请输入要查看命中的入站端口，例如 8443: " port

  if [ -z "$port" ]; then
    echo -e "${RED}端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${BLUE}NAT PREROUTING 命中情况：${RESET}"
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E "dpt:$port|Chain|num" || echo "没有找到相关 PREROUTING 规则。"

  echo
  echo -e "${BLUE}FORWARD 命中情况：${RESET}"
  iptables -L FORWARD -n -v --line-numbers | grep -E "dpt:|Chain|num" || true

  echo
  echo -e "${YELLOW}提示：如果 packets/bytes 数字增加，说明流量命中了规则。${RESET}"
}

modify_rule() {
  echo
  echo -e "${BLUE}修改规则：建议通过旧备注删除，再添加新规则。${RESET}"
  echo

  read -rp "请输入旧规则备注 comment，例如 xjj-forward-8443: " old_comment

  if [ -z "$old_comment" ]; then
    echo -e "${RED}旧备注不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}旧规则：${RESET}"
  pattern="$(comment_grep_pattern "$old_comment")"
  iptables-save | grep -E -- "$pattern" || {
    echo -e "${RED}没有找到旧备注对应规则。${RESET}"
    return
  }

  echo
  read -rp "新入站端口: " in_port
  read -rp "新目标 IP: " target_ip
  read -rp "新目标端口: " target_port
  protocols="$(ask_protocols)" || return
  read -rp "新备注，留空继续使用旧备注: " new_comment

  [ -z "$new_comment" ] && new_comment="$old_comment"

  if [ -z "$in_port" ] || [ -z "$target_ip" ] || [ -z "$target_port" ]; then
    echo -e "${RED}新入站端口、目标 IP、目标端口不能为空。${RESET}"
    return
  fi

  echo
  echo -e "${CYAN}即将执行修改：${RESET}"
  echo "删除旧备注：$old_comment"
  echo "添加新规则：$protocols $in_port -> $target_ip:$target_port comment=$new_comment"
  echo

  read -rp "确认修改？[y/N]: " yn

  case "$yn" in
    y|Y)
      backup_rules
      delete_by_comment_core "$old_comment"
      check_sysctl
      for proto in $protocols; do
        add_one_forward "$in_port" "$target_ip" "$target_port" "$proto" "$new_comment"
      done
      save_rules
      ;;
    *)
      echo "已取消。"
      ;;
  esac
}

install_self_check_service() {
  echo
  echo -e "${BLUE}安装开机自检 systemd 服务...${RESET}"

  if [ ! -f "$SELF_PATH" ]; then
    echo -e "${RED}无法定位当前脚本路径：$SELF_PATH${RESET}"
    return
  fi

  cat > /etc/systemd/system/ipt-forward-selfcheck.service <<EOF
[Unit]
Description=iptables forward manager self check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $SELF_PATH --self-check
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable ipt-forward-selfcheck.service

  echo -e "${GREEN}已安装并启用 ipt-forward-selfcheck.service${RESET}"
  echo "查看日志：cat $LOG_FILE"
  log "self-check service installed"
}

uninstall_self_check_service() {
  echo -e "${BLUE}卸载开机自检 systemd 服务...${RESET}"

  systemctl disable ipt-forward-selfcheck.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/ipt-forward-selfcheck.service
  systemctl daemon-reload

  echo -e "${GREEN}已卸载。${RESET}"
  log "self-check service uninstalled"
}

self_check() {
  log "self-check start"

  if command -v iptables >/dev/null 2>&1; then
    log "iptables ok: $(iptables --version)"
  else
    log "iptables missing"
  fi

  local ipf
  ipf="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
  log "runtime ip_forward=$ipf"

  if [ "$ipf" != "1" ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
    log "attempted to enable runtime ip_forward"
  fi

  local count
  count="$(iptables-save -t nat 2>/dev/null | grep -c "DNAT" || echo 0)"
  log "dnat rule count=$count"

  log "self-check end"
}

view_log() {
  echo -e "${BLUE}日志：$LOG_FILE${RESET}"
  if [ -f "$LOG_FILE" ]; then
    tail -n 100 "$LOG_FILE"
  else
    echo "暂无日志。"
  fi
}

menu() {
  clear
  echo "=================================================="
  echo " $APP_NAME v$VERSION"
  echo "=================================================="
  echo " 基础检查"
  echo "  1) 检查 iptables 是否安装"
  echo "  2) 检查/修复 IPv4 转发 sysctl"
  echo
  echo " 规则查看"
  echo "  3) 查看规则摘要表"
  echo "  4) 查看全部 NAT / FORWARD 规则"
  echo "  5) 搜索旧规则，包括端口/IP/备注"
  echo "  6) 只显示带备注的规则"
  echo "  7) 查看某端口规则命中次数"
  echo
  echo " 添加/删除/修改"
  echo "  8) 添加单条转发"
  echo "  9) 批量添加转发"
  echo " 10) 按备注删除规则"
  echo " 11) 批量按备注删除规则"
  echo " 12) 按入站端口 + 目标 IP + 目标端口删除"
  echo " 13) 修改已有规则"
  echo
  echo " 配置导入导出"
  echo " 14) 导出当前转发为 .conf"
  echo " 15) 从 .conf 导入转发，导入前预览"
  echo
  echo " 备份/回滚/测试"
  echo " 16) 备份当前 iptables 规则"
  echo " 17) 查看备份列表"
  echo " 18) 从备份回滚"
  echo " 19) 测试目标端口 TCP 可达性"
  echo " 20) 保存当前规则"
  echo
  echo " 开机自检/日志"
  echo " 21) 安装开机自检服务"
  echo " 22) 卸载开机自检服务"
  echo " 23) 查看脚本日志"
  echo
  echo "  0) 退出"
  echo "=================================================="
}

main() {
  if [ "${1:-}" = "--self-check" ]; then
    self_check
    exit 0
  fi

  need_root
  safe_mkdirs

  while true; do
    menu
    read -rp "请选择: " choice

    case "$choice" in
      1) check_iptables; pause ;;
      2) check_sysctl; pause ;;
      3) show_summary; pause ;;
      4) show_all_rules; pause ;;
      5) search_rules; pause ;;
      6) show_comment_rules; pause ;;
      7) test_forward_hit; pause ;;
      8) add_forward_interactive; pause ;;
      9) batch_add_forward; pause ;;
      10) delete_by_comment; pause ;;
      11) batch_delete_by_comment; pause ;;
      12) delete_by_exact_forward; pause ;;
      13) modify_rule; pause ;;
      14) export_conf; pause ;;
      15) import_conf; pause ;;
      16) backup_rules; pause ;;
      17) list_backups; pause ;;
      18) restore_backup; pause ;;
      19) test_target; pause ;;
      20) save_rules; pause ;;
      21) install_self_check_service; pause ;;
      22) uninstall_self_check_service; pause ;;
      23) view_log; pause ;;
      0) exit 0 ;;
      *) echo -e "${RED}无效选择。${RESET}"; pause ;;
    esac
  done
}

main "$@"