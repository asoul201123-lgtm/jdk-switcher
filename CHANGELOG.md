# 更新记录

## 1.2.0

- Windows 版新增从 Eclipse Adoptium 官方目录下载 Eclipse Temurin JDK。
- 支持选择可用 JDK 版本，自动匹配 x64 / ARM64 架构，并下载 Windows ZIP 免安装包。
- 下载支持进度、取消、SHA-256 校验、安全解压、JDK 结构与架构校验。
- 下载完成后可一键自动备份并切换；切换失败时保留已安装 JDK 并恢复原环境。
- 托管 JDK 保存在 `%LOCALAPPDATA%\SafeJdkSwitcher\jdks`，重启后仍会被扫描发现。
- 新增离线下载测试、下载弹窗 XAML 测试和 EXE 嵌入资源检查。

## 1.1.0

- 新增独立 Linux 版本，支持 Tk 桌面和命令行，扫描与校验 Linux ELF JDK。
- 支持 Bash / Zsh 当前用户环境切换、变更预览、原始文件备份和冲突保护恢复。
- 新增 Linux 单文件 Python zipapp、独立 tar.gz 发布包、隐私与元数据检查。
- 新增临时家目录的事务测试、真实 Bash/Zsh 测试和 Ubuntu CI。
- 保留 Windows EXE 与原有环境管理流程。

## 1.0.1

- 新增可双击启动的单文件 JdkSwitcher.exe，嵌入界面和环境管理核心。
- 通过 Windows 内置引擎进程内运行，不解压临时脚本，不修改执行策略。
- 新增离线 EXE 构建、编译后启动测试、二进制隐私检查及 SHA-256。
- 完整项目发布包同时包含 EXE、源码及构建脚本。

## 1.0.0

- Windows 原生桌面界面，常见安装位置自动发现和手动添加。
- 当前用户/系统两种范围的 JDK 切换与完整变更预览。
- 原始注册表备份、逐项校验、失败回滚与恢复预览。
- 并发改动保护、发布白名单和隐私扫描。
