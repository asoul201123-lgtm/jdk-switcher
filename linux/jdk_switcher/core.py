"""Linux discovery and recoverable shell-file transactions (standard library only)."""
from __future__ import annotations

import base64
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import difflib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import struct
import sys
import subprocess
import tempfile
from typing import Callable, Iterator
import uuid

MAX_FILE = 2 * 1024 * 1024
START = b"# >>> JDK Switcher Linux v1 >>>"
END = b"# <<< JDK Switcher Linux v1 <<<"
HEADER = "# JDK Switcher Linux managed environment v1\n"


class SafetyError(RuntimeError):
    """The requested change cannot be performed without risking existing state."""


def uid() -> int:
    return os.getuid() if hasattr(os, "getuid") else 0


def require_linux_user() -> None:
    if platform.system() != "Linux":
        raise SafetyError("写入操作仅支持 Linux；Windows 请使用 JdkSwitcher.exe。")
    if os.geteuid() == 0:
        raise SafetyError("请以普通用户运行，不要使用 sudo；本版本只管理当前用户的环境。")


def _arch(value: str) -> str:
    value = value.lower()
    return {"amd64": "x86_64", "arm64": "aarch64", "i686": "x86", "i386": "x86",
            "armv7l": "arm", "ppc64le": "ppc64", "riscv64": "riscv64"}.get(value, value)


@dataclass(frozen=True)
class Jdk:
    home: str
    version: str
    vendor: str
    architecture: str
    major: int


def inspect_jdk(path: str | Path) -> Jdk:
    home = Path(path).expanduser().resolve(strict=True)
    if any(ord(c) < 32 or ord(c) == 127 for c in str(home)) or (os.name == "posix" and ":" in str(home)):
        raise SafetyError("JDK 路径不能包含冒号或控制字符。")
    release = home / "release"
    if not release.is_file() or release.stat().st_size > MAX_FILE:
        raise SafetyError("缺少有效的 release 元数据。")
    metadata = dict(re.findall(r'^([A-Z_]+)="([^"\r\n]*)"$', release.read_text(encoding="utf-8"), re.M))
    version = metadata.get("JAVA_VERSION", "")
    if not re.fullmatch(r"\d+[\w.+-]*", version):
        raise SafetyError("JAVA_VERSION 无效。")
    if metadata.get("OS_NAME", "Linux").lower() != "linux":
        raise SafetyError("该 JDK 不是 Linux 版本。")
    arches = []
    for name in ("java", "javac"):
        binary = home / "bin" / name
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise SafetyError(f"缺少可执行的 bin/{name}，请选择完整 JDK。")
        with binary.open("rb") as stream:
            header = stream.read(20)
        if len(header) != 20 or header[:4] != b"\x7fELF" or header[4] not in (1, 2) or header[5] not in (1, 2):
            raise SafetyError(f"{name} 不是有效的 ELF 可执行文件。")
        if (header[5] == 1) != (sys.byteorder == "little"):
            raise SafetyError(f"{name} 的 ELF 字节序与本机不一致。")
        endian = "<" if header[5] == 1 else ">"
        binary_type, machine = struct.unpack(endian + "HH", header[16:20])
        arch = {3: "x86", 62: "x86_64", 183: "aarch64", 40: "arm", 21: "ppc64",
                243: "riscv64", 22: "s390x"}.get(machine)
        if binary_type not in (2, 3) or arch is None:
            raise SafetyError(f"{name} 的 ELF 类型或处理器架构不受支持。")
        if (arch in ("x86", "arm") and header[4] != 1) or (arch not in ("x86", "arm") and header[4] != 2):
            raise SafetyError(f"{name} 的 ELF 位数与架构不一致。")
        arches.append(arch)
    if arches[0] != arches[1]:
        raise SafetyError("java 与 javac 的架构不一致。")
    native = _arch(platform.machine())
    if native and arches[0] != native:
        raise SafetyError(f"该 JDK 架构为 {arches[0]}，当前系统为 {native}；为避免无法运行，已拒绝切换。")
    major = int(re.match(r"(?:1\.)?(\d+)", version).group(1))
    return Jdk(str(home), version, metadata.get("IMPLEMENTOR", "Unknown vendor"), arches[0], major)


def discover(home: Path | None = None, extra: tuple[Path, ...] = ()) -> list[Jdk]:
    home = home or Path.home()
    candidates: set[Path] = set()
    roots = [Path(p) for p in ("/usr/lib/jvm", "/usr/java", "/opt/java", "/opt/jdk", "/opt/jdks", "/opt/jvm", "/usr/local/java")]
    roots += [home / p for p in (".jdks", ".sdkman/candidates/java", ".asdf/installs/java", ".local/share/mise/installs/java")]
    roots += list(extra)
    if os.environ.get("JAVA_HOME"):
        candidates.add(Path(os.environ["JAVA_HOME"]))
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        for executable in ("java", "javac"):
            try:
                binary = Path(directory) / executable
                if binary.is_file():
                    candidates.add(binary.resolve().parent.parent)
            except OSError:
                pass
    for root in roots:
        candidates.add(root)
        level = [root]
        for _ in range(2):
            next_level = []
            for directory in level:
                if directory.is_symlink():
                    continue
                try:
                    with os.scandir(directory) as entries:
                        for index, entry in enumerate(entries):
                            if index >= 250:
                                break
                            if entry.is_dir():
                                child = Path(entry.path)
                                candidates.add(child)
                                if not entry.is_symlink() and not (child / "release").is_file():
                                    next_level.append(child)
                except OSError:
                    continue
            level = next_level
    found = {}
    for candidate in candidates:
        try:
            jdk = inspect_jdk(candidate)
            found[jdk.home] = jdk
        except (OSError, ValueError, UnicodeError, SafetyError):
            pass
    return sorted(found.values(), key=lambda j: (-j.major, j.home))


def render_environment(home: str) -> bytes:
    # POSIX syntax shared by Bash and Zsh. Only the exact target bin is deduped;
    # all unrelated and old JDK entries, including empty entries, are retained.
    guard = "if ! (JAVA_HOME=" + shlex.quote(home) + " PATH=${PATH-}) 2>/dev/null; then\n    return 1\nfi\n"
    return (HEADER + guard + "export JAVA_HOME=" + shlex.quote(home) + "\n" + '''_jdk_switcher_v1_new=$JAVA_HOME/bin
if [ "${PATH+x}" = x ]; then
    _jdk_switcher_v1_rest=$PATH
    while :; do
        case $_jdk_switcher_v1_rest in
            *:*) _jdk_switcher_v1_part=${_jdk_switcher_v1_rest%%:*}
                 _jdk_switcher_v1_rest=${_jdk_switcher_v1_rest#*:}
                 _jdk_switcher_v1_more=1 ;;
            *)   _jdk_switcher_v1_part=$_jdk_switcher_v1_rest
                 _jdk_switcher_v1_more=0 ;;
        esac
        if [ "$_jdk_switcher_v1_part" != "$JAVA_HOME/bin" ]; then
            _jdk_switcher_v1_new=$_jdk_switcher_v1_new:$_jdk_switcher_v1_part
        fi
        [ "$_jdk_switcher_v1_more" -eq 1 ] || break
    done
fi
export PATH=$_jdk_switcher_v1_new
unset _jdk_switcher_v1_new _jdk_switcher_v1_rest _jdk_switcher_v1_part _jdk_switcher_v1_more
''').encode("utf-8")


def read_managed_home(content: bytes) -> str:
    try:
        text = content.decode("utf-8")
        line = next(line for line in text.splitlines() if line.startswith("export JAVA_HOME="))
        parts = shlex.split(line[len("export JAVA_HOME="):])
        if len(parts) == 1 and render_environment(parts[0]) == content:
            return parts[0]
    except (UnicodeError, ValueError, StopIteration):
        pass
    raise SafetyError("受管 env.sh 含有未知或手动修改的内容，拒绝覆盖。请先核对并另存。")


def render_hook(env_file: Path) -> bytes:
    quoted = shlex.quote(str(env_file))
    return START + f"\nif [ -r {quoted} ]; then\n    if . {quoted}; then :; else\n        printf '%s\\n' 'JDK Switcher: Java environment could not be loaded; check readonly variables.' >&2\n    fi\nfi\n".encode("utf-8") + END + b"\n"


def add_hook(content: bytes, env_file: Path) -> bytes:
    hook = render_hook(env_file)
    if START in content or END in content:
        if content.count(START) != 1 or content.count(END) != 1 or hook not in content:
            raise SafetyError("Shell 配置中的受管标记被修改或不完整，拒绝覆盖。")
        return content
    # Ensure a previous line continuation cannot absorb the new hook.
    tail = content.rstrip(b"\r\n")
    if tail.endswith(b"\\"):
        raise SafetyError("Shell 文件以续行反斜杠结尾，不能安全追加配置。")
    return content + (b"\n" if content and not content.endswith(b"\n") else b"") + hook


@dataclass(frozen=True)
class FileState:
    exists: bool
    content: bytes = b""
    mode: int = 0o600
    owner: int = 0
    group: int = 0
    attributes: tuple[tuple[str, bytes], ...] = ()


@dataclass(frozen=True)
class Plan:
    action: str
    before: dict[Path, FileState]
    after: dict[Path, FileState]
    jdk: str = ""
    shells: str = "bash"

    @property
    def changed(self) -> list[Path]:
        return [path for path in self.before if self.before[path] != self.after[path]]

    def diff(self) -> str:
        result = []
        for path in self.changed:
            old, new = self.before[path], self.after[path]
            result.extend(difflib.unified_diff(
                old.content.decode("utf-8", "replace").splitlines(keepends=True),
                new.content.decode("utf-8", "replace").splitlines(keepends=True),
                fromfile=str(path) + (" (原值)" if old.exists else " (不存在)"),
                tofile=str(path) + (" (新值)" if new.exists else " (删除)")))
        return "".join(result) or "配置已是目标状态，无需修改。"


class Controller:
    def __init__(self, home: Path | None = None, environ: dict[str, str] | None = None):
        env = dict(os.environ) if environ is None else environ
        self.home = (home or Path.home()).resolve()
        self.config = Path(env.get("XDG_CONFIG_HOME") or self.home / ".config")
        self.state = Path(env.get("XDG_STATE_HOME") or self.home / ".local/state") / "jdk-switcher"
        self.zdotdir = Path(env.get("ZDOTDIR") or self.home)
        self.env_file = self.config / "jdk-switcher/env.sh"
        self.backups = self.state / "backups"
        for path in (self.config, self.state, self.zdotdir):
            self._relative(path)
        self.allowed = {self.env_file, *(self.home / p for p in (".bashrc", ".bash_profile", ".bash_login", ".profile")),
                        self.zdotdir / ".zshrc", self.zdotdir / ".zprofile"}

    def _relative(self, path: Path) -> str:
        if any(ord(c) < 32 or ord(c) == 127 for c in str(path)):
            raise SafetyError("配置路径不能包含控制字符。")
        if not path.is_absolute() or ".." in path.parts:
            raise SafetyError("配置路径必须是当前用户家目录内的绝对路径。")
        try:
            return path.relative_to(self.home).as_posix()
        except ValueError as error:
            raise SafetyError("为避免跨账户修改，配置与备份路径必须位于当前家目录内。") from error

    def _check(self, path: Path, create: bool = False) -> None:
        self._relative(path)
        current = self.home
        home_info = self.home.stat()
        if not stat.S_ISDIR(home_info.st_mode) or (os.name == "posix" and (home_info.st_uid != uid() or home_info.st_mode & 0o022)):
            raise SafetyError("家目录的所有者或写权限不安全。")
        for part in path.relative_to(self.home).parts:
            current /= part
            if not current.exists() and not current.is_symlink():
                if not create:
                    return
                current.mkdir(mode=0o700)
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
                raise SafetyError(f"配置目录不能是链接或普通文件：{current}")
            if os.name == "posix" and (info.st_uid != uid() or info.st_mode & 0o022):
                raise SafetyError(f"目录所有者或写权限不安全：{current}")

    def snapshot(self, path: Path) -> FileState:
        if path not in self.allowed:
            raise SafetyError("拒绝访问未列入允许列表的配置文件。")
        self._check(path.parent)
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags)
        except FileNotFoundError:
            return FileState(False, owner=uid(), group=os.getgid() if hasattr(os, "getgid") else 0)
        except OSError as error:
            raise SafetyError(f"无法安全读取配置文件：{path}") from error
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            if path.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > MAX_FILE:
                raise SafetyError(f"拒绝链接、非普通文件、硬链接或过大的配置文件：{path}")
            mode = stat.S_IMODE(info.st_mode)
            if os.name == "posix" and (info.st_uid != uid() or mode & 0o7022 or not mode & 0o200):
                raise SafetyError(f"配置文件所有者或写权限不安全：{path}")
            content = stream.read(MAX_FILE + 1)
            if len(content) > MAX_FILE:
                raise SafetyError("配置文件在读取时变得过大。")
            attributes = ()
            if hasattr(os, "listxattr"):
                attributes = tuple(sorted((name, os.getxattr(stream.fileno(), name)) for name in os.listxattr(stream.fileno())))
            return FileState(True, content, mode, info.st_uid, info.st_gid, attributes)

    def shell_files(self, shells: str) -> list[Path]:
        paths = []
        if shells not in ("bash", "zsh", "both"):
            raise SafetyError("仅支持 Bash 和 Zsh；Fish 等 Shell 不能使用此环境脚本。")
        if shells in ("bash", "both"):
            paths.append(self.home / ".bashrc")
            login = next((self.home / name for name in (".bash_profile", ".bash_login", ".profile")
                          if (self.home / name).exists() or (self.home / name).is_symlink()), self.home / ".profile")
            paths.append(login)
        if shells in ("zsh", "both"):
            paths.extend((self.zdotdir / ".zshrc", self.zdotdir / ".zprofile"))
        return paths

    def plan_switch(self, home: str | Path, shells: str = "bash") -> Plan:
        jdk = inspect_jdk(home)
        paths = [self.env_file] + self.shell_files(shells)
        before = {path: self.snapshot(path) for path in paths}
        if before[self.env_file].exists:
            read_managed_home(before[self.env_file].content)
        after = {}
        for path, old in before.items():
            content = render_environment(jdk.home) if path == self.env_file else add_hook(old.content, self.env_file)
            after[path] = FileState(True, content, old.mode, old.owner, old.group, old.attributes)
        return Plan("switch", before, after, jdk.home, shells)

    def _identity(self) -> dict:
        try:
            machine = Path("/etc/machine-id").read_bytes().strip()
        except OSError:
            machine = platform.node().encode("utf-8")
        return {"uid": uid(), "home": str(self.home), "config": str(self.config), "zdotdir": str(self.zdotdir),
                "machine": hashlib.sha256(machine).hexdigest()}

    @staticmethod
    def _encode(state: FileState) -> dict:
        record = asdict(state)
        record["content"] = base64.b64encode(state.content).decode("ascii")
        record["attributes"] = [[name, base64.b64encode(value).decode("ascii")] for name, value in state.attributes]
        return record

    @staticmethod
    def _decode(record: dict) -> FileState:
        try:
            if set(record) != {"exists", "content", "mode", "owner", "group", "attributes"}:
                raise ValueError("Invalid state keys")
            content = base64.b64decode(record["content"], validate=True)
            mode, owner, group = record["mode"], record["owner"], record["group"]
            if type(record["exists"]) is not bool or any(type(x) is not int or x < 0 for x in (mode, owner, group)):
                raise ValueError("Invalid state types")
            if mode > 0o777 or mode & 0o022 or len(content) > MAX_FILE:
                raise ValueError("Invalid file mode or size")
            if os.name == "posix" and record["exists"] and owner != uid():
                raise ValueError("Invalid file owner")
            attributes = tuple((name, base64.b64decode(value, validate=True)) for name, value in record["attributes"])
            if any(not isinstance(name, str) for name, _ in attributes):
                raise ValueError("Invalid attribute name")
            return FileState(record["exists"], content, mode, owner, group, attributes)
        except (ValueError, TypeError, KeyError) as error:
            raise SafetyError("备份的文件状态无效。") from error

    def _backup(self, plan: Plan) -> Path:
        self._check(self.backups, create=True)
        payload = {"schema": 1, "identity": self._identity(), "action": plan.action,
                   "files": {self._relative(path): {"before": self._encode(plan.before[path]), "after": self._encode(plan.after[path])}
                             for path in plan.before}}
        canonical = json.dumps(payload, sort_keys=True, ensure_ascii=True).encode("utf-8")
        record = json.dumps({"payload": payload, "sha256": hashlib.sha256(canonical).hexdigest()}, ensure_ascii=True).encode("utf-8")
        if len(record) > 32 * MAX_FILE:
            raise SafetyError("备份过大，已停止写入。")
        name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex + ".json"
        target = self.backups / name
        descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(record)
            stream.flush()
            os.fsync(stream.fileno())
        self._sync_directory(self.backups)
        if target.read_bytes() != record:
            raise SafetyError("备份回读校验失败，环境未修改。")
        return target

    def list_backups(self) -> list[Path]:
        self._check(self.backups)
        if not self.backups.exists():
            return []
        return sorted((p for p in self.backups.glob("*.json") if re.fullmatch(r"\d{8}T\d{6}-[a-f0-9]{32}\.json", p.name)), reverse=True)

    def plan_restore(self, name: str) -> Plan:
        if not re.fullmatch(r"\d{8}T\d{6}-[a-f0-9]{32}\.json", name):
            raise SafetyError("只能选择本机备份目录内的备份文件名。")
        self._check(self.backups)
        source = self.backups / name
        info = source.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > 32 * MAX_FILE:
            raise SafetyError("备份文件类型或大小无效。")
        if os.name == "posix" and (info.st_uid != uid() or info.st_mode & 0o077):
            raise SafetyError("备份文件所有者或权限不安全。")
        try:
            document = json.loads(source.read_bytes())
            payload = document["payload"]
            canonical = json.dumps(payload, sort_keys=True, ensure_ascii=True).encode("utf-8")
            if hashlib.sha256(canonical).hexdigest() != document["sha256"]:
                raise SafetyError("备份完整性校验失败。")
            if payload["schema"] != 1 or payload["identity"] != self._identity():
                raise SafetyError("仅能恢复当前机器、当前用户和原配置位置创建的备份。")
            files = payload["files"]
            if not isinstance(files, dict) or not 1 <= len(files) <= 5:
                raise SafetyError("备份的文件数量无效。")
            before, after = {}, {}
            for relative, record in files.items():
                path = self.home / relative
                if path not in self.allowed or self._relative(path) != relative:
                    raise SafetyError("备份包含不允许的文件路径。")
                old, written = self._decode(record["before"]), self._decode(record["after"])
                if old == written:
                    continue
                current = self.snapshot(path)
                if current != old and current != written:
                    raise SafetyError(f"备份后配置已被其他程序修改，拒绝覆盖：{path}")
                before[path], after[path] = current, old
            return Plan("restore", before, after)
        except (KeyError, TypeError, ValueError) as error:
            raise SafetyError("备份结构无效。") from error

    @staticmethod
    def _sync_directory(path: Path) -> None:
        if os.name == "posix":
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)

    def _write(self, path: Path, state: FileState) -> None:
        self._check(path.parent, create=True)
        if not state.exists:
            path.unlink(missing_ok=True)
            self._sync_directory(path.parent)
            return
        descriptor, name = tempfile.mkstemp(prefix=".jdk-switcher-", dir=path.parent)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(state.content)
                stream.flush()
                if os.name == "posix":
                    os.fchown(stream.fileno(), state.owner, state.group)
                    os.fchmod(stream.fileno(), state.mode)
                if hasattr(os, "setxattr"):
                    for attribute, value in state.attributes:
                        os.setxattr(stream.fileno(), attribute, value)
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            self._sync_directory(path.parent)
        finally:
            temporary.unlink(missing_ok=True)

    @contextmanager
    def _lock(self) -> Iterator[None]:
        import fcntl  # Linux-only, imported lazily so portable tests can read core.
        self._check(self.state, create=True)
        descriptor = os.open(self.state / "transaction.lock", os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != uid() or stat.S_IMODE(info.st_mode) & 0o077:
                raise SafetyError("事务锁文件的类型或权限不安全。")
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise SafetyError("另一个切换操作正在进行，请稍后重试。") from error
            yield
        finally:
            os.close(descriptor)

    def _validate_syntax(self, plan: Plan) -> None:
        for path in plan.changed:
            target = plan.after[path]
            if path == self.env_file or not target.exists:
                continue
            shell = "zsh" if path.name in (".zshrc", ".zprofile") else "bash"
            executable = next((str(p) for p in (Path("/bin") / shell, Path("/usr/bin") / shell) if p.is_file()), None)
            if executable is None:
                raise SafetyError(f"未安装 {shell}，无法检查配置语法；请只选择已安装的 Shell。")
            options = [executable, "--noprofile", "--norc", "-n"] if shell == "bash" else [executable, "-f", "-n"]
            try:
                result = subprocess.run(options, input=target.content, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        env={"PATH": "/usr/bin:/bin", "HOME": str(self.home), "LC_ALL": "C"}, timeout=10, check=False)
            except subprocess.TimeoutExpired as error:
                raise SafetyError(f"Shell 语法检查超时，环境未修改：{path}") from error
            if result.returncode or result.stderr:
                raise SafetyError(f"Shell 配置语法检查失败，环境未修改：{path}\n" + result.stderr.decode("utf-8", "replace"))

    def apply(self, plan: Plan) -> Path | None:
        require_linux_user()
        if set(plan.before) != set(plan.after) or not set(plan.before) <= self.allowed:
            raise SafetyError("变更计划包含不允许的文件。")
        with self._lock():
            if any(self.snapshot(path) != state for path, state in plan.before.items()):
                raise SafetyError("预览后配置已发生改变，请重新预览。")
            if plan.action == "switch":
                verified = self.plan_switch(plan.jdk, plan.shells)
                if verified.before != plan.before or verified.after != plan.after:
                    raise SafetyError("JDK 或配置计划已改变，请重新预览。")
            elif plan.action != "restore":
                raise SafetyError("未知操作。")
            if not plan.changed:
                return None
            self._validate_syntax(plan)
            backup = self._backup(plan)
            attempted = []
            expected = dict(plan.before)
            try:
                for path in plan.changed:
                    if any(self.snapshot(p) != state for p, state in expected.items()):
                        raise SafetyError("写入期间检测到外部配置修改。")
                    attempted.append(path)
                    self._write(path, plan.after[path])
                    expected[path] = plan.after[path]
                    if any(self.snapshot(p) != state for p, state in expected.items()):
                        raise SafetyError("文件写入回读校验失败。")
            except Exception as error:
                failures = []
                for path in reversed(attempted):
                    try:
                        actual = self.snapshot(path)
                        if actual == plan.before[path]:
                            continue
                        if actual != plan.after[path]:
                            raise SafetyError("存在第三方改动，未覆盖。")
                        self._write(path, plan.before[path])
                        if self.snapshot(path) != plan.before[path]:
                            raise SafetyError("回滚校验失败。")
                    except Exception as rollback_error:
                        failures.append(f"{path}: {rollback_error}")
                if failures:
                    raise SafetyError(f"操作失败，部分文件无法自动回滚：{'；'.join(failures)}。备份：{backup}") from error
                raise SafetyError(f"操作失败，已回滚本次写入：{error}。备份：{backup}") from error
            return backup

    def status(self) -> dict:
        state = self.snapshot(self.env_file)
        return {"saved_jdk": read_managed_home(state.content) if state.exists else None,
                "process_java_home": os.environ.get("JAVA_HOME"), "process_java": shutil.which("java"),
                "environment_file": str(self.env_file), "backup_count": len(self.list_backups())}
