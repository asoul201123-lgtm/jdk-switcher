# JDK Switcher · Linux

独立的 Linux 版本：自动发现 JDK，支持桌面界面和命令行，预览后切换当前用户的 Java 环境。Windows 版本继续保留在仓库根目录。

**Python 3.10+ · 无 pip 依赖 · Bash / Zsh · 无遥测 · MIT**

## 启动

解压 `jdk-switcher-1.1.0-linux.tar.gz`，进入目录：

```sh
cd jdk-switcher-linux
./jdk-switcher
```

发布包中的 `jdk-switcher` 是带可执行权限的单文件 Python zipapp，需要系统安装 Python 3.10 或更新版本；它不是 ELF 原生二进制。也可运行独立下载的 `jdk-switcher-linux.pyz`：

```sh
python3 jdk-switcher-linux.pyz
```

有桌面显示服务时打开 Tk 界面；无桌面且连接终端时使用交互菜单。GUI 需要发行版提供的 Python Tk 组件；没有 Tk 时仍可使用所有命令行功能。不会自动安装软件。Tk 是否可用可用 `python3 -m tkinter` 检查，参见 [Python 官方文档](https://docs.python.org/3/library/tkinter.html)。Wayland 桌面可能需要兼容当前系统 Tk 的显示服务或 XWayland。

源码启动：`python3 jdk_switcher.py` 或 `sh Start.sh`。请以目标普通用户运行，**不要 sudo**。

## 一键切换

界面选择 JDK 与 Bash / Zsh，核对逐行差异，点击“备份并一键切换”。未发现的安装可以“添加目录”。Fish、Csh、PowerShell 等不兼容此环境脚本；当前默认 Shell 无法识别时，必须主动选择需要配置的 Bash 或 Zsh。

本版本只管理当前用户的 Shell 环境，不更改 `/usr/bin/java`、`/etc/profile`、`update-alternatives` 或其他用户的配置。JDK 不会被删除或重新安装。

```sh
# 自动发现，也可以加 --root /opt/java 指定其他安装位置
./jdk-switcher list

# 只读预览
./jdk-switcher preview /opt/java/jdk-21 --shell bash

# 预览、人工确认后备份并切换
./jdk-switcher switch /opt/java/jdk-21 --shell bash

# 自动化场景明确同意写入；选择 zsh 或 both 时会检查对应 Shell 的语法
./jdk-switcher switch /opt/java/jdk-21 --shell both --yes

# 查看已保存环境和本进程环境（两者可能不同）
./jdk-switcher status

# 列出备份，然后选择输出中的文件名恢复
./jdk-switcher backups
./jdk-switcher restore BACKUP_FILENAME
```

## 生效范围

切换后，**新打开的对应 Shell** 会加载配置。程序不能改变父终端或运行中 IDE 的环境；若需要让当前 Bash/Zsh 立即使用目标 JDK，主动执行成功提示中的加载命令，默认位置为：

```sh
. "$HOME/.config/jdk-switcher/env.sh"
command -v java
command -v javac
java -version
javac -version
```

配置了 `XDG_CONFIG_HOME` 时以程序提示的实际路径为准。恢复旧配置后建议重新登录，单纯再次 source 不能撤销已进入父进程的所有环境变更。

会同时配置所选 Shell 的交互和登录入口：

- Bash：`.bashrc`，以及现有的 `.bash_profile`、`.bash_login`、`.profile` 中优先级最高的一个；三个都不存在时只创建 `.profile`，避免新建 `.bash_profile` 屏蔽原有入口。
- Zsh：当前 `ZDOTDIR` 下的 `.zshrc`、`.zprofile`；未设置 `ZDOTDIR` 时使用家目录。

启动文件顺序分别依据 [Bash 官方文档](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files.html) 和 [Zsh 官方文档](https://zsh.sourceforge.io/Doc/Release/Files.html)。如果 `ZDOTDIR` 仅在其他启动脚本内设置，运行工具前应先导出正确的 `ZDOTDIR`。Shell 中提前执行 `return` / `exit`、禁用启动文件，或稍后加载的自定义脚本，都可能阻止加载或再次覆盖 Java 环境；工具不会执行你的启动文件来猜测最终结果。

IDE 固定的 JDK、服务和计划任务可能不读取这些交互/登录配置，仍需单独设置。别名、函数和当前目录中的命令也可能影响实际执行结果。

## 安全设计

- 扫描只读 `release` 和 `java` / `javac` 的 ELF 文件头，不执行未知 JDK；检查完整 JDK、Linux 格式、可执行位与本机 CPU 架构。元数据检查不是签名验证，JDK 仍应来自可信发行方。
- 只修改 `env.sh` 与所选 Shell 文件中的受管加载块，保留原有文件字节。PATH 只移除目标 bin 的重复项，不删除旧 JDK 或其他条目。
- 写入前展示完整差异，原始文件、缺失状态、权限及可读取的扩展属性先备份，再逐文件原子替换、回读校验。
- 使用 `flock` 防止本工具并发写入；预览过期则停止。写入失败会倒序回滚，遇到第三方改动时拒绝覆盖并报告待处理文件。
- 加载前会在子 Shell 中检查 `JAVA_HOME` 和 `PATH` 是否可写；只读变量导致加载失败时保留原环境，加载块不会因 `set -e` 直接终止启动流程。
- Shell 文件写入前执行对应 Shell 的 `-n` 语法检查，不执行启动文件；语法错误、警告或选定的 Shell 未安装时停止操作。
- 拒绝 Shell 配置符号链接、硬链接、不安全的目录/文件写权限、非当前用户所有的文件、过大的配置和修改过的受管块。使用 dotfiles 链接管理器的用户需要先手动核对并调整，工具不会拆毁链接。
- 使用当前家目录内的 XDG 配置位置；跨家目录的 XDG 或 ZDOTDIR 路径被拒绝。自定义 SELinux 标签、ACL 或其他元数据无法保留时也会停止，不静默移除。

跨多个文件的修改不是整体原子事务。断电或强制终止时不能执行自动回滚，但原配置已先备份，可恢复已经写入的部分。第三方也不受本工具锁约束，检查与替换之间仍有竞态窗口；不要让多个环境管理器同时修改这些文件。

## 备份与恢复

- 环境脚本：`${XDG_CONFIG_HOME:-$HOME/.config}/jdk-switcher/env.sh`
- 备份目录：`${XDG_STATE_HOME:-$HOME/.local/state}/jdk-switcher/backups`
- 新建目录使用 `0700`，备份使用 `0600`。原有安全目录不会自动修改权限。

备份包含原始 Shell 文件、家目录路径、用户 UID 和机器标识的哈希，只保存在本机，**不要提交到公开仓库**。恢复只接受原机器、用户和配置位置匹配的本地备份。恢复前会再次备份，后续手动修改过的文件会拒绝覆盖。自动回滚不删除操作中创建的空目录。

完整性哈希用于发现损坏，不是数字签名；同一用户和管理员可以修改备份。只选择自己创建的可信备份，并核对预览。

## 开发与发布

在项目根目录运行：

```sh
python3 -m unittest discover -s linux/tests -v
python3 linux/jdk_switcher.py --demo --smoke-test
python3 linux/package.py
```

构建输出 `dist/jdk-switcher-linux.pyz`、`dist/jdk-switcher-1.1.0-linux.tar.gz` 和对应 SHA-256 文件。构建使用固定白名单，不打包缓存、备份、本机状态、绝对编译路径或任何 Windows EXE。tar 内文件的 UID、GID、用户名、组名及时间戳均使用通用值。

测试使用临时家目录和虚构 ELF 文件，不更改开发者真实 Shell 配置。Windows 能运行隔离逻辑及可用的 Bash 测试，但真实 Linux 权限、锁、链接和 Zsh 需要 Linux 环境验证；仓库中的 Ubuntu CI 包含这些检查与虚拟显示下的 GUI 检查。
