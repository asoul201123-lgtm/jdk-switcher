from __future__ import annotations

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import shlex
import sys

from . import __version__
from .core import Controller, SafetyError, discover


def default_shell() -> str | None:
    shell = Path(os.environ.get("SHELL", "")).name
    return shell if shell in ("bash", "zsh") else None


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Linux JDK Switcher：预览、备份后切换当前用户的 Bash/Zsh 环境。")
    result.add_argument("--version", action="version", version=__version__)
    result.add_argument("--demo", action="store_true", help="虚构数据的只读桌面演示")
    result.add_argument("--smoke-test", action="store_true", help="创建并验证桌面界面，不执行写入")
    sub = result.add_subparsers(dest="command")
    scan = sub.add_parser("list", help="只读扫描已安装的 Linux JDK")
    scan.add_argument("--root", action="append", default=[], help="附加扫描目录，可重复指定")
    scan.add_argument("--json", action="store_true")
    sub.add_parser("status", help="查看已保存配置与当前进程环境")
    for name in ("preview", "switch"):
        operation = sub.add_parser(name, help="预览切换" if name == "preview" else "备份并切换")
        operation.add_argument("jdk", help="完整 JDK 根目录")
        operation.add_argument("--shell", choices=("bash", "zsh", "both"), default=default_shell())
        if name == "switch":
            operation.add_argument("--yes", action="store_true", help="明确同意预览中的文件修改，适合自动化")
    sub.add_parser("backups", help="列出本地备份")
    restore = sub.add_parser("restore", help="预览并恢复本机当前账户的备份")
    restore.add_argument("name", help="backups 命令显示的备份文件名")
    restore.add_argument("--yes", action="store_true")
    return result


def confirm() -> bool:
    if not sys.stdin.isatty():
        raise SafetyError("非交互环境需显式传入 --yes 才能修改配置。")
    return input("核对以上变更，输入 yes 备份并应用：").strip() == "yes"


def describe_result(controller: Controller, backup: Path | None) -> None:
    if backup is None:
        print("配置已是目标状态，无需修改。")
    else:
        print("已完成，原始文件已备份：" + backup.name)
        print("请重新打开终端。若要更新当前 Bash/Zsh，请主动执行：")
        print(". " + shlex.quote(str(controller.env_file)))
        print("恢复操作后应重新登录；运行中的终端和 IDE 不会被本工具改写。")


def menu(controller: Controller) -> int:
    jdks = discover(controller.home)
    print("JDK Switcher Linux · " + __version__)
    for index, jdk in enumerate(jdks, 1):
        print(f"{index}. Java {jdk.version} | {jdk.vendor} | {jdk.home}")
    choice = input("选择 JDK 序号，输入目录路径，或输入 q 退出：").strip()
    if choice == "q" or not choice:
        return 0
    target = jdks[int(choice) - 1].home if choice.isdigit() and 1 <= int(choice) <= len(jdks) else choice
    shell = default_shell()
    if shell is None:
        shell = input("选择需要配置的 Shell（bash / zsh / both）：").strip()
    plan = controller.plan_switch(target, shell)
    print(plan.diff())
    if plan.changed and confirm():
        describe_result(controller, controller.apply(plan))
    return 0


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        if arguments.command is None:
            if arguments.demo or arguments.smoke_test or os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
                from .gui import run
                return run(demo=arguments.demo, smoke_test=arguments.smoke_test)
            if sys.stdin.isatty():
                return menu(Controller())
            parser().print_help()
            return 0
        if arguments.demo or arguments.smoke_test:
            raise SafetyError("--demo / --smoke-test 不能与写入或其他子命令组合。")
        controller = None if arguments.command == "list" else Controller()
        if arguments.command == "list":
            jdks = discover(Path.home(), tuple(Path(p).expanduser() for p in arguments.root))
            if arguments.json:
                print(json.dumps([asdict(jdk) for jdk in jdks], ensure_ascii=False, indent=2))
            else:
                for jdk in jdks:
                    print(f"{jdk.version:18} {jdk.architecture:9} {jdk.vendor:24} {jdk.home}")
                if not jdks:
                    print("未发现完整、架构匹配的 Linux JDK。可通过 --root 添加安装目录。")
        elif arguments.command == "status":
            print(json.dumps(controller.status(), ensure_ascii=False, indent=2))
        elif arguments.command == "backups":
            for backup in controller.list_backups():
                print(backup.name)
        else:
            if arguments.command == "restore":
                plan = controller.plan_restore(arguments.name)
            else:
                if arguments.shell is None:
                    raise SafetyError("无法识别默认 Shell；请通过 --shell 显式选择 bash 或 zsh。")
                plan = controller.plan_switch(arguments.jdk, arguments.shell)
            print(plan.diff())
            if arguments.command != "preview" and plan.changed and (arguments.yes or confirm()):
                describe_result(controller, controller.apply(plan))
        return 0
    except (SafetyError, OSError, ValueError) as error:
        print("操作未完成：" + str(error), file=sys.stderr)
        return 1
    except ImportError as error:
        print("桌面界面不可用，请安装发行版的 Python Tk 组件，或使用 list / preview / switch 等命令。\n" + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\n已取消。", file=sys.stderr)
        return 130
