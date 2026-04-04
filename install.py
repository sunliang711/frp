#!/usr/bin/env python3
"""Install or uninstall frp manager, binaries, and systemd templates."""

from __future__ import annotations

import argparse
import shutil
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

import frp


PROJECT_DIR = Path(__file__).resolve().parent
DOWNLOAD_SCRIPT = PROJECT_DIR / "download.py"
MANAGER_SCRIPT = PROJECT_DIR / "frp.py"
INSTALLED_MANAGER = frp.BIN_DIR / "frp.py"


@dataclass(frozen=True)
class RollbackEntry:
    path: Path
    backup_path: Path | None
    backup_mode: str | None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="安装或卸载 frp、管理脚本和 systemd template。",
    )
    parser.add_argument(
        "command",
        nargs="?",
        choices=("install", "uninstall"),
        default="install",
        help="默认 install，也支持 uninstall。",
    )
    parser.add_argument(
        "-v",
        "--version",
        help="install 时指定 frp 版本，例如 0.68.0；不指定则下载最新版。",
    )
    return parser.parse_args()


def iter_known_units() -> list[str]:
    units: list[str] = []
    for spec in frp.SERVICE_SPECS.values():
        if not spec.config_dir.exists():
            continue
        for config_path in sorted(spec.config_dir.glob("*.toml")):
            units.append(spec.unit_name(config_path.stem))
    return units


def remove_path(path: Path) -> None:
    frp.run_command(["/bin/rm", "-f", str(path)], sudo=True, check=False)


def snapshot_path(path: Path, backup_dir: Path, index: int) -> tuple[Path | None, str | None]:
    if not path.exists():
        return None, None

    backup_path = backup_dir / f"{index:02d}-{path.name}"
    shutil.copy2(path, backup_path)
    backup_mode = f"{stat.S_IMODE(path.stat().st_mode):03o}"
    return backup_path, backup_mode


def install_file_with_rollback(
    src: Path,
    dest: Path,
    mode: str,
    backup_dir: Path,
    rollback_entries: list[RollbackEntry],
) -> None:
    backup_path, backup_mode = snapshot_path(dest, backup_dir, len(rollback_entries))
    frp.install_file(src, dest, mode)
    rollback_entries.append(RollbackEntry(dest, backup_path, backup_mode))


def install_text_with_rollback(
    dest: Path,
    content: str,
    mode: str,
    backup_dir: Path,
    rollback_entries: list[RollbackEntry],
) -> None:
    backup_path, backup_mode = snapshot_path(dest, backup_dir, len(rollback_entries))
    frp.install_text(dest, content, mode)
    rollback_entries.append(RollbackEntry(dest, backup_path, backup_mode))


def rollback_install(rollback_entries: list[RollbackEntry]) -> None:
    if not rollback_entries:
        return

    frp.LOGGER.warning("安装失败，开始回滚已写入的文件。")
    for entry in reversed(rollback_entries):
        try:
            if entry.backup_path is not None and entry.backup_mode is not None:
                frp.install_file(entry.backup_path, entry.path, entry.backup_mode)
            else:
                remove_path(entry.path)
        except Exception as exc:  # noqa: BLE001
            frp.LOGGER.warning("回滚失败: %s (%s)", entry.path, exc)

    frp.run_command(["systemctl", "daemon-reload"], sudo=True, check=False)


def cmd_install(args: argparse.Namespace) -> int:
    frp.require_linux_for_systemd()
    frp.ensure_project_layout()
    frp.ensure_command("systemctl")

    if not DOWNLOAD_SCRIPT.exists():
        raise frp.FrpError(f"未找到下载脚本: {DOWNLOAD_SCRIPT}")
    if not MANAGER_SCRIPT.exists():
        raise frp.FrpError(f"未找到管理脚本: {MANAGER_SCRIPT}")

    with tempfile.TemporaryDirectory(prefix="frp-install-") as tmp_dir:
        with tempfile.TemporaryDirectory(prefix="frp-install-backup-") as backup_tmp:
            rollback_entries: list[RollbackEntry] = []
            backup_dir = Path(backup_tmp)
            try:
                command = [
                    sys.executable,
                    str(DOWNLOAD_SCRIPT),
                    "frp",
                    "--extract",
                    "-o",
                    tmp_dir,
                ]
                if args.version:
                    command.extend(["--version", args.version.lstrip("v")])

                frp.LOGGER.info("开始下载 frp")
                frp.run_command(command, sudo=False)

                temp_root = Path(tmp_dir)
                frpc_src = frp.find_downloaded_binary(temp_root, "frpc")
                frps_src = frp.find_downloaded_binary(temp_root, "frps")
                frp.LOGGER.info("安装 frpc -> %s", frp.BIN_DIR / "frpc")
                install_file_with_rollback(
                    frpc_src,
                    frp.BIN_DIR / "frpc",
                    "755",
                    backup_dir,
                    rollback_entries,
                )
                frp.LOGGER.info("安装 frps -> %s", frp.BIN_DIR / "frps")
                install_file_with_rollback(
                    frps_src,
                    frp.BIN_DIR / "frps",
                    "755",
                    backup_dir,
                    rollback_entries,
                )

                frp.LOGGER.info("安装管理脚本 -> %s", INSTALLED_MANAGER)
                install_file_with_rollback(
                    MANAGER_SCRIPT,
                    INSTALLED_MANAGER,
                    "755",
                    backup_dir,
                    rollback_entries,
                )

                project_hint = frp.project_hint_path(INSTALLED_MANAGER)
                frp.LOGGER.info("写入项目路径 -> %s", project_hint)
                install_text_with_rollback(
                    project_hint,
                    f"{PROJECT_DIR}\n",
                    "644",
                    backup_dir,
                    rollback_entries,
                )

                for spec in frp.SERVICE_SPECS.values():
                    frp.LOGGER.info("写入 template -> %s", spec.unit_template_path)
                    install_text_with_rollback(
                        spec.unit_template_path,
                        frp.render_unit(spec),
                        "644",
                        backup_dir,
                        rollback_entries,
                    )

                frp.LOGGER.info("刷新 systemd 配置")
                frp.run_command(["systemctl", "daemon-reload"], sudo=True)
            except Exception:
                rollback_install(rollback_entries)
                raise

    frp.LOGGER.info("安装完成")
    frp.LOGGER.info("仓库目录: %s", PROJECT_DIR)
    frp.LOGGER.info("示例: /usr/local/bin/frp.py frpc add demo")
    return 0


def cmd_uninstall(args: argparse.Namespace) -> int:
    if args.version:
        raise frp.FrpError("uninstall 不支持 --version。")

    frp.require_linux_for_systemd()
    frp.ensure_command("systemctl")

    for unit_name in iter_known_units():
        frp.LOGGER.info("停用并停止实例: %s", unit_name)
        frp.run_command(["systemctl", "disable", "--now", unit_name], sudo=True, check=False)

    for spec in frp.SERVICE_SPECS.values():
        frp.LOGGER.info("删除 template: %s", spec.unit_template_path)
        remove_path(spec.unit_template_path)

    frp.LOGGER.info("删除二进制和管理脚本")
    remove_path(frp.BIN_DIR / "frpc")
    remove_path(frp.BIN_DIR / "frps")
    remove_path(INSTALLED_MANAGER)
    remove_path(frp.project_hint_path(INSTALLED_MANAGER))

    frp.LOGGER.info("刷新 systemd 配置")
    frp.run_command(["systemctl", "daemon-reload"], sudo=True, check=False)
    frp.LOGGER.info("卸载完成")
    frp.LOGGER.info("本地配置目录保留在: %s", PROJECT_DIR / "etc")
    return 0


def main() -> int:
    frp.configure_logging()
    args = parse_args()

    try:
        if args.command == "uninstall":
            return cmd_uninstall(args)
        return cmd_install(args)
    except KeyboardInterrupt:
        return 130
    except frp.FrpError as exc:
        frp.LOGGER.error("%s", exc)
        return 1
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
