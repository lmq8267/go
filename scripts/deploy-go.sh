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

# ------------------------- 定位 Release -------------------------
REPO="${SOURCE_REPO:-$GITHUB_REPOSITORY}"
[ -n "$REPO" ] || { err "未指定发布仓库 (inputs.source-repo)"; exit 1; }

TAG="${TAG_ARG:-}"
if [ -n "$TAG" ]; then
  info "加载指定 Release: $REPO / tag=$TAG"
  RELEASE_URL="$(gh release view "$TAG" --repo "$REPO" --json url -q .url 2>/dev/null || true)"
  ASSET_URL="$(gh release view "$TAG" --repo "$REPO" --json assets \
                  -q '.assets[] | select(.name|endswith(".linux-amd64.tar.gz")) | .browser_download_url' \
                  2>/dev/null | head -n1 || true)"
else
  info "加载最新 Release: $REPO"
  TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)"
  RELEASE_URL="$(gh release view --repo "$REPO" --json url -q .url 2>/dev/null || true)"
  ASSET_URL="$(gh release view --repo "$REPO" --json assets \
                  -q '.assets[] | select(.name|endswith(".linux-amd64.tar.gz")) | .browser_download_url' \
                  2>/dev/null | head -n1 || true)"
fi

if [ -z "$TAG" ] || [ -z "$ASSET_URL" ]; then
  err "未找到可用 Release/资产。仓库=$REPO tag=${TAG:-最新的}"
  err "请确认: 发布仓库与分支输入正确、Release 已发布、资产含 *linux-amd64.tar.gz"
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
