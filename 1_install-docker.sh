#!/usr/bin/env bash
# 安装 Docker Engine 与 Docker Compose（插件或 standalone 二进制）脚本
# 兼容：Ubuntu (apt)
# 用法：
#   sudo bash install-docker.sh [username]
# 如果不传 username，会尝试使用 $SUDO_USER 或当前 $USER，将该用户加入 docker 组。

set -euo pipefail

# 可配置项
USERNAME="${1:-${SUDO_USER:-${USER:-root}}}"
DOCKER_GPG_KEYRING="/etc/apt/keyrings/docker.gpg"
DOCKER_REPO_FILE="/etc/apt/sources.list.d/docker.list"
COMPOSE_BIN="/usr/local/bin/docker-compose"

info() { printf "\e[32m[INFO]\e[0m %s\n" "$*"; }
warn() { printf "\e[33m[WARN]\e[0m %s\n" "$*"; }
err()  { printf "\e[31m[ERROR]\e[0m %s\n" "$*"; exit 1; }

# 检查是否以 root 或 sudo 执行
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 身份运行脚本：sudo bash $0"
fi

# 检查 apt 是否可用
if ! command -v apt-get >/dev/null 2>&1; then
  err "未检测到 apt-get，本脚本仅支持基于 apt 的系统（例如 Ubuntu/Debian）"
fi

info "开始安装前的准备：更新 apt 索引并安装依赖包"
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

# 创建 keyrings 目录
mkdir -p "$(dirname "$DOCKER_GPG_KEYRING")"

info "下载 Docker 官方 GPG key 并写入 ${DOCKER_GPG_KEYRING}"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o "${DOCKER_GPG_KEYRING}"

UBUNTU_CODENAME="$(lsb_release -cs || echo focal)"
ARCH="$(dpkg --print-architecture || uname -m)"
info "系统信息：codename=${UBUNTU_CODENAME} arch=${ARCH}"

info "添加 Docker 官方 apt 源到 ${DOCKER_REPO_FILE}"
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=${DOCKER_GPG_KEYRING}] https://download.docker.com/linux/ubuntu \
  ${UBUNTU_CODENAME} stable" > "${DOCKER_REPO_FILE}"

info "更新 apt 索引"
apt-get update -y

info "安装 Docker Engine、containerd 与 Compose 插件（如果可用）"
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin || {
  warn "apt 安装 docker 或 docker-compose-plugin 失败，继续尝试安装 core 部分（docker-ce/docker-ce-cli/containerd.io）"
  apt-get install -y docker-ce docker-ce-cli containerd.io || err "安装 Docker 失败"
}

info "启用并启动 docker 服务"
systemctl enable --now docker

# 验证 docker 可用
if ! command -v docker >/dev/null 2>&1; then
  err "docker 命令不可用，安装可能失败"
fi

info "检测 docker compose 命令（插件或二进制）"
if docker compose version >/dev/null 2>&1; then
  info "检测到 docker compose 插件 (docker compose)，版本："
  docker compose version
else
  warn "未检测到 docker compose 插件，尝试安装 standalone docker-compose 二进制到 ${COMPOSE_BIN}"
  # 获取最新 release 的下载地址（官方推荐的静态下载地址）
  DOWNLOAD_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)"
  info "从 ${DOWNLOAD_URL} 下载..."
  if curl -fsSL "${DOWNLOAD_URL}" -o "${COMPOSE_BIN}"; then
    chmod +x "${COMPOSE_BIN}"
    info "已安装 ${COMPOSE_BIN}"
  else
    warn "从 GitHub 下载 docker-compose 二进制失败，尝试使用 apt 安装（可能不存在）"
    apt-get install -y docker-compose || warn "apt 无法安装 docker-compose，安装已尽力"
  fi

  if command -v docker-compose >/dev/null 2>&1; then
    info "检测到 docker-compose：$(docker-compose --version)"
  fi
fi

# 将用户加入 docker 组，避免每次 sudo
if id -u "${USERNAME}" >/dev/null 2>&1; then
  info "将用户 ${USERNAME} 添加到 docker 组（如果尚未加入）"
  usermod -aG docker "${USERNAME}" || warn "usermod 返回非零，可能用户已在组中或出错"
else
  warn "指定用户 ${USERNAME} 不存在，跳过加入 docker 组"
fi

# 防火墙提示（不自动修改）
info "注意：请确认防火墙/云安全组允许你需要的端口（例如 80/443/8080/8000 等）"

# 输出版本信息
info "安装完成，版本信息："
docker --version || true
if docker compose version >/dev/null 2>&1; then
  docker compose version || true
else
  docker-compose --version || true
fi

cat <<EOF

下一步（请手动执行或在新会话中）：
- 如果你用的是非 root 用户（例如 ${USERNAME}），需要重新登录或运行：
    newgrp docker
  或登出并重新登录，令 docker 组生效。
- 测试命令：
    docker run --rm hello-world
    docker ps
    docker compose version    （或 docker-compose --version）
- 若需要安装 docker-compose plugin 的替代（standalone docker-compose），脚本已尝试下载到 ${COMPOSE_BIN}。
- 若你在 AWS 或其他云，请确保 Security Group / 防火墙允许 HTTP(S)（80/443）和其他需要的端口。

若你希望，我可以：
- 为你的项目目录生成一个一键启动的 docker compose 启动脚本（包含 nginx/wordpress/证书目录），
- 或者把这个脚本改为非交互式的 batch 部署脚本，自动修改防火墙规则（需要你确认允许端口）。

EOF

exit 0
