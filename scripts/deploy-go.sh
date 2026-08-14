#!/usr/bin/env bash
# =============================================================================
#
# 从指定仓库的最新 Release(或指定 tag)下载 Go 官方工具链(linux/amd64),
# 校验 SHA256 后安装到 INSTALL_DIR,并写入 PATH / GOROOT 环境变量,
# 使调用方当前 job 的后续步骤可直接使用 go 命令。
#
# 需要环境变量: SOURCE_REPO / TAG_ARG / INSTALL_DIR / GH_TOKEN
#   (由 action.yml 传入)
# =============================================================================
set -euo pipefail

# ------------------------- 中文彩色日志 -------------------------
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'

info()    { printf '  %s■ %s%s\n' "$C_BLUE"     "$C_RESET" "$*"; }
ok()      { printf '  %s✔ %s%s\n' "$C_GREEN"    "$C_RESET" "$*"; }
warn()    { printf '  %s⚠ %s%s\n' "$C_YELLOW"   "$C_RESET" "$*"; }
err()     { printf '  %s✘ %s%s\n' "$C_RED"      "$C_RESET" "$*" >&2; }
section() { local t="$*" line="" i; for ((i = 0; i < ${#t}; i++)); do line+="━"; done; \
            printf '\n%s━━ %s ━━%s\n' "$C_MAGENTA$C_BOLD" "$t" "$C_RESET"; }

# ------------------------- 平台匹配检查 -------------------------
# 本仓库发布的工具链仅支持 linux/amd64 (x86-64);若当前 runner 不是该平台,
# 立即报错退出,避免把 amd64 工具链在 arm64 / Windows / macOS 等处误装。
check_platform() {
  local os_name arch
  os_name="$(uname -s)"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64)            arch="amd64" ;;
    aarch64|arm64)           arch="arm64" ;;
    i386|i486|i586|i686|x86) arch="386" ;;
  esac
  if [ "$os_name" != "Linux" ] || [ "$arch" != "amd64" ]; then
    err "当前运行环境: ${os_name}/${arch}"
    err "本仓库发布的 Go 工具链仅支持 linux/amd64 (x86-64)。"
    err "请在 linux/amd64 runner 上调用(如 runs-on: ubuntu-latest),本步骤将拒绝在其它平台部署。"
    return 1
  fi
  ok "运行环境匹配: Linux/amd64 (x86-64)"
}

section "部署 Go 工具链 · linux/amd64"

# runner 平台校验: 非 linux/amd64 立即拒绝,避免在其他平台误用
check_platform

# ------------------------- 定位 Release (REST API) -------------------------
# 使用 gh api(REST)获取,字段为固定的 snake_case(tag_name / html_url /
# browser_download_url),不受 gh CLI --json 输出 camelCase 风格影响
REPO="${SOURCE_REPO:-$GITHUB_REPOSITORY}"
[ -n "$REPO" ] || { err "未指定发布仓库 (inputs.source-repo)"; exit 1; }

TAG="${TAG_ARG:-}"
REL_JSON=""
if [ -n "$TAG" ]; then
  info "加载指定 Release: $REPO / tag=$TAG"
  REL_JSON="$(gh api "repos/${REPO}/releases/tags/${TAG}" 2>/dev/null || true)"
else
  info "加载最新 Release: $REPO"
  REL_JSON="$(gh api "repos/${REPO}/releases/latest" 2>/dev/null || true)"
fi

if [ -z "$REL_JSON" ]; then
  err "无法获取该 Release 信息(仓库=$REPO tag=${TAG:-latest})。"
  err "请确认: 仓库名正确、该 release 已发布、GITHUB_TOKEN 有读取权限。"
  exit 1
fi

TAG="$(printf '%s' "$REL_JSON" | jq -r '.tag_name' 2>/dev/null || true)"
RELEASE_URL="$(printf '%s' "$REL_JSON" | jq -r '.html_url' 2>/dev/null || true)"
ASSET_URL="$(printf '%s' "$REL_JSON" | jq -r \
              '.assets[] | select(.name|endswith(".linux-amd64.tar.gz")) | .browser_download_url' \
              2>/dev/null | head -n1 || true)"

if [ -z "$ASSET_URL" ]; then
  err "未在该 Release 中找到 *linux-amd64.tar.gz 资产(仓库=$REPO tag=${TAG:-最新的})。"
  err "请确认发布流程已成功上传资产(压缩包 + .sha256)。"
  exit 1
fi

ok "定位 Release: $TAG"
info "资产: ${ASSET_URL##*/}"

# ------------------------- 下载并校验 -------------------------
info "下载发布包 ..."
TMP="$RUNNER_TEMP/go-deploy"; rm -rf "$TMP"; mkdir -p "$TMP"
curl -fsSL "$ASSET_URL" -o "$TMP/go.tar.gz"

ACTUAL="$(sha256sum "$TMP/go.tar.gz" | awk '{print $1}')"
EXPECT="$(curl -fsSL "${ASSET_URL}.sha256" 2>/dev/null | awk '{print $1}' || true)"
if [ -n "$EXPECT" ]; then
  [ "$ACTUAL" = "$EXPECT" ] || { err "SHA256 校验失败! 期望=$EXPECT 实际=$ACTUAL"; exit 1; }
  ok "SHA256 校验通过: $ACTUAL"
else
  warn "未获取到官方 sha256,跳过校验(实际=$ACTUAL)"
fi

# ------------------------- 安装 -------------------------
info "安装到 $INSTALL_DIR ..."
tar -C "$TMP" -xzf "$TMP/go.tar.gz"                       # 解出 $TMP/go
sudo rm -rf "$INSTALL_DIR"
sudo mkdir -p "$(dirname "$INSTALL_DIR")"
sudo mv "$TMP/go" "$INSTALL_DIR"

# ------------------------- 全局 PATH / GOROOT -------------------------
# 写入 GITHUB_PATH / GITHUB_ENV → 调用方当前 job 的后续步骤立即生效
echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"
echo "GOROOT=$INSTALL_DIR" >> "$GITHUB_ENV"
info "已写入 PATH: $INSTALL_DIR/bin"
info "已写入 GOROOT: $INSTALL_DIR"

# ------------------------- 验证与输出 -------------------------
GO_VER="$("$INSTALL_DIR/bin/go" version)"
ok "go version → $GO_VER"
info "GOROOT    → $("$INSTALL_DIR/bin/go" env GOROOT)"
info "GOOS/GOARCH → $("$INSTALL_DIR/bin/go" env GOOS) / $("$INSTALL_DIR/bin/go" env GOARCH)"

echo "go_version=$GO_VER"       >> "$GITHUB_OUTPUT"
echo "go_root=$INSTALL_DIR"     >> "$GITHUB_OUTPUT"
echo "release_url=$RELEASE_URL" >> "$GITHUB_OUTPUT"
echo "tag=$TAG"                 >> "$GITHUB_OUTPUT"

ok "部署完成。当前 job 的后续步骤可直接执行 go 命令。"
