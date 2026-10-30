"""Optional Tk desktop; imported only for graphical runs."""
from __future__ import annotations

import os
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import filedialog, ttk

from . import __version__
from .cli import default_shell
from .core import Controller, Jdk, SafetyError, discover, inspect_jdk


class App:
    def __init__(self, root: tk.Tk, demo: bool = False):
        self.root = root
        self.demo = demo
        self.controller = None if demo else Controller()
        self.plan = None
        self.jdks = []
        self.extra = []
        self.messages = queue.Queue()
        self.busy = False
        root.title("JDK Switcher · Linux")
        root.geometry("1100x760")
        root.minsize(880, 660)
        root.configure(background="#f3f5f9")
        style = ttk.Style(root)
        style.theme_use("clam")
        style.configure("TFrame", background="#f3f5f9")
        style.configure("TLabel", background="#f3f5f9", foreground="#263953", font=("sans-serif", 10))
        style.configure("Title.TLabel", font=("sans-serif", 23, "bold"), foreground="#172641")
        style.configure("TButton", padding=(14, 9))
        style.configure("Treeview", rowheight=36, font=("sans-serif", 10), background="white", fieldbackground="white")
        style.configure("Treeview.Heading", font=("sans-serif", 10, "bold"), padding=(10, 10))
        style.map("Treeview", background=[("selected", "#dce7ff")], foreground=[("selected", "#2049a9")])
        outer = ttk.Frame(root, padding=24)
        outer.pack(fill="both", expand=True)
        outer.columnconfigure(0, weight=1)
        outer.rowconfigure(3, weight=2)
        outer.rowconfigure(6, weight=1)
        ttk.Label(outer, text="Java 环境 · Linux", style="Title.TLabel").grid(row=0, column=0, sticky="w")
        ttk.Label(outer, text=f"{__version__}  /  当前用户 · Bash / Zsh · 本地运行 · 无遥测").grid(row=1, column=0, sticky="w", pady=(5, 16))
        tools = ttk.Frame(outer)
        tools.grid(row=2, column=0, sticky="ew", pady=(0, 10))
        self.current = ttk.Label(tools, text="读取已保存的配置…")
        self.current.pack(side="left")
        self.refresh_button = ttk.Button(tools, text="刷新扫描", command=self.scan)
        self.refresh_button.pack(side="right")
        self.add_button = ttk.Button(tools, text="添加目录", command=self.add)
        self.add_button.pack(side="right", padx=8)
        table = ttk.Frame(outer)
        table.grid(row=3, column=0, sticky="nsew")
        self.tree = ttk.Treeview(table, columns=("version", "vendor", "architecture", "home"), show="headings", selectmode="browse")
        for name, label, width in (("version", "版本", 130), ("vendor", "发行商", 180), ("architecture", "架构", 100), ("home", "安装目录", 450)):
            self.tree.heading(name, text=label)
            self.tree.column(name, width=width, minwidth=70, stretch=name == "home")
        scrollbar = ttk.Scrollbar(table, orient="vertical", command=self.tree.yview)
        self.tree.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        self.tree.pack(side="left", fill="both", expand=True)
        self.tree.bind("<<TreeviewSelect>>", lambda _: self.preview())
        options = ttk.Frame(outer)
        options.grid(row=4, column=0, sticky="ew", pady=14)
        ttk.Label(options, text="配置 Shell").pack(side="left", padx=(0, 10))
        self.shell = tk.StringVar(value=default_shell() or ("bash" if demo else ""))
        self.shell_box = ttk.Combobox(options, textvariable=self.shell, values=("bash", "zsh", "both"), state="readonly", width=12)
        self.shell_box.pack(side="left")
        self.shell_box.bind("<<ComboboxSelected>>", lambda _: self.preview())
        ttk.Label(options, text="保留原有配置，仅添加受标记的加载块；不修改系统 Java。").pack(side="left", padx=16)
        ttk.Label(outer, text="变更预览 · 确认前不写入文件").grid(row=5, column=0, sticky="w", pady=(0, 8))
        preview_frame = ttk.Frame(outer)
        preview_frame.grid(row=6, column=0, sticky="nsew")
        self.text = tk.Text(preview_frame, wrap="none", height=11, background="#eaf0fa", foreground="#314b72", borderwidth=0, padx=12, pady=10, font=("monospace", 10))
        preview_scroll = ttk.Scrollbar(preview_frame, command=self.text.yview)
        horizontal = ttk.Scrollbar(preview_frame, orient="horizontal", command=self.text.xview)
        self.text.configure(yscrollcommand=preview_scroll.set, xscrollcommand=horizontal.set)
        preview_scroll.pack(side="right", fill="y")
        horizontal.pack(side="bottom", fill="x")
        self.text.pack(fill="both", expand=True)
        self.show_text("选择一个 JDK 查看逐行变更；备份失败时不会修改环境。")
        actions = ttk.Frame(outer)
        actions.grid(row=7, column=0, sticky="ew", pady=(14, 0))
        self.apply_button = ttk.Button(actions, text="备份并一键切换", command=self.apply, state="disabled")
        self.apply_button.pack(side="left")
        self.restore_button = ttk.Button(actions, text="恢复备份", command=self.restore)
        self.restore_button.pack(side="left", padx=10)
        self.status = tk.StringVar(value="正在读取本地安装；不会执行 Java 程序。")
        ttk.Label(outer, textvariable=self.status, wraplength=1000).grid(row=8, column=0, sticky="w", pady=(12, 0))
        if demo:
            self.add_button.configure(state="disabled")
            self.restore_button.configure(state="disabled")
        root.after(80, self.scan)
        root.after(100, self.poll)

    def show_text(self, content: str):
        self.text.configure(state="normal")
        self.text.delete("1.0", "end")
        self.text.insert("1.0", content)
        self.text.configure(state="disabled")

    def invalidate(self):
        self.plan = None
        self.apply_button.configure(state="disabled", text="备份并一键切换")

    def scan(self):
        if self.busy:
            return
        self.invalidate()
        if self.demo:
            self.installations([
                Jdk("/opt/java/jdk-21", "21.0.6", "Eclipse Adoptium", "x86_64", 21),
                Jdk("/opt/java/jdk-17", "17.0.14", "Microsoft", "x86_64", 17)])
            self.current.configure(text="已保存：/opt/java/jdk-17（虚构演示）")
            return
        try:
            status = self.controller.status()
            self.current.configure(text="已保存：" + (status["saved_jdk"] or "尚未配置"))
        except (SafetyError, OSError) as error:
            self.status.set(str(error))
        self.busy = True
        self.refresh_button.configure(state="disabled")
        self.status.set("正在扫描本地候选目录…")

        def work():
            try:
                self.messages.put(("scan", discover(self.controller.home, tuple(self.extra))))
            except Exception as error:
                self.messages.put(("error", str(error)))
        threading.Thread(target=work, daemon=True).start()

    def poll(self):
        try:
            kind, value = self.messages.get_nowait()
            self.busy = False
            self.refresh_button.configure(state="normal")
            if kind == "scan":
                self.installations(value)
            else:
                self.status.set(value)
        except queue.Empty:
            pass
        self.root.after(100, self.poll)

    def installations(self, jdks):
        self.jdks = jdks
        self.tree.delete(*self.tree.get_children())
        for index, jdk in enumerate(jdks):
            self.tree.insert("", "end", iid=str(index), values=(jdk.version, jdk.vendor, jdk.architecture, jdk.home))
        self.status.set(f"发现 {len(jdks)} 个 JDK。选择安装目录并核对变更，已有终端需重新加载环境。")

    def preview(self):
        self.invalidate()
        selected = self.tree.selection()
        if not selected:
            return
        if self.demo:
            self.show_text("演示数据，不会写入：\n\n+ export JAVA_HOME=/opt/java/jdk-21\n+ 在保留原有条目的前提下，将目标 bin 放到 PATH 最前面\n+ 在所选 Shell 配置末尾添加受标记的加载块\n\n真实操作会展示所有受影响文件的完整逐行差异。")
            self.status.set("只读演示：所有路径均为虚构示例。")
            return
        try:
            self.plan = self.controller.plan_switch(self.jdks[int(selected[0])].home, self.shell.get())
            self.show_text(self.plan.diff())
            self.apply_button.configure(state="normal" if self.plan.changed else "disabled")
            self.status.set("确认后先备份再写入。仅影响当前用户，不需要 sudo。")
        except (SafetyError, OSError, ValueError) as error:
            self.show_text(str(error))
            self.status.set("无法安全切换，请核对以上提示。")

    def add(self):
        if self.busy:
            return
        path = filedialog.askdirectory(title="选择 Linux JDK 根目录")
        if path:
            try:
                jdk = inspect_jdk(path)
                self.extra.append(Path(jdk.home))
                self.scan()
            except (SafetyError, OSError, ValueError) as error:
                self.status.set(str(error))

    def apply(self):
        if self.demo or self.plan is None or self.busy:
            return
        plan = self.plan
        self.invalidate()
        try:
            backup = self.controller.apply(plan)
            saved = self.controller.status()["saved_jdk"]
            self.current.configure(text="已保存：" + (saved or "尚未配置"))
            self.status.set("完成，原始文件已备份。请重新打开终端；恢复后建议重新登录。")
            self.show_text("备份：" + str(backup) + "\n\n环境脚本：" + str(self.controller.env_file) + "\n\n不改写正在运行的终端、IDE，也不关闭任何进程。")
        except (SafetyError, OSError, ValueError) as error:
            self.show_text(str(error))
            self.status.set("操作未完成，请核对错误及备份提示。")

    def restore(self):
        if self.demo or self.busy:
            return
        self.invalidate()
        try:
            backups = self.controller.list_backups()
            if not backups:
                self.status.set("暂无备份。首次写入前会自动创建。")
                return
            name = filedialog.askopenfilename(title="选择本地备份", initialdir=str(self.controller.backups), filetypes=(("JDK 备份", "*.json"),))
            if not name:
                return
            selected = Path(name)
            if selected.parent != self.controller.backups:
                raise SafetyError("只能选择当前账户备份目录内的文件。")
            self.plan = self.controller.plan_restore(selected.name)
            self.show_text(self.plan.diff())
            self.apply_button.configure(text="备份并确认恢复", state="normal" if self.plan.changed else "disabled")
            self.status.set("核对恢复预览后再确认；外部改动的文件不会被覆盖。")
        except (SafetyError, OSError, ValueError) as error:
            self.show_text(str(error))


def run(demo: bool = False, smoke_test: bool = False) -> int:
    try:
        root = tk.Tk()
    except tk.TclError as error:
        raise SafetyError("无法连接桌面显示服务；可使用终端命令 list / preview / switch。") from error
    app = App(root, demo)
    if smoke_test:
        root.withdraw()
        root.update_idletasks()
        if demo:
            app.scan()
            app.tree.selection_set("0")
            app.preview()
            if str(app.apply_button.cget("state")) != "disabled":
                raise SafetyError("演示模式的写入按钮应保持禁用。")
        root.destroy()
        print("Linux desktop smoke test passed (read only).")
        return 0
    root.mainloop()
    return 0
