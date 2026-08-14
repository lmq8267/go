# Go 工具链自动构建与发布仓库

> 一键在 GitHub Actions 上编译 **Go 官方源码**(默认 `master`)并发布工具链,主要用于**修复自 Go 1.26 以来 MIPS 系列平台编译的 Go 程序 runtime 崩溃问题**([golang/go#77730](https://github.com/golang/go/issues/77730));同时提供可复用部署流程,供其他仓库/CI 直接引用部署最新 Release。

## 🎯 项目背景：修复 MIPS 系列 Go 程序 runtime 崩溃问题

本仓库编译并发布的 Go 工具链,**核心目的是修复自 Go 1.26 版本以来、MIPS 系列平台(`mips` / `mipsle`)上编译的 Go 程序在运行时崩溃的问题**。

对应 Go 官方 issue：**[golang/go#77730 — runtime: regression segfault on linux 3.4 on mipsle](https://github.com/golang/go/issues/77730)**

### 问题现象

- 在 **mipsle**(MIPS 小端)平台的旧内核(**Linux 3.4**,仍处于 Go 官方支持范围内)上,Go 程序**启动阶段即崩溃**：
  ```text
  futexwakeup addr=0x586232c returned -89
  SIGSEGV: segmentation violation
  PC=0x816f0 m=0 sigcode=128 addr=0x0
  ```
- 崩溃发生在 runtime 创建新 goroutine 时:`newproc → wakep → startm → newm → allocm → mcommoninit → unlock → … → futexwakeup`,即程序刚启动就段错误(goroutine 0 与 goroutine 1 同时触发 `wakep`)。

### 根因分析

- **Go 1.26 引入回归**：runtime 开始调用 64 位时间 / 锁相关的 syscall(`timer_settime64`、`futex_time64`)。
- **旧内核不支持**：Linux 3.4 内核未实现这些 syscall,调用返回 `ENOSYS(-89)`;runtime 未对此优雅降级,随后在 futex 唤醒路径上访问空地址(`addr=0x0`),触发 SIGSEGV。
- 社区验证的直接规避手段：注释掉 runtime 中 `timer_settime64`、`futex_time64` 的调用即可解决。

### 修复与发布

- 官方修复已排入 **Go 1.27** 里程碑(issue 状态 `FixPending` / Done),因此本仓库**默认构建 `master` 分支**(包含修复),发布时也可手动输入 `release-branch.go1.27` 等分支。
- 除构建发布外,本仓库自带 **mipsel 交叉编译 + qemu 运行验证**(`测试mipsle-cloudflared.yml`),持续确认修复后的工具链在 MIPS 上编译的 Go 程序可正常编译、运行,不再崩溃。

---

## ✨ 特性

- 🎛️ **手动触发、可填分支**：在 Actions 页面输入任意 Go 源码分支(默认 `master`),自动完成"编译 → 打包 → 发布"。
- 📦 **打包格式与官方一致**：产出 `go1.XX.X.linux-amd64.tar.gz`(顶层 `go/` 目录)+ `.sha256`,仅需 x86-64(linux/amd64)。
- 🎨 **全程中文彩色日志**：编译、校验、打包、发布各阶段 ANSI 彩色输出,一目了然。
- 📋 **详细构建报告**：成功/失败都会把完整报告写入 `GITHUB_STEP_SUMMARY`,含**可点击跳转的编译提交记录**(commit 链接)、产物 SHA256、构建日志。
- 🚀 **Release 说明详尽**：发布页自动附带版本、分支、编译提交(可跳转)、作者、时间、SHA256、安装说明。
- 🔁 **可复用部署**：其他仓库 CI 以 `uses:` 直接引用本仓库的部署流程,自动拉取最新 Release 并设置全局 `PATH` / `GOROOT`。

---

## 📁 目录结构

```
action.yml                       # 部署操作「根入口」,支持 uses: <owner>/<repo>@main 简洁引用
.github/
└── workflows/
    ├── CI.yml                   # 构建并发布 Go 工具链(手动触发,默认 master 含 MIPS 修复)
    ├── deploy-go.yml            # 可复用部署流程(workflow_call,供其他 CI 引用)
    └── 测试mipsle-cloudflared.yml # 端到端测试:用发布产物编译并 qemu 运行 cloudflared
scripts/
├── go-toolchain-build.sh        # 构建/打包/发布/摘要核心脚本
└── deploy-go.sh                 # 部署复合操作核心脚本(由根 action.yml 调用)
```

---

## 🔧 方式一：构建并发布 Go 工具链（仓库内使用）

仓库的 Actions 页面 → 点击 **Run workflow**：

| 输入项 | 说明 | 默认值 |
|---|---|---|
| `go-branch` | Go 官方源码分支 | `master`(含 MIPS runtime 修复;也可填 `release-branch.go1.27` 等) |

### 执行流程

1. 浅克隆 `github.com/golang/go` 指定分支
2. 读取源码内 `VERSION` 与编译提交信息(commit 可点击跳转)
3. `src/make.bash` 构建 `linux/amd64` 工具链
4. 打包为官方格式 `go<版本>.linux-amd64.tar.gz` + `.sha256`,并解压到 `/usr/local/go` 做安装验证
5. 无论成败,生成详细报告写入 **构建摘要(GITHUB_STEP_SUMMARY)**
6. 发布到 **Releases**：tag 为 `go<版本>-<短提交号>`(如 `go1.24-abc12345`),统一作为正式 Release 发布;tag 已存在时仅更新说明与资产

### 产物说明

| 文件 | 说明 |
|---|---|
| `go1.24.linux-amd64.tar.gz` | 官方同款格式工具链,解压到 `/usr/local/go` 即可使用 |
| `go1.24.linux-amd64.tar.gz.sha256` | SHA256 校验文件 |

Release 说明与构建摘要均包含**编译时提交记录的可点击链接**:

```
[abc12345](https://github.com/golang/go/commit/<完整SHA>)
```

---

## 🔁 方式二：在其他 CI 中部署最新 Release（可复用 workflow）

其他仓库(或其他 workflow)以 **job 级 `uses:`** 引用本仓库的部署流程,自动下载部署当前仓库最新 Release 的 Go 工具链。

### 参数说明

| 参数 | 类型 | 说明 |
|---|---|---|
| `source-repo` | string | 发布 Go 工具链的仓库(格式 `owner/repo`)。留空默认调用方当前仓库;**跨仓库部署必须传入** |
| `tag` | string | 指定 Release tag;留空 = 最新 Release |
| `install-dir` | string | GOROOT 安装目录,默认 `/usr/local/go`(需与发布包 `GOROOT_FINAL` 一致) |

### 输出 (outputs)

| 输出 | 说明 |
|---|---|
| `go-version` | 部署的 Go 版本(`go version` 输出) |
| `go-root` | GOROOT 安装目录 |
| `release-url` | 部署的 Release 页面链接 |
| `tag` | 部署的 Release tag 名 |

### 示例：其他仓库 CI 部署并随后使用

```yaml
name: 使用 Go 工具链
on: push

jobs:
  # 1) 可复用工作流以 job 方式部署最新 Release(独立 job)
  deploy-go:
    uses: <发布工具链的仓库>/.github/workflows/deploy-go.yml@main
    with:
      source-repo: <发布工具链的仓库>   # 跨仓库部署,必须传入
      tag: ''                           # 留空 = 最新 Release

  # 2) 需要 go 的 job,通过 outputs.go-root 注入 PATH
  build:
    needs: deploy-go
    runs-on: ubuntu-latest
    steps:
      - name: 启用 go(PATH)
        run: echo "${{ needs.deploy-go.outputs.go-root }}/bin" >> $GITHUB_PATH
      - name: 使用 go
        run: |
          go version
          go env GOROOT GOOS GOARCH
```

> ⚠️ **作用域限制**：GitHub Actions 中 `PATH`/`GOROOT` 是 **job 级**环境变量。可复用工作流是独立 job,它内部写入的 `PATH` 不会自动传给调用方其他 job,因此调用方需按上例用 `outputs.go-root` 在自己的 job 中追加 `PATH`。

---

## 🧪 方式三：端到端测试发布产物（仓库内）

仓库自带 `测试mipsle-cloudflared.yml` 验证 workflow：用「当前仓库」发布的最新 Go 工具链交叉编译 cloudflared(`GOOS=linux GOARCH=mipsle GOMIPS=softfloat`),再经 qemu-mipsel 运行验证,证明发布产物真实可编译、可运行。可选输入 `tag` 指定测试某个 Release(留空 = 最新)。全程中文彩色日志,无论成功/失败都会输出详细测试报告到 `GITHUB_STEP_SUMMARY`。

```yaml
# 手动触发: Actions → 测试mipsel版cloudflared → Run workflow
# 可选填 tag,留空测试最新 Release
```

---

## ⚡ 进阶：同一 job 内直接使用 go（composite action）

如果希望**同一 job 的后续步骤直接执行 `go` 命令**(无需手动追加 PATH),请改用复合操作——它在调用方 job 内运行,写入的 `PATH`/`GOROOT` 对当前 job 后续步骤**立即生效**:

```yaml
name: 部署并立即使用 Go
on: push

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: lmq8267/go@main
        with:
          tag: ''                           # 留空 = 最新 Release
      # 之后的步骤无需任何配置,直接使用 go:
      - name: 直接使用 go
        run: go version && go build ./...
```

composite action 的输入参数与输出(outputs `go-version` / `go-root` / `release-url` / `tag`)与方式二一致,私有仓库场景可通过 `token:` 传入高权限 token。

---

## ❓ 常见问题

**Q：构建产物安装到哪里?**
发布包以 `GOROOT_FINAL=/usr/local/go` 编译,解压到 `/usr/local/go` 即可直接使用(与官方发布一致)。若安装到其他目录,需设置 `export GOROOT=/你的目录`。

**Q：Release 的 tag 为什么带短提交号?**
tag 格式为 `go<版本>-<短提交号>`(如 `go1.24-abc12345`),保证同一版本多次构建时 tag 唯一、不冲突;发布包文件名则保持纯官方格式 `go1.24.linux-amd64.tar.gz`。

**Q：在 Windows / macOS / arm64 等非 linux/amd64 的 CI 上引用会怎样?**
部署流程(composite action 与可复用 workflow)启动时会**自动校验当前 runner 平台**,仅 `linux/amd64`(x86-64)放行,其他平台会立即以中文错误提示终止本次部署,避免把 amd64 工具链误装到不兼容平台。请在调用方使用 `runs-on: ubuntu-latest` 等 x86-64 Linux runner。

**Q：为什么其他 CI 引用后 `go` 命令还是不可用?**
参见上文"作用域限制"。可复用工作流是独立 job,请在调用方需要 go 的 job 中追加 `outputs.go-root` 到 `$GITHUB_PATH`,或改用 composite action(同 job 生效)。

**Q：需要构建其他架构(arm64 等)?**
当前仅构建并发布 `linux/amd64`(可在 CI 直接运行的 x86-64 工具链)。如需其他架构可扩展脚本中的 `GOOS`/`GOARCH` 与打包逻辑。

---

## 📄 License

遵循上游 [Go 开源协议](https://github.com/golang/go/blob/master/LICENSE)。本仓库仅为自动构建发布方案。
