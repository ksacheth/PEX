#!/usr/bin/env python3
from __future__ import annotations

import ctypes
import sys
import threading
import time
from pathlib import Path

try:
    import tkinter as tk
except ModuleNotFoundError:
    tk = None


ROOT_DIR = Path(__file__).resolve().parents[1]
LIBPEX_PATH = ROOT_DIR / "libpex" / "libpex.so"
ASSET_PATH = ROOT_DIR / "demo" / "assets" / "protected_image.enc.hex"
MAP_SIZE = 4096
IMAGE_SCALE = 14
XOR_KEY = b"PEX-DEMO-KEY"
PEX_POLICY_OWNER_THREAD_ONLY = 1


class PexHandle(ctypes.Structure):
    _fields_ = [
        ("fd", ctypes.c_int),
        ("ctx_id", ctypes.c_int),
        ("mapped_addr", ctypes.c_void_p),
        ("mapped_size", ctypes.c_size_t),
    ]


class PexCtxInfo(ctypes.Structure):
    _fields_ = [
        ("ctx_id", ctypes.c_int32),
        ("owner_tgid", ctypes.c_int32),
        ("owner_tid", ctypes.c_int32),
        ("active", ctypes.c_uint32),
        ("policy_flags", ctypes.c_uint32),
        ("size", ctypes.c_uint64),
        ("total_entries", ctypes.c_uint64),
        ("total_exits", ctypes.c_uint64),
        ("total_faults", ctypes.c_uint64),
        ("total_ns", ctypes.c_uint64),
    ]


class PexRuntime:
    def __init__(self, lib_path: Path, map_size: int) -> None:
        self._lib = ctypes.CDLL(str(lib_path))
        self._configure()
        self.map_size = map_size
        self.handle = PexHandle()
        self.handle.fd = -1
        self.handle.ctx_id = -1
        self.handle.mapped_addr = None
        self.handle.mapped_size = 0

    def _configure(self) -> None:
        self._lib.pex_open.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_open.restype = ctypes.c_int
        self._lib.pex_close.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_close.restype = None
        self._lib.pex_create.argtypes = [
            ctypes.POINTER(PexHandle),
            ctypes.c_char_p,
            ctypes.c_size_t,
            ctypes.c_uint32,
        ]
        self._lib.pex_create.restype = ctypes.c_int
        self._lib.pex_destroy.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_destroy.restype = ctypes.c_int
        self._lib.pex_enter.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_enter.restype = ctypes.c_int
        self._lib.pex_exit.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_exit.restype = ctypes.c_int
        self._lib.pex_get_info.argtypes = [ctypes.POINTER(PexHandle), ctypes.POINTER(PexCtxInfo)]
        self._lib.pex_get_info.restype = ctypes.c_int
        self._lib.pex_map.argtypes = [ctypes.POINTER(PexHandle), ctypes.c_size_t]
        self._lib.pex_map.restype = ctypes.c_void_p
        self._lib.pex_unmap.argtypes = [ctypes.POINTER(PexHandle)]
        self._lib.pex_unmap.restype = ctypes.c_int

    def open(self) -> None:
        rc = self._lib.pex_open(ctypes.byref(self.handle))
        if rc:
            raise RuntimeError(f"pex_open failed: {rc}")

    def create(self, name: str, policy_flags: int) -> None:
        rc = self._lib.pex_create(
            ctypes.byref(self.handle),
            name.encode("utf-8"),
            self.map_size,
            policy_flags,
        )
        if rc:
            raise RuntimeError(f"pex_create failed: {rc}")

    def map(self) -> int:
        addr = self._lib.pex_map(ctypes.byref(self.handle), self.map_size)
        if not addr:
            raise RuntimeError("pex_map failed")
        return int(addr)

    def enter(self) -> int:
        return int(self._lib.pex_enter(ctypes.byref(self.handle)))

    def exit(self) -> int:
        return int(self._lib.pex_exit(ctypes.byref(self.handle)))

    def get_info(self) -> PexCtxInfo:
        info = PexCtxInfo()
        rc = self._lib.pex_get_info(ctypes.byref(self.handle), ctypes.byref(info))
        if rc:
            raise RuntimeError(f"pex_get_info failed: {rc}")
        return info

    def destroy(self) -> int:
        if self.handle.ctx_id <= 0:
            return 0
        return int(self._lib.pex_destroy(ctypes.byref(self.handle)))

    def unmap(self) -> int:
        return int(self._lib.pex_unmap(ctypes.byref(self.handle)))

    def close(self) -> None:
        self._lib.pex_close(ctypes.byref(self.handle))


def xor_bytes(data: bytes, key: bytes) -> bytes:
    return bytes(byte ^ key[index % len(key)] for index, byte in enumerate(data))


def load_protected_ppm(asset_path: Path) -> bytes:
    hex_blob = "".join(line.strip() for line in asset_path.read_text(encoding="utf-8").splitlines())
    encrypted = bytes.fromhex(hex_blob)
    decrypted = xor_bytes(encrypted, XOR_KEY)
    if not decrypted.startswith(b"P3\n"):
        raise RuntimeError("decrypted asset is not a PPM image")
    if len(decrypted) > MAP_SIZE:
        raise RuntimeError("decrypted asset exceeds mapped PEX page")
    return decrypted


def generate_locked_placeholder(width: int = 16, height: int = 16) -> bytes:
    rows = []
    for y in range(height):
        for x in range(width):
            if (x + y) % 2 == 0:
                r, g, b = (20, 28, 46)
            else:
                r, g, b = (36, 42, 64)

            if 4 <= x <= 11 and 3 <= y <= 12:
                r, g, b = (132, 138, 156)
            if 5 <= x <= 10 and 7 <= y <= 12:
                r, g, b = (228, 184, 69)
            if 6 <= x <= 9 and 3 <= y <= 6 and (x in (6, 9) or y == 3):
                r, g, b = (228, 184, 69)
            if (x, y) in {(7, 9), (8, 9), (7, 10), (8, 10)}:
                r, g, b = (45, 50, 74)
            rows.append(f"{r} {g} {b}")
    ppm = f"P3\n{width} {height}\n255\n" + "\n".join(rows) + "\n"
    return ppm.encode("ascii")


def parse_ppm(ppm_bytes: bytes) -> tuple[int, int, list[tuple[int, int, int]]]:
    tokens = ppm_bytes.split()
    if len(tokens) < 4 or tokens[0] != b"P3":
        raise RuntimeError("PPM payload must be ASCII P3 data")

    width = int(tokens[1])
    height = int(tokens[2])
    max_value = int(tokens[3])
    if max_value != 255:
        raise RuntimeError(f"unsupported PPM max value: {max_value}")

    pixel_values = [int(token) for token in tokens[4:]]
    expected_values = width * height * 3
    if len(pixel_values) < expected_values:
        # Demo payloads may be truncated by a few channels; pad with the last RGB triplet.
        missing = expected_values - len(pixel_values)
        filler = pixel_values[-3:] if len(pixel_values) >= 3 else [0, 0, 0]
        repeats = (missing + 2) // 3
        pixel_values.extend((filler * repeats)[:missing])
    elif len(pixel_values) > expected_values:
        pixel_values = pixel_values[:expected_values]

    pixels = [tuple(pixel_values[index:index + 3]) for index in range(0, len(pixel_values), 3)]
    return width, height, pixels


def photo_from_ppm(root: tk.Tk, ppm_bytes: bytes, scale: int) -> tk.PhotoImage:
    width, height, pixels = parse_ppm(ppm_bytes)
    image = tk.PhotoImage(master=root, width=width, height=height)

    rows = []
    for y in range(height):
        row = []
        start = y * width
        for r, g, b in pixels[start:start + width]:
            row.append(f"#{r:02x}{g:02x}{b:02x}")
        rows.append("{" + " ".join(row) + "}")

    image.put(" ".join(rows))
    return image.zoom(scale, scale)


class PexViewerApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("PEX SofTEE Demo")
        self.root.configure(bg="#0f1726")
        self.root.geometry("980x680")

        if not LIBPEX_PATH.exists():
            raise RuntimeError(f"libpex shared object not found at {LIBPEX_PATH}")
        if not ASSET_PATH.exists():
            raise RuntimeError(f"encrypted asset not found at {ASSET_PATH}")

        self.runtime = PexRuntime(LIBPEX_PATH, MAP_SIZE)
        self.protected_image = load_protected_ppm(ASSET_PATH)
        self.placeholder_image = generate_locked_placeholder()
        self.display_buffer = bytearray()
        self.active = False
        self.mapped_addr = 0
        self.current_image: tk.PhotoImage | None = None

        self.status_var = tk.StringVar(value="Initializing PEX runtime...")
        self.ctx_var = tk.StringVar(value="Context: not created")
        self.entries_var = tk.StringVar(value="Entries: 0")
        self.exits_var = tk.StringVar(value="Exits: 0")
        self.faults_var = tk.StringVar(value="Context faults: 0")
        self.time_var = tk.StringVar(value="Protected time: 0 ns")
        self.global_var = tk.StringVar(value="Global stats: unavailable")
        self.proc_var = tk.StringVar(value="Proc line: unavailable")

        self._build_ui()
        self._bootstrap_runtime()
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)
        self.root.after(1000, self.periodic_refresh)

    def _build_ui(self) -> None:
        title = tk.Label(
            self.root,
            text="PEX SofTEE Protected Reveal Demo",
            font=("Georgia", 22, "bold"),
            fg="#f8fafc",
            bg="#0f1726",
        )
        title.pack(pady=(18, 6))

        subtitle = tk.Label(
            self.root,
            text="Kernel-enforced protected execution with real /dev/pex state, live counters, and thread policy faults",
            font=("Helvetica", 11),
            fg="#c7d2fe",
            bg="#0f1726",
        )
        subtitle.pack(pady=(0, 16))

        shell = tk.Frame(self.root, bg="#162033", bd=0, highlightthickness=0)
        shell.pack(fill="both", expand=True, padx=18, pady=(0, 18))

        left = tk.Frame(shell, bg="#162033")
        left.pack(side="left", fill="both", expand=True, padx=(0, 14))
        right = tk.Frame(shell, bg="#101827", width=320)
        right.pack(side="right", fill="y")
        right.pack_propagate(False)

        self.image_frame = tk.Frame(left, bg="#0b1120", highlightbackground="#355070", highlightthickness=1)
        self.image_frame.pack(fill="both", expand=True)

        self.image_label = tk.Label(
            self.image_frame,
            text="",
            bg="#0b1120",
            fg="#e2e8f0",
            compound="center",
        )
        self.image_label.pack(expand=True, padx=20, pady=20)

        controls = tk.Frame(left, bg="#162033")
        controls.pack(fill="x", pady=(14, 0))

        button_style = {
            "font": ("Helvetica", 11, "bold"),
            "bd": 0,
            "relief": "flat",
            "activeforeground": "#ffffff",
            "padx": 16,
            "pady": 10,
        }

        tk.Button(
            controls,
            text="Enter Protected Mode",
            command=self.enter_protected_mode,
            bg="#2563eb",
            fg="#ffffff",
            activebackground="#1d4ed8",
            **button_style,
        ).pack(side="left", padx=(0, 12))

        tk.Button(
            controls,
            text="Exit Protected Mode",
            command=self.exit_protected_mode,
            bg="#0f766e",
            fg="#ffffff",
            activebackground="#115e59",
            **button_style,
        ).pack(side="left", padx=(0, 12))

        tk.Button(
            controls,
            text="Rogue Thread Access",
            command=self.trigger_rogue_thread,
            bg="#b45309",
            fg="#ffffff",
            activebackground="#92400e",
            **button_style,
        ).pack(side="left")

        status_card = tk.Frame(right, bg="#111c2d", highlightbackground="#2f4463", highlightthickness=1)
        status_card.pack(fill="x", padx=12, pady=(12, 10))

        tk.Label(
            status_card,
            text="Runtime Status",
            font=("Georgia", 16, "bold"),
            fg="#f8fafc",
            bg="#111c2d",
        ).pack(anchor="w", padx=14, pady=(12, 8))

        for variable in (
            self.ctx_var,
            self.entries_var,
            self.exits_var,
            self.faults_var,
            self.time_var,
            self.global_var,
            self.proc_var,
        ):
            tk.Label(
                status_card,
                textvariable=variable,
                font=("Courier", 10),
                fg="#dbeafe",
                bg="#111c2d",
                justify="left",
                wraplength=280,
                anchor="w",
            ).pack(fill="x", padx=14, pady=2)

        status_banner = tk.Label(
            right,
            textvariable=self.status_var,
            font=("Helvetica", 11, "bold"),
            fg="#fef3c7",
            bg="#7c2d12",
            justify="left",
            wraplength=280,
            padx=14,
            pady=12,
        )
        status_banner.pack(fill="x", padx=12, pady=(0, 10))

        log_card = tk.Frame(right, bg="#111c2d", highlightbackground="#2f4463", highlightthickness=1)
        log_card.pack(fill="both", expand=True, padx=12, pady=(0, 12))

        tk.Label(
            log_card,
            text="Event Log",
            font=("Georgia", 16, "bold"),
            fg="#f8fafc",
            bg="#111c2d",
        ).pack(anchor="w", padx=14, pady=(12, 8))

        self.log_widget = tk.Text(
            log_card,
            height=14,
            wrap="word",
            bg="#0b1120",
            fg="#dbeafe",
            insertbackground="#dbeafe",
            relief="flat",
            font=("Courier", 10),
            padx=12,
            pady=12,
        )
        self.log_widget.pack(fill="both", expand=True, padx=12, pady=(0, 12))
        self.log_widget.configure(state="disabled")

    def _bootstrap_runtime(self) -> None:
        self.runtime.open()
        self.runtime.create("viewer_ctx", PEX_POLICY_OWNER_THREAD_ONLY)
        self.mapped_addr = self.runtime.map()
        self.log("Created viewer_ctx and mapped a single protected page.")
        self.set_placeholder()
        self.refresh_stats()

    def log(self, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        self.log_widget.configure(state="normal")
        self.log_widget.insert("end", f"[{timestamp}] {message}\n")
        self.log_widget.see("end")
        self.log_widget.configure(state="disabled")

    def set_image(self, ppm_bytes: bytes, locked: bool) -> None:
        image = photo_from_ppm(self.root, ppm_bytes, IMAGE_SCALE)
        self.current_image = image
        self.image_label.configure(
            image=image,
            text="LOCKED" if locked else "",
            fg="#fef2f2" if locked else "#e2e8f0",
            font=("Helvetica", 22, "bold"),
        )

    def set_placeholder(self) -> None:
        self.set_image(self.placeholder_image, locked=True)

    def _wipe_display_buffer(self) -> None:
        for index in range(len(self.display_buffer)):
            self.display_buffer[index] = 0
        self.display_buffer = bytearray()

    def _wipe_protected_buffer(self) -> None:
        if self.mapped_addr:
            ctypes.memset(self.mapped_addr, 0, MAP_SIZE)

    def enter_protected_mode(self) -> None:
        if self.active:
            self.status_var.set("Context is already active.")
            return

        rc = self.runtime.enter()
        if rc:
            self.status_var.set(f"pex_enter failed with rc={rc}")
            self.log(f"Enter request failed with rc={rc}.")
            self.refresh_stats()
            return

        ctypes.memmove(self.mapped_addr, self.protected_image, len(self.protected_image))
        copied = ctypes.string_at(self.mapped_addr, len(self.protected_image))
        self.display_buffer = bytearray(copied)
        self.active = True
        self.set_image(bytes(self.display_buffer), locked=False)
        self.status_var.set("Protected image is visible. Memory access is enabled for the owner thread.")
        self.log("Entered protected mode, decrypted the PPM payload, and rendered the protected image.")
        self.refresh_stats()

    def exit_protected_mode(self) -> None:
        if not self.active:
            self.status_var.set("Context is already inactive.")
            self.set_placeholder()
            self.refresh_stats()
            return

        self._wipe_protected_buffer()
        rc = self.runtime.exit()
        if rc:
            self.status_var.set(f"pex_exit failed with rc={rc}")
            self.log(f"Exit request failed with rc={rc}.")
            self.refresh_stats()
            return

        self._wipe_display_buffer()
        self.active = False
        self.set_placeholder()
        self.status_var.set("Protected mode exited. The image is locked again and the protected page is inaccessible.")
        self.log("Exited protected mode, zeroized the protected page, and restored the locked placeholder.")
        self.refresh_stats()

    def trigger_rogue_thread(self) -> None:
        result: dict[str, int] = {"rc": 0}

        def worker() -> None:
            result["rc"] = self.runtime.enter()

        thread = threading.Thread(target=worker, name="rogue-thread")
        thread.start()
        thread.join()

        rc = result["rc"]
        if rc < 0:
            self.status_var.set(f"Rogue thread denied with rc={rc}. Fault counter should increase.")
            self.log(f"Secondary thread attempted pex_enter and was denied with rc={rc}.")
        else:
            self.status_var.set(f"Unexpected rogue thread result rc={rc}.")
            self.log(f"Unexpected rogue-thread result rc={rc}; policy enforcement needs investigation.")
        self.refresh_stats()

    def read_proc_stats(self) -> tuple[dict[str, str], list[str]]:
        summary: dict[str, str] = {}
        lines: list[str] = []
        proc_path = Path("/proc/pex_stats")

        if not proc_path.exists():
            return summary, lines

        for raw in proc_path.read_text(encoding="utf-8").splitlines():
            if raw.startswith("ctx="):
                lines.append(raw)
                continue
            if "=" in raw:
                key, value = raw.split("=", 1)
                summary[key] = value
        return summary, lines

    def refresh_stats(self) -> None:
        info = self.runtime.get_info()
        summary, ctx_lines = self.read_proc_stats()

        self.ctx_var.set(
            f"Context: id={info.ctx_id} active={info.active} owner={info.owner_tgid}:{info.owner_tid}"
        )
        self.entries_var.set(f"Entries: {info.total_entries}")
        self.exits_var.set(f"Exits: {info.total_exits}")
        self.faults_var.set(f"Context faults: {info.total_faults}")
        self.time_var.set(f"Protected time: {info.total_ns} ns")
        self.global_var.set(
            "Global stats: "
            f"live={summary.get('live_contexts', '?')} "
            f"active={summary.get('active_contexts', '?')} "
            f"faults={summary.get('total_faults', '?')}"
        )

        current_line = "Proc line: unavailable"
        for line in ctx_lines:
            if f"ctx={info.ctx_id} " in line:
                current_line = f"Proc line: {line}"
                break
        self.proc_var.set(current_line)

    def periodic_refresh(self) -> None:
        try:
            self.refresh_stats()
        except Exception as exc:  # noqa: BLE001
            self.status_var.set(f"Periodic refresh failed: {exc}")
        self.root.after(1000, self.periodic_refresh)

    def on_close(self) -> None:
        try:
            if self.active:
                self._wipe_protected_buffer()
                rc = self.runtime.exit()
                if rc:
                    self.log(f"Close handler saw pex_exit rc={rc}.")
                self.active = False
            self._wipe_display_buffer()
            self.runtime.unmap()
            destroy_rc = self.runtime.destroy()
            if destroy_rc:
                self.log(f"pex_destroy returned rc={destroy_rc}.")
            self.runtime.close()
        finally:
            self.root.destroy()


def run_self_check() -> None:
    runtime = PexRuntime(LIBPEX_PATH, MAP_SIZE)
    protected_image = load_protected_ppm(ASSET_PATH)
    print("[self-check] opening /dev/pex")
    runtime.open()
    try:
        runtime.create("viewer_self_check", PEX_POLICY_OWNER_THREAD_ONLY)
        mapped_addr = runtime.map()
        before = runtime.get_info()
        print(
            f"[self-check] ctx={before.ctx_id} active={before.active} "
            f"faults={before.total_faults}"
        )

        rc = runtime.enter()
        if rc:
            raise RuntimeError(f"pex_enter failed: {rc}")

        ctypes.memmove(mapped_addr, protected_image, len(protected_image))
        revealed = ctypes.string_at(mapped_addr, len(protected_image))
        print(f"[self-check] revealed_bytes={len(revealed)} header={revealed[:11]!r}")

        result: dict[str, int] = {"rc": 0}

        def worker() -> None:
            result["rc"] = runtime.enter()

        thread = threading.Thread(target=worker, name="rogue-thread")
        thread.start()
        thread.join()

        after_thread = runtime.get_info()
        print(
            f"[self-check] rogue_thread_rc={result['rc']} "
            f"faults_after={after_thread.total_faults}"
        )
        if result["rc"] >= 0:
            raise RuntimeError("rogue thread unexpectedly entered the context")
        if after_thread.total_faults <= before.total_faults:
            raise RuntimeError("fault counter did not increase after rogue-thread attempt")

        ctypes.memset(mapped_addr, 0, MAP_SIZE)
        rc = runtime.exit()
        if rc:
            raise RuntimeError(f"pex_exit failed: {rc}")

        after_exit = runtime.get_info()
        print(
            f"[self-check] after_exit active={after_exit.active} "
            f"entries={after_exit.total_entries} exits={after_exit.total_exits}"
        )
    finally:
        runtime.unmap()
        destroy_rc = runtime.destroy()
        if destroy_rc:
            print(f"[self-check] destroy_rc={destroy_rc}")
        runtime.close()


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-check":
        try:
            run_self_check()
            return
        except Exception as exc:  # noqa: BLE001
            raise SystemExit(
                "PEX viewer self-check failed: "
                f"{exc}\nMake sure pex.ko is loaded and /dev/pex exists via scripts/dev_setup.sh."
            )

    if tk is None:
        raise SystemExit(
            "PEX viewer startup failed: tkinter is not installed.\n"
            "Install it with: sudo apt install python3-tk"
        )

    try:
        root = tk.Tk()
        app = PexViewerApp(root)
        app.log("Viewer ready. Use Enter Protected Mode to reveal the protected PPM asset.")
        root.mainloop()
    except Exception as exc:  # noqa: BLE001
        raise SystemExit(
            "PEX viewer startup failed: "
            f"{exc}\nMake sure libpex is built and /dev/pex is ready via scripts/dev_setup.sh."
        )


if __name__ == "__main__":
    main()
