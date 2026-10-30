"""Only isolated temporary homes and synthetic ELF files are used."""
from contextlib import nullcontext
from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jdk_switcher import core
from jdk_switcher.cli import main


def fake_jdk(home: Path, version="21.0.1", machine=62) -> Path:
    (home / "bin").mkdir(parents=True)
    (home / "release").write_text(f'JAVA_VERSION="{version}"\nIMPLEMENTOR="Test fixture"\nOS_NAME="Linux"\n', encoding="utf-8")
    binary = bytearray(64)
    binary[:6] = b"\x7fELF\x02\x01"
    binary[16:20] = struct.pack("<HH", 3, machine)
    for name in ("java", "javac"):
        file = home / "bin" / name
        file.write_bytes(binary)
        file.chmod(0o755)
    return home


class CoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="jdk-switcher-test-")
        def cleanup():
            # Windows scanners can briefly keep deleted directory entries open.
            for attempt in range(4):
                try:
                    self.temporary.cleanup()
                    return
                except OSError:
                    if attempt == 3:
                        raise
                    time.sleep(0.1)
        self.addCleanup(cleanup)
        self.home = Path(self.temporary.name).resolve()
        self.ctrl = core.Controller(self.home, {})
        self.jdk_a = fake_jdk(self.home / "runtimes/jdk a's", "17.0.1")
        self.jdk_b = fake_jdk(self.home / "runtimes/jdk-b", "21.0.1")
        self.start_patch(patch.object(core.platform, "machine", return_value="x86_64"))
        self.start_patch(patch.object(core, "require_linux_user"))
        # Windows has neither flock nor POSIX file modes. Only these adapters are
        # replaced locally; Ubuntu CI exercises the real lock and metadata paths.
        if os.name != "posix":
            self.start_patch(patch.object(self.ctrl, "_lock", side_effect=nullcontext))
            self.start_patch(patch.object(self.ctrl, "_validate_syntax"))
            original = self.ctrl.snapshot
            self.start_patch(patch.object(self.ctrl, "snapshot", side_effect=lambda p: replace(original(p), mode=0o600)))

    def start_patch(self, patcher):
        result = patcher.start()
        self.addCleanup(patcher.stop)
        return result

    def plan(self):
        return self.ctrl.plan_switch(self.jdk_a)

    def test_metadata_only_no_java_execution(self):
        with patch.object(core.subprocess, "run", side_effect=AssertionError("Must not execute Java")):
            info = core.inspect_jdk(self.jdk_a)
        self.assertEqual((info.major, info.architecture), (17, "x86_64"))

    def test_reject_incomplete_jre(self):
        (self.jdk_a / "bin/javac").unlink()
        with self.assertRaises(core.SafetyError):
            core.inspect_jdk(self.jdk_a)

    def test_reject_windows_or_non_elf_binary(self):
        (self.jdk_a / "bin/java").write_bytes(b"MZ" + bytes(62))
        with self.assertRaises(core.SafetyError):
            core.inspect_jdk(self.jdk_a)

    def test_reject_foreign_architecture(self):
        foreign = fake_jdk(self.home / "arm-jdk", machine=183)
        with self.assertRaisesRegex(core.SafetyError, "架构"):
            core.inspect_jdk(foreign)

    def test_discovery_follows_jdk_alias_but_deduplicates(self):
        with patch.dict(os.environ, {"JAVA_HOME": str(self.jdk_a), "PATH": ""}, clear=True):
            found = core.discover(self.home, (self.home / "runtimes",))
        homes = [jdk.home for jdk in found]
        self.assertTrue({str(self.jdk_a), str(self.jdk_b)} <= set(homes))
        self.assertEqual(homes.count(str(self.jdk_a)), 1)

    def test_preview_is_read_only(self):
        plan = self.plan()
        self.assertEqual(len(plan.changed), 3)
        self.assertFalse(self.ctrl.config.exists())
        self.assertFalse(self.ctrl.state.exists())
        self.assertIn("不存在", plan.diff())

    def test_preserves_original_bytes_without_final_newline(self):
        original = b"# custom config\nexport KEEP='unchanged'\n# trailing comment\xff"
        (self.home / ".bashrc").write_bytes(original)
        plan = self.plan()
        self.assertTrue(plan.after[self.home / ".bashrc"].content.startswith(original + b"\n"))
        self.assertEqual((self.home / ".bashrc").read_bytes(), original)

    def test_bash_uses_existing_highest_priority_login_file(self):
        (self.home / ".bash_profile").write_text("# existing\n")
        (self.home / ".profile").write_text("# lower priority\n")
        paths = self.ctrl.shell_files("bash")
        self.assertIn(self.home / ".bash_profile", paths)
        self.assertNotIn(self.home / ".profile", paths)

    def test_unknown_shell_is_rejected(self):
        with self.assertRaises(core.SafetyError):
            self.ctrl.plan_switch(self.jdk_a, "fish")

    def test_both_shells_and_custom_zdotdir(self):
        controller = core.Controller(self.home, {"ZDOTDIR": str(self.home / ".config/zsh")})
        paths = controller.shell_files("both")
        self.assertEqual(len(paths), 4)
        self.assertIn(self.home / ".config/zsh/.zshrc", paths)

    def test_rejects_xdg_path_outside_home(self):
        with self.assertRaises(core.SafetyError):
            core.Controller(self.home, {"XDG_CONFIG_HOME": str(self.home.parent / "outside")})

    def test_modified_or_duplicate_markers_rejected(self):
        hook = core.render_hook(self.ctrl.env_file)
        for content in (hook + hook, core.START + b"\nmodified\n" + core.END, core.START):
            with self.assertRaises(core.SafetyError):
                core.add_hook(content, self.ctrl.env_file)

    def test_trailing_line_continuation_rejected(self):
        with self.assertRaises(core.SafetyError):
            core.add_hook(b"export VALUE=hello\\\n", self.ctrl.env_file)

    def test_switch_is_backed_up_and_idempotent(self):
        plan = self.plan()
        backup = self.ctrl.apply(plan)
        self.assertTrue(backup.is_file())
        self.assertEqual(core.read_managed_home(self.ctrl.env_file.read_bytes()), str(self.jdk_a))
        count = len(self.ctrl.list_backups())
        self.assertIsNone(self.ctrl.apply(self.plan()))
        self.assertEqual(len(self.ctrl.list_backups()), count)

    def test_failure_to_backup_performs_no_writes(self):
        plan = self.plan()
        with patch.object(self.ctrl, "_backup", side_effect=OSError("disk full")), patch.object(self.ctrl, "_write") as writer:
            with self.assertRaisesRegex(OSError, "disk full"):
                self.ctrl.apply(plan)
            writer.assert_not_called()

    def test_stale_preview_is_rejected(self):
        plan = self.plan()
        (self.home / ".bashrc").write_text("# external edit\n")
        with self.assertRaisesRegex(core.SafetyError, "重新预览"):
            self.ctrl.apply(plan)
        self.assertFalse(self.ctrl.env_file.exists())

    def test_rolls_back_before_and_after_write_failure(self):
        for after in (False, True):
            with self.subTest(after=after):
                plan = self.plan()
                original_write = self.ctrl._write
                counter = 0

                def fail(path, state):
                    nonlocal counter
                    counter += 1
                    if counter == 2 and not after:
                        raise OSError("simulated failure")
                    original_write(path, state)
                    if counter == 2 and after:
                        raise OSError("simulated failure after write")

                with patch.object(self.ctrl, "_write", side_effect=fail):
                    with self.assertRaisesRegex(core.SafetyError, "已回滚"):
                        self.ctrl.apply(plan)
                self.assertEqual({p: self.ctrl.snapshot(p) for p in plan.before}, plan.before)

    def test_concurrent_same_file_edit_is_never_overwritten_by_rollback(self):
        plan = self.plan()
        original_write = self.ctrl._write

        def external(path, state):
            original_write(path, state)
            path.write_bytes(b"# external content\n")

        with patch.object(self.ctrl, "_write", side_effect=external):
            with self.assertRaisesRegex(core.SafetyError, "无法自动回滚"):
                self.ctrl.apply(plan)
        self.assertEqual(self.ctrl.env_file.read_bytes(), b"# external content\n")

    def test_concurrent_unrelated_edit_is_preserved(self):
        plan = self.plan()
        original_write = self.ctrl._write
        first = True

        def external(path, state):
            nonlocal first
            original_write(path, state)
            if first:
                first = False
                (self.home / ".bashrc").write_bytes(b"# concurrent shell edit\n")

        with patch.object(self.ctrl, "_write", side_effect=external):
            with self.assertRaisesRegex(core.SafetyError, "已回滚"):
                self.ctrl.apply(plan)
        self.assertFalse(self.ctrl.env_file.exists())
        self.assertEqual((self.home / ".bashrc").read_bytes(), b"# concurrent shell edit\n")

    def test_restore_preserves_original_content_and_missing_state(self):
        original = b"# original config\nexport EXAMPLE=keep\n"
        (self.home / ".bashrc").write_bytes(original)
        backup = self.ctrl.apply(self.plan())
        restore = self.ctrl.plan_restore(backup.name)
        second_backup = self.ctrl.apply(restore)
        self.assertTrue(second_backup.exists())
        self.assertEqual((self.home / ".bashrc").read_bytes(), original)
        self.assertFalse((self.home / ".profile").exists())
        self.assertFalse(self.ctrl.env_file.exists())

    def test_restore_refuses_post_switch_changes(self):
        backup = self.ctrl.apply(self.plan())
        (self.home / ".bashrc").write_bytes(b"# later edit\n")
        with self.assertRaisesRegex(core.SafetyError, "拒绝覆盖"):
            self.ctrl.plan_restore(backup.name)

    def test_restore_can_recover_a_partially_written_transaction(self):
        plan = self.plan()
        self.ctrl._check(self.ctrl.state, create=True)
        backup = self.ctrl._backup(plan)
        self.ctrl._write(self.ctrl.env_file, plan.after[self.ctrl.env_file])
        restore = self.ctrl.plan_restore(backup.name)
        self.assertEqual(restore.changed, [self.ctrl.env_file])
        self.ctrl.apply(restore)
        self.assertFalse(self.ctrl.env_file.exists())

    def test_manually_edited_environment_file_is_never_overwritten(self):
        self.ctrl.apply(self.plan())
        self.ctrl.env_file.write_bytes(self.ctrl.env_file.read_bytes() + b"# handwritten\n")
        with self.assertRaisesRegex(core.SafetyError, "拒绝覆盖"):
            self.ctrl.plan_switch(self.jdk_b)

    def test_damaged_backup_rejected(self):
        backup = self.ctrl.apply(self.plan())
        document = json.loads(backup.read_bytes())
        document["payload"]["schema"] = 9
        backup.write_text(json.dumps(document))
        with self.assertRaisesRegex(core.SafetyError, "完整性"):
            self.ctrl.plan_restore(backup.name)

    def test_backup_path_traversal_and_foreign_identity_rejected(self):
        with self.assertRaises(core.SafetyError):
            self.ctrl.plan_restore("../foreign.json")
        backup = self.ctrl.apply(self.plan())
        document = json.loads(backup.read_bytes())
        document["payload"]["identity"]["uid"] = -1
        encoded = json.dumps(document["payload"], sort_keys=True, ensure_ascii=True).encode()
        document["sha256"] = hashlib.sha256(encoded).hexdigest()
        backup.write_text(json.dumps(document))
        with self.assertRaisesRegex(core.SafetyError, "当前用户"):
            self.ctrl.plan_restore(backup.name)

    def test_no_noninteractive_write_without_yes(self):
        from contextlib import redirect_stdout, redirect_stderr
        import io
        with patch("jdk_switcher.cli.Controller", return_value=self.ctrl), patch("sys.stdin.isatty", return_value=False), redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(main(["switch", str(self.jdk_a), "--shell", "bash"]), 1)
        self.assertFalse(self.ctrl.env_file.exists())

    @unittest.skipUnless(os.name == "posix", "Startup file integration requires POSIX paths")
    def test_shell_hook_works_from_an_isolated_bash_home(self):
        bashrc = self.home / ".bashrc"
        bashrc.write_text("export KEEP_ORIGINAL=retained\n")
        self.ctrl.apply(self.plan())
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "LC_ALL": "C"}
        command = '. "$HOME/.bashrc"; printf "%s\\n%s\\n%s" "$JAVA_HOME" "${PATH%%:*}" "$KEEP_ORIGINAL"'
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", command], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True)
        self.assertEqual(result.stdout.splitlines(), [str(self.jdk_a), str(self.jdk_a / "bin"), "retained"])

    @unittest.skipUnless(os.name == "posix", "Real POSIX permissions and flock require Linux")
    def test_permissions_lock_and_original_mode(self):
        bashrc = self.home / ".bashrc"
        bashrc.write_text("# original\n")
        bashrc.chmod(0o640)
        plan = self.plan()
        backup = self.ctrl.apply(plan)
        self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.ctrl.backups.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(bashrc.stat().st_mode), 0o640)
        with self.ctrl._lock():
            with self.assertRaisesRegex(core.SafetyError, "另一个"):
                with self.ctrl._lock():
                    pass

    @unittest.skipUnless(os.name == "posix", "POSIX symlinks/permissions")
    def test_reject_symlink_hardlink_and_writable_config(self):
        bashrc = self.home / ".bashrc"
        external = self.home / "external"
        external.write_text("# private\n")
        bashrc.symlink_to(external)
        with self.assertRaises(core.SafetyError):
            self.plan()
        bashrc.unlink()
        os.link(external, bashrc)
        with self.assertRaises(core.SafetyError):
            self.plan()
        bashrc.unlink()
        bashrc.write_text("# unsafe\n")
        bashrc.chmod(0o666)
        with self.assertRaises(core.SafetyError):
            self.plan()

    @unittest.skipUnless(os.name == "posix", "Real Bash validation requires Linux")
    def test_reject_broken_shell_syntax_before_backup(self):
        (self.home / ".bashrc").write_text("if then\n")
        with self.assertRaisesRegex(core.SafetyError, "语法检查失败"):
            self.ctrl.apply(self.plan())
        self.assertFalse(self.ctrl.env_file.exists())
        self.assertEqual(self.ctrl.list_backups(), [])


class ShellTests(unittest.TestCase):
    def run_shell(self, shell: str, content: str, environment: dict | None = None):
        executable = os.environ.get("JDK_TEST_BASH") if shell == "bash" else None
        executable = executable or shutil.which(shell)
        if not executable:
            self.skipTest(shell + " is not installed")
        options = [executable, "--noprofile", "--norc", "-c"] if shell == "bash" else [executable, "-f", "-c"]
        env = dict(os.environ)
        for key in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS"):
            env.pop(key, None)
        if environment is not None:
            if "PATH" not in environment:
                env.pop("PATH", None)
            env.update(environment)
        return subprocess.run(options + [content], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True)

    def test_bash_and_zsh_path_order_empty_entries_and_idempotence(self):
        for shell in ("bash", "zsh"):
            with self.subTest(shell=shell):
                target = "/opt/jdk with a ' quote"
                script = core.render_environment(target).decode()
                before = ":/usr/bin::" + target + "/bin:/opt/old/bin:"
                content = "PATH=" + shlex.quote(before) + "\n" + script + script + "printf '%s\\n%s\\n' \"$JAVA_HOME\" \"$PATH\""
                result = self.run_shell(shell, content)
                self.assertEqual(result.stdout.splitlines(), [target, target + "/bin::/usr/bin::/opt/old/bin:"])

    def test_unset_path_does_not_introduce_current_directory(self):
        result = self.run_shell("bash", "unset PATH\n" + core.render_environment("/opt/jdk").decode() + "printf '%s' \"$PATH\"")
        self.assertEqual(result.stdout, "/opt/jdk/bin")

    def test_readonly_environment_is_left_unchanged(self):
        for variable in ("JAVA_HOME", "PATH"):
            with self.subTest(variable=variable):
                script = ("set -eu\nJAVA_HOME=/opt/original; PATH=/usr/bin; readonly " + variable + "\n"
                          "_jdk_test_source() {\n" + core.render_environment("/opt/new").decode() + "}\n"
                          "if _jdk_test_source; then printf UNEXPECTED; fi\n"
                          "printf '%s\\n%s' \"$JAVA_HOME\" \"$PATH\"")
                result = self.run_shell("bash", script)
                self.assertEqual(result.stdout.splitlines(), ["/opt/original", "/usr/bin"])

    def test_environment_supports_nounset_and_errexit(self):
        script = "set -eu\nunset PATH\n" + core.render_environment("/opt/new").decode() + "printf '%s' \"$PATH\""
        result = self.run_shell("bash", script)
        self.assertEqual(result.stdout, "/opt/new/bin")

    def test_existing_empty_path_is_preserved(self):
        result = self.run_shell("bash", "PATH=''\n" + core.render_environment("/opt/jdk").decode() + "printf '%s' \"$PATH\"")
        self.assertEqual(result.stdout, "/opt/jdk/bin:")

    def test_metacharacters_are_not_executed(self):
        result = self.run_shell("bash", core.render_environment("/opt/jdk-$(printf UNSAFE)").decode() + "printf '%s' \"$JAVA_HOME\"")
        self.assertEqual(result.stdout, "/opt/jdk-$(printf UNSAFE)")


if __name__ == "__main__":
    unittest.main()
