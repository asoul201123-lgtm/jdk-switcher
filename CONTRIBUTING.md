# 贡献指南

欢迎修复问题和改进 Windows 上的 JDK 发现能力。新功能应继续遵循“预览、备份、最小修改、回读校验、可恢复”的原则。

## 本地检查

运行 `tests/Core.Tests.ps1`，并在 Windows PowerShell 5.1 和 PowerShell 7 上检查核心模块。界面变更执行 `src/App.ps1 -SmokeTest`；需要截图时使用 `-Demo -SmokeTest -PreviewImage docs/preview.png`，仅允许虚构数据出现在公开截图中。

测试使用内存存储模拟注册表，不得将本机真实环境变量作为写入测试目标。临时测试产物放入 `.local/` 并在结束后清理。

## 提交前

- 不提交备份、完整 Path、账户 SID、机器标识、个人邮箱、令牌、用户名、绝对工作目录或真实配置截图。
- 示例只用 `C:\Java\jdk-21`、`C:\Tools` 等通用路径。
- 运行 `scripts/Check-Privacy.ps1` 和 `scripts/Package.ps1`（包含 EXE 编译、嵌入资源和只读启动检查）；检查实际要提交的差异。
- PowerShell 源码使用 UTF-8 BOM，保持 5.1 兼容。不引入自动执行 JDK 二进制的发现流程。

请在 PR 中说明触发问题的通用场景、最终行为、验证方式及已知限制，不粘贴私人环境快照。

## Linux 版本

使用 `python3 -m unittest discover -s linux/tests -v` 验证隔离事务和 Shell 行为，使用 `python3 linux/package.py` 构建。Linux 代码使用 UTF-8、LF；`.pyc`、临时家目录与真实 Shell 配置不得入库。请在 Linux 上验证真实的文件权限、扩展属性、flock 和符号链接行为，不能用 Windows 模拟结果替代。
