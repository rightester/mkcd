# mkcd 跨平台实现方案总结

## 需求

实现 `mkcd` 命令：一次调用完成 `mkdir + cd`，创建目录并进入其中。需覆盖四个平台：

- Windows CMD（`.cmd`）
- Windows PowerShell（`.ps1`）
- Linux Bash（`.sh`）
- macOS（`.sh`）

要求为**独立可执行脚本**，而非 shell 函数。

---

## 核心难点：`cd` 的进程边界

`cd` 是 shell 内置命令，**只能改变当前进程的工作目录**。不同平台下独立脚本的进程模型不同：

| 平台 | 脚本执行方式 | cd 是否影响调用者 |
|------|-------------|:---------------:|
| CMD `.bat/.cmd` | 同进程 | ✅ |
| PowerShell `.ps1` | 同进程，`Set-Location` 修改 session 状态 | ✅ |
| Bash/Shell `.sh` | 子进程（fork+exec） | ❌ |

关键发现：
- **CMD 和 PowerShell 的脚本跑在调用者进程内**，`cd` 直接改变当前 shell 的目录
- **Unix Shell 脚本跑在子进程中**，`cd` 不影响父 shell

---

## 各平台最终方案

### Windows CMD（`mkcd.cmd`）

不涉及子进程，直接 cd：

```batch
@echo off
mkdir %*
if errorlevel 1 exit /b 1
for %%a in (%*) do set "last=%%a"
cd /d "%last%"
```

### Windows PowerShell（`mkcd.ps1`）

`.ps1` 脚本与调用者同进程，`Set-Location` 直接生效，无需额外处理：

```powershell
mkdir @args
if ($?) {
  Set-Location $args[-1]
}
```

#### PowerShell 陷阱：`$LASTEXITCODE` 不适用于 cmdlet

```powershell
mkdir @args
if ($LASTEXITCODE -eq 0) { ... }  # ❌ 永远不会进入
```

PowerShell 的 `mkdir` 是 `New-Item -ItemType Directory` 的别名，属于 **cmdlet**，不是外部命令。cmdlet 不设置 `$LASTEXITCODE`。应改用：

```powershell
mkdir @args
if ($?) { ... }  # ✅ $? 检查上一条命令是否成功
```

### Linux（`mkcd.sh`）

Shell 脚本在子进程运行，`cd` 无法传出。改为：创建目录 → `cd` 进入 → 启动**同类型子 shell**：

```bash
#!/usr/bin/env bash
mkdir "$@"
cd "${@: -1}" || exit

# 检测当前实际进程的 shell，启动同类型子 shell
if [ -r /proc/$$/exe ]; then
  # Linux: /proc/$$/exe 是到实际可执行文件的符号链接
  exec "$(readlink /proc/$$/exe)"
elif command -v lsof >/dev/null 2>&1; then
  # macOS 无 /proc/$$/exe，用 lsof 回退
  exec "$(lsof -p $$ -Fn | awk 'NR>1 && /^n\//{print substr($0,2); exit}')"
else
  exec "$SHELL"   # 兜底
fi
```

工作流：
```
~ $ mkcd /tmp/foo
/tmp/foo $    ← 已进入子 shell
/tmp/foo $ exit
~ $            ← 回到原 shell
```

#### 为什么不用 `$SHELL`？

`$SHELL` 存的是**登录 shell**（`/etc/passwd` 中配置），不等于**当前实际运行的 shell**：

```
登录 shell: bash
$ exec fish        ← 现在跑的是 fish
$ echo $SHELL
/bin/bash          ← 仍然指向 bash，不符预期 ❌
```

`/proc/$$/exe` 方案：
- 直接读取当前进程的可执行文件路径
- **不依赖 shell 类型名称列表**，任意标准可执行文件形式的 shell 均可适配
- 兼容 bash / zsh / fish / dash / nix-shell 等

### macOS（`mkcd_macos.sh`）

内容同 Linux。macOS 10.15+ 默认 shell 为 zsh，但检测逻辑自动适配实际 shell，不受 shebang 影响。

---

## 探索过程回顾

1. **直接 cd（失败）**：一开始所有人平台都写 `mkdir + cd`，发现 Shell 脚本的 `cd` 不影响调用者
2. **启动子 shell（矫枉过正）**：给全部平台都加了子 shell 逻辑，同时踩了 PowerShell 的 `$LASTEXITCODE` 和 `Resolve-Path` 的坑
3. **实测发现真相**：PowerShell 和 CMD 一样**同进程执行**，不需要子 shell；Shell 脚本才需要子 shell 方案
4. **Shell 检测**：从 `$SHELL` 进化到 `/proc/$$/exe`，保证 `exec fish` 后仍能正确识别当前 shell

---

## 最终行为对比

| 平台 | 脚本 | cd 机制 | 使用方式 |
|------|------|---------|---------|
| Windows CMD | `mkcd.cmd` | 直接 cd（同进程） | 放入 PATH，直接运行 |
| Windows PowerShell | `mkcd.ps1` | `Set-Location` 修改 session | `.\mkcd.ps1 <dir>` 或放入 PATH |
| Linux | `mkcd.sh` | 启动子 shell | `chmod +x` 后放入 PATH |
| macOS | `mkcd_macos.sh` | 启动子 shell | 同上 |

## 附：为什么不做函数？

shell 函数无进程边界，`cd` 天然继承给调用者，实现更简单：

```bash
# .bashrc
mkcd() { mkdir "$@" && cd "${@: -1}"; }
```

但函数无法作为独立文件分发、不能放到 `$PATH` 里跨 shell 共享、也无法用于非交互式场景。独立脚本配合子 shell 方案是更好的工程选择。
