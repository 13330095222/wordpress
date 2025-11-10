#!/usr/bin/env bash
# swapon.sh - 创建并启用 2G swapfile，持久化到 /etc/fstab，并设置 vm.swappiness=10
# 用法：
#   sudo bash swapon.sh
# 脚本特性：
# - 幂等：如果 /swapfile 已启用则不会重复创建（仍会确保 swappiness 设置）
# - 如果 /swapfile 存在但大小不同，则不会覆盖，避免意外删除数据
# - 支持 fallocate（优先）和 dd（回退）来创建 swapfile
set -euo pipefail

SWAPFILE="/swapfile"
SWAPSIZE="2G"
SWAP_BYTES=$((2 * 1024 * 1024 * 1024))
FSTAB="/etc/fstab"
SYSCTL_CONF="/etc/sysctl.d/99-swappiness.conf"
SWAPPINESS=10

info(){ printf "\e[32m[INFO]\e[0m %s\n" "$*"; }
warn(){ printf "\e[33m[WARN]\e[0m %s\n" "$*"; }
err(){ printf "\e[31m[ERROR]\e[0m %s\n" "$*"; exit 1; }

# 必须以 root 运行
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 身份运行：sudo bash $0"
fi

info "当前 swap 使用情况："
swapon --show || true

# 检查是否已启用 /swapfile
if swapon --show --noheadings --raw | awk '{print $1}' | grep -q "^${SWAPFILE}$"; then
  info "${SWAPFILE} 已启用（active）。跳过创建。"
else
  if [ -f "${SWAPFILE}" ]; then
    existing_size=$(stat -c%s "${SWAPFILE}")
    if [ "${existing_size}" -ne "${SWAP_BYTES}" ]; then
      warn "${SWAPFILE} 已存在，但大小非 ${SWAPSIZE}（${existing_size} bytes）。为避免数据丢失脚本不会覆盖它。"
      warn "如需重新创建，请手动删除 ${SWAPFILE} 并重新运行脚本：sudo rm -f ${SWAPFILE}"
      # 仍尝试启用（如果不是 mkswap 则继续）
      if file "${SWAPFILE}" | grep -qi swap; then
        info "${SWAPFILE} 看起来像 swap，尝试启用..."
        mkswap "${SWAPFILE}" || true
        swapon "${SWAPFILE}" || true
      fi
    else
      info "${SWAPFILE} 已存在且大小为 ${SWAPSIZE}，尝试设置权限并启用..."
      chmod 600 "${SWAPFILE}"
      if ! file "${SWAPFILE}" | grep -qi swap; then
        mkswap "${SWAPFILE}"
      fi
      swapon "${SWAPFILE}"
    fi
  else
    info "将创建 ${SWAPFILE} 大小 ${SWAPSIZE}，请稍候..."
    # 检查可用空间（在 / 有足够空间）
    avail_bytes=$(df --output=avail / | tail -1)
    avail_bytes=$((avail_bytes * 1024))
    if [ "${avail_bytes}" -lt "${SWAP_BYTES}" ]; then
      warn "根分区可用空间不足：${avail_bytes} bytes < ${SWAP_BYTES} bytes。请先确保有足够磁盘空间。"
      err "空间不足，脚本退出。"
    fi

    # 尝试使用 fallocate（更快），如果失败回退到 dd
    if command -v fallocate >/dev/null 2>&1; then
      if fallocate -l "${SWAPSIZE}" "${SWAPFILE}" 2>/dev/null; then
        info "使用 fallocate 创建 swapfile 完成。"
      else
        warn "fallocate 创建失败，尝试使用 dd 回退..."
        dd if=/dev/zero of="${SWAPFILE}" bs=1M count=2048 status=progress
      fi
    else
      info "fallocate 不可用，使用 dd 创建 swapfile（这可能需要一些时间）..."
      dd if=/dev/zero of="${SWAPFILE}" bs=1M count=2048 status=progress
    fi

    chmod 600 "${SWAPFILE}"
    info "设置文件权限为 600"

    # 标记为 swap 并启用
    mkswap "${SWAPFILE}"
    swapon "${SWAPFILE}"
    info "${SWAPFILE} 已创建并启用。"
  fi
fi

# 确保 /etc/fstab 中存在挂载项（避免重复添加）
FSTAB_LINE="${SWAPFILE} none swap sw 0 0"
if grep -Fxq "${FSTAB_LINE}" "${FSTAB}"; then
  info "/etc/fstab 已包含 swap 挂载项"
else
  info "将 swap 挂载项写入 ${FSTAB}"
  # 备份 fstab
  cp -p "${FSTAB}" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)" || true
  echo "${FSTAB_LINE}" >> "${FSTAB}"
  info "已追加：${FSTAB_LINE}"
fi

# 设置 vm.swappiness（持久化到 /etc/sysctl.d/99-swappiness.conf）
info "设置 vm.swappiness=${SWAPPINESS}（写入 ${SYSCTL_CONF}）"
cat > "${SYSCTL_CONF}" <<EOF
# set swappiness for better swap behaviour
vm.swappiness=${SWAPPINESS}
EOF

# 立即应用 sysctl 改动
info "应用 sysctl 配置..."
sysctl --system >/dev/null 2>&1 || {
  warn "sysctl --system 返回非零（可能旧系统）。尝试单独设置 vm.swappiness"
  sysctl -w vm.swappiness="${SWAPPINESS}" || true
}

info "最终 swap 状态："
swapon --show || true

info "内存使用摘要："
free -mh || true

info "完成：如果一切正常，/swapfile 将在系统重启后自动启用。"
