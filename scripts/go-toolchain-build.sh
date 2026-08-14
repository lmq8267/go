#!/usr/bin/env bash
# =============================================================================
# 构建并发布 Go 官方工具链 (linux/amd64) 到 GitHub Releases
# -----------------------------------------------------------------------------
# 用法: go-toolchain-build.sh <fetch-info|build|package|summary|release>
#
# 依赖环境变量（由 CI workflow 提供，未设置时回退到 $RUNNER_TEMP 默认值）:
#   GO_BRANCH, BUILD_ROOT, GO_SRC, LOG_FILE, INFO_FILE, NOTES_FILE, SUMMARY_FILE
#   GITHUB_ENV, GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_SERVER_URL, RUNNER_TEMP
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# 临时目录/路径默认值: CI 自动注入 $RUNNER_TEMP;本地调试时可自行覆盖这些变量
# -----------------------------------------------------------------------------
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
BUILD_ROOT="${BUILD_ROOT:-$RUNNER_TEMP/gosrc}"
GO_SRC="${GO_SRC:-$BUILD_ROOT/go}"
LOG_FILE="${LOG_FILE:-$RUNNER_TEMP/build.log}"
INFO_FILE="${INFO_FILE:-$RUNNER_TEMP/go_info.txt}"
NOTES_FILE="${NOTES_FILE:-$RUNNER_TEMP/notes.md}"
SUMMARY_FILE="${SUMMARY_FILE:-$RUNNER_TEMP/summary.md}"

# -----------------------------------------------------------------------------
# 彩色日志工具（全程 ANSI 彩色输出，GitHub Actions 日志会渲染颜色）
# -----------------------------------------------------------------------------
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'

log()     { printf '%s[%s]%s %s\n' "$C_CYAN" "$(date +%H:%M:%S)" "$C_RESET" "$*"; }
info()    { printf '  %s■ %s%s\n'   "$C_BLUE" "$C_RESET" "$*"; }
ok()      { printf '  %s✔ %s%s\n'   "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '  %s⚠ %s%s\n'   "$C_YELLOW" "$C_RESET" "$*"; }
err()     { printf '  %s✘ %s%s\n'   "$C_RED" "$C_RESET" "$*" >&2; }

section() {
  local t="$*" line="" i
  for ((i = 0; i < ${#t}; i++)); do line+="━"; done
  printf '\n%s━━ %s ━━%s\n' "$C_MAGENTA$C_BOLD" "$t" "$C_RESET"
}

# 从 INFO_FILE 安全读取一行 KV（容错：值中可能含 =、特殊字符）
info_val() { grep -m1 "^$1=" "$INFO_FILE" | cut -d= -f2- || true; }

# -----------------------------------------------------------------------------
# 模式一：克隆 Go 源码、读取版本与提交信息
# -----------------------------------------------------------------------------
cmd_fetch_info() {
  section "获取 Go 源码与提交信息"
  local branch="${GO_BRANCH:-master}"
  branch="${branch//[^a-zA-Z0-9._-]/}"
  [ -n "$branch" ] || { err "分支名非法: ${GO_BRANCH:-空}"; exit 1; }

  info "源码分支: $branch"
  info "浅克隆 Go 官方源码 → $GO_SRC"
  rm -rf "$BUILD_ROOT"; mkdir -p "$BUILD_ROOT"
  git clone --depth 1 --single-branch --branch "$branch" \
    https://github.com/golang/go.git "$GO_SRC" 2>&1 | sed 's/^/    /'
  [ -d "$GO_SRC/.git" ] || { err "克隆失败：分支 '$branch' 可能不存在"; exit 1; }

  cd "$GO_SRC"
  local version full short msg date author url
  version="$(head -n1 VERSION | tr -d '[:space:]')"
  full="$(git rev-parse HEAD)"
  short="$(git rev-parse --short=8 HEAD)"
  msg="$(git log -1 --format=%s)"
  date="$(git log -1 --format='%aD')"
  author="$(git log -1 --format='%an <%ae>')"
  url="https://github.com/golang/go/commit/$full"

  if [[ ! "$version" =~ ^go[0-9] ]]; then
    err "VERSION 文件内容异常: '$version'"
    exit 1
  fi

  log "版本: $C_BOLD$version$C_RESET | 提交: $C_BOLD$short$C_RESET | 分支: $branch"
  info "提交信息: $msg"

  # 供后续步骤使用的简单安全变量
  {
    echo "VERSION=$version"
    echo "SHORT_SHA=$short"
    echo "FULL_SHA=$full"
    echo "COMMIT_URL=$url"
    echo "TAG=${version}-${short}"
    echo "PKG_FILE=${version}.linux-amd64.tar.gz"
  } >> "$GITHUB_ENV"

  # 详细提交信息（供 summary / release notes 使用）
  {
    echo "VERSION=$version"
    echo "BRANCH=$branch"
    echo "SHORT_SHA=$short"
    echo "FULL_SHA=$full"
    echo "COMMIT_URL=$url"
    echo "COMMIT_MSG=$msg"
    echo "COMMIT_DATE=$date"
    echo "COMMIT_AUTHOR=$author"
  } > "$INFO_FILE"

  ok "版本信息已保存: $version ($short)"
}

# -----------------------------------------------------------------------------
# 模式二：构建工具链（本机构建即 linux/amd64）
# -----------------------------------------------------------------------------
cmd_build() {
  section "构建 Go 工具链 · linux/amd64"
  # make.bash 位于 Go 源码树的 src/ 子目录
  cd "$GO_SRC/src"

  info "检查构建依赖 (gcc / make / git)..."
  for t in gcc make git; do
    command -v "$t" >/dev/null 2>&1 || { err "缺少依赖: $t"; exit 1; }
  done
  ok "依赖检查通过: gcc, make, git"

  info "检测 Bootstrap Go ..."
  local bootstrap
  bootstrap="$(go env GOROOT)"
  export GOROOT_BOOTSTRAP="$bootstrap"
  export GOROOT_FINAL=/usr/local/go
  info "Bootstrap GOROOT: $bootstrap  ($(go version))"
  echo "BOOTSTRAP_GO=$(go version)" >> "$GITHUB_ENV"

  info "运行 src/make.bash --no-banner ..."
  ./make.bash --no-banner 2>&1 | tee -a "$LOG_FILE"
  local status=${PIPESTATUS[0]}
  if [ "$status" -ne 0 ]; then
    err "make.bash 构建失败 (退出码 $status)"
    err "完整构建日志: $LOG_FILE"
    exit 1
  fi

  ok "构建完成"
  info "go version → $("$GO_SRC/bin/go" version)"
  info "GOOS/GOARCH → $("$GO_SRC/bin/go" env GOOS) / $("$GO_SRC/bin/go" env GOARCH)"
}

# -----------------------------------------------------------------------------
# 模式三：打包为官方发布格式并验证
# -----------------------------------------------------------------------------
cmd_package() {
  section "打包为官方发布格式 (linux/amd64)"
  cd "$BUILD_ROOT"

  info "清理源码树中的临时/无关文件..."
  rm -rf go/pkg/obj go/.git go/.github

  info "打包 ${PKG_FILE} ..."
  tar -C "$BUILD_ROOT" -czf "${PKG_FILE}" go
  sha256sum "${PKG_FILE}" > "${PKG_FILE}.sha256"
  ok "SHA256: $(awk '{print $1}' "${PKG_FILE}.sha256")"

  section "验证发布包（完整安装到 /usr/local/go）"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "${PKG_FILE}"
  local ver
  ver="$(/usr/local/go/bin/go version)"
  ok "go version → $ver"
  echo "VERIFY_GO_VERSION=$ver" >> "$GITHUB_ENV"

  printf 'package main\nimport ("fmt";"runtime")\nfunc main(){fmt.Println("Hello, Go Toolchain!", runtime.Version())}\n' > /tmp/hello_verify.go
  ok "编译运行验证 → $(/usr/local/go/bin/go run /tmp/hello_verify.go)"

  echo "ARTIFACT_SIZE=$(ls -lh "${PKG_FILE}" | awk '{print $5}')" >> "$GITHUB_ENV"
  info "产物清单:"
  ls -lh "${PKG_FILE}" "${PKG_FILE}.sha256" | sed 's/^/    /'
}

# -----------------------------------------------------------------------------
# 模式四：生成构建摘要（summary）与发布说明（release notes）
# -----------------------------------------------------------------------------
cmd_summary() {
  local status="${JOB_STATUS:-success}"
  section "生成构建摘要与发布说明"

  # 读取详细提交信息（容错）
  local version branch short full url msg date author
  version=""; branch=""; short=""; full=""; url=""; msg=""; date=""; author=""
  if [ -f "$INFO_FILE" ]; then
    version="$(info_val VERSION)";  branch="$(info_val BRANCH)"
    short="$(info_val SHORT_SHA)";  full="$(info_val FULL_SHA)"
    url="$(info_val COMMIT_URL)";   msg="$(info_val COMMIT_MSG)"
    date="$(info_val COMMIT_DATE)"; author="$(info_val COMMIT_AUTHOR)"
  fi
  # env 中（若后续步骤已设置）优先
  version="${VERSION:-$version}"; short="${SHORT_SHA:-$short}"
  url="${COMMIT_URL:-$url}";       branch="${BRANCH:-$branch}"
  [ -n "$version" ] || version="未知"
  [ -n "$short" ]  || short="未知"
  [ -n "$url" ]    || url="#"

  local badge
  case "$status" in
    success)   badge="✅ **成功**" ;;
    failure)   badge="❌ **失败**" ;;
    cancelled) badge="⚠️ **已取消**" ;;
    *)         badge="\`$status\`" ;;
  esac

  local msg_safe
  msg_safe="$(printf '%s' "$msg" | sed 's/|/\\|/g')"
  [ -n "$msg_safe" ] || msg_safe="（无法获取提交信息）"

  local run_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
  local tag="${TAG:-}" release_url=""
  if [ -n "$tag" ]; then
    release_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/releases/tag/${tag}"
  fi

  local pkg_sha="" pkg_size="${ARTIFACT_SIZE:-}" verify_ver="${VERIFY_GO_VERSION:-}"
  if [ -n "${PKG_FILE:-}" ] && [ -f "${BUILD_ROOT}/${PKG_FILE}.sha256" ]; then
    pkg_sha="$(awk '{print $1}' "${BUILD_ROOT}/${PKG_FILE}.sha256")"
  fi

  # 生成 markdown；$1=输出文件  $2=true 时附带构建日志
  gen_md() {
    local out="$1" inc_log="$2"
    {
      echo "# 🚀 Go 工具链构建发布报告"
      echo
      echo "## 📋 构建结果：$badge"
      echo
      echo "| 项目 | 信息 |"
      echo "|---|---|"
      echo "| 构建状态 | $badge |"
      echo "| Go 版本 | \`$version\` |"
      echo "| 源码分支 | \`${branch:-未知}\` |"
      echo "| 提交 | [\`$short\`]($url) |"
      echo "| 提交信息 | $msg_safe |"
      echo "| 提交作者 | ${author:-未知} |"
      echo "| 提交时间 | ${date:-未知} |"
      echo
      echo "## 🛠️ 构建环境"
      echo
      echo "| 项目 | 信息 |"
      echo "|---|---|"
      echo "| 目标平台 | \`linux/amd64\` (x86-64) |"
      echo "| 构建系统 | GitHub Actions \`ubuntu-latest\` |"
      echo "| Bootstrap Go | \`${BOOTSTRAP_GO:-未检测}\` |"
      echo "| GOROOT_FINAL | \`/usr/local/go\` |"
      echo "| 打包格式 | 与官方一致：tar.gz 顶层为 \`go/\` 目录 |"
      echo
      echo "## 📦 构建产物"
      echo
      if [ "$status" = "success" ] && [ -n "$pkg_sha" ]; then
        echo "| 文件 | 大小 | SHA256 |"
        echo "|---|---|---|"
        echo "| \`${PKG_FILE}\` | ${pkg_size:-未知} | \`$pkg_sha\` |"
        echo "| \`${PKG_FILE}.sha256\` | — | \`SHA256 校验文件\` |"
        echo
        if [ -n "$verify_ver" ]; then
          echo "安装验证：\`$verify_ver\`"
          echo
        fi
        if [ -n "$release_url" ]; then
          echo "**Release 下载地址**：[${release_url}]($release_url)"
          echo
        fi
      else
        echo "未生成产物（构建未成功，请查看上方状态与下方日志）。"
        echo
      fi

      echo "## 🔗 相关链接"
      echo
      echo "- [本次构建运行]($run_url)"
      if [ -n "$full" ]; then
        echo "- [编译时源码提交 \`$short\`]($url)"
        echo "- [提交详情 \`$full\`](https://github.com/golang/go/commit/$full)"
      fi
      if [ -n "$release_url" ]; then
        echo "- [Release 页面]($release_url)"
      fi
      echo "- [Go 官方版本下载页](https://go.dev/dl/)"
      echo "- [Go 官方源码仓库](https://github.com/golang/go)"
      echo

      if [ "$status" = "success" ]; then
        echo "## 🚀 使用方式"
        echo
        echo '```bash'
        echo "# 打开 Release 页面下载，或直接命令行下载："
        echo "wget <Release 中的资产地址>/${version}.linux-amd64.tar.gz"
        echo "sudo tar -C /usr/local -xzf ${version}.linux-amd64.tar.gz"
        echo 'export PATH=$PATH:/usr/local/go/bin'
        echo 'go version'
        echo '```'
        echo
      fi

      if [ "$inc_log" = "true" ] && [ -f "$LOG_FILE" ]; then
        echo "## 📜 构建日志（尾部）"
        echo
        echo "<details>"
        echo "<summary>点击展开查看构建日志</summary>"
        echo
        echo '```text'
        sed 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG_FILE" | tail -n 300
        echo '```'
        echo "</details>"
        echo
      fi
    } > "$out"
  }

  gen_md "$SUMMARY_FILE" true
  gen_md "$NOTES_FILE" false

  ok "摘要 → $SUMMARY_FILE"
  ok "发布说明 → $NOTES_FILE"
}

# -----------------------------------------------------------------------------
# 模式五：发布到 GitHub Releases
# -----------------------------------------------------------------------------
cmd_release() {
  section "发布到 GitHub Releases"
  cd "$BUILD_ROOT"
  # 显式指定目标仓库,避免 gh 依赖当前目录的 git 配置(此处 $BUILD_ROOT 不是 git 仓库)
  local repo="${GITHUB_REPOSITORY:?未指定 GITHUB_REPOSITORY}"
  local title="${VERSION} · linux/amd64 · ${SHORT_SHA}"

  if gh release view "$TAG" --repo "$repo" >/dev/null 2>&1; then
    # 已存在: 不删除重建,仅更新说明(body)与资产(file)
    warn "Release '$TAG' 已存在,仅更新说明与资产"
    gh release edit "$TAG" --repo "$repo" \
      --title "$title" \
      --notes-file "$NOTES_FILE"
    gh release upload "$TAG" --repo "$repo" --clobber \
      "${PKG_FILE}" "${PKG_FILE}.sha256"
    ok "已更新 Release '$TAG' 的说明(body)与资产(file)"
  else
    info "创建新的正式 Release: $VERSION"
    gh release create "$TAG" --repo "$repo" \
      "${PKG_FILE}" "${PKG_FILE}.sha256" \
      --title "$title" \
      --notes-file "$NOTES_FILE"
  fi

  local url
  url="$(gh release view "$TAG" --repo "$repo" --json url -q .url)"
  echo "RELEASE_URL=$url" >> "$GITHUB_ENV"
  ok "Release → $url"
  info "Tag: $TAG"
  info "资产: ${PKG_FILE}, ${PKG_FILE}.sha256"
}

# -----------------------------------------------------------------------------
case "${1:-}" in
  fetch-info) cmd_fetch_info ;;
  build)      cmd_build ;;
  package)    cmd_package ;;
  summary)    cmd_summary ;;
  release)    cmd_release ;;
  *)
    echo "用法: $0 <fetch-info|build|package|summary|release>" >&2
    exit 2
    ;;
esac
