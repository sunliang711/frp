#!/usr/bin/env python3
"""frp systemd template manager.

Manage template-based systemd instances whose configs live in the project's
`etc` directory.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


DEFAULT_FRPC_CONFIG = """serverAddr = "127.0.0.1"
serverPort = 7000

# auth.method = "token"
# auth.token = "change-me"

[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6000
"""

DEFAULT_FRPS_CONFIG = """bindPort = 7000

# auth.method = "token"
# auth.token = "change-me"

# webServer.addr = "0.0.0.0"
# webServer.port = 7500
# webServer.user = "admin"
# webServer.password = "admin"
"""


class FrpError(RuntimeError):
    """User-facing command error."""


LOGGER = logging.getLogger("frp")


def configure_logging() -> None:
    if getattr(configure_logging, "_configured", False):
        return
    logging.basicConfig(level=logging.INFO, format="[%(levelname)s] %(message)s")
    configure_logging._configured = True


def project_hint_path(script_path: Path | None = None) -> Path:
    script_path = script_path or Path(__file__).resolve()
    return script_path.with_name(f"{script_path.name}.project")


def resolve_project_dir(script_path: Path | None = None) -> Path:
    env_path = os.environ.get("FRP_PROJECT_DIR")
    if env_path:
        return Path(env_path).expanduser().resolve()

    script_path = script_path or Path(__file__).resolve()
    hint_path = project_hint_path(script_path)
    if hint_path.exists():
        project_path = hint_path.read_text(encoding="utf-8").strip()
        if project_path:
            return Path(project_path).expanduser().resolve()

    return script_path.parent


PROJECT_DIR = resolve_project_dir()
ETC_DIR = PROJECT_DIR / "etc"
DEFAULT_CONFIG_DIR = ETC_DIR / "defaults"
SYSTEMD_DIR = Path("/etc/systemd/system")
BIN_DIR = Path("/usr/local/bin")
VALID_INSTANCE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


@dataclass(frozen=True)
class ServiceSpec:
    name: str
    binary_name: str
    config_dir: Path
    restart_policy: str
    default_config: str

    @property
    def binary_path(self) -> Path:
        return BIN_DIR / self.binary_name

    @property
    def unit_template_path(self) -> Path:
        return SYSTEMD_DIR / f"{self.name}@.service"

    def config_path(self, instance: str) -> Path:
        return self.config_dir / f"{instance}.toml"

    @property
    def default_template_path(self) -> Path:
        return DEFAULT_CONFIG_DIR / f"{self.name}.toml"

    def unit_name(self, instance: str) -> str:
        return f"{self.name}@{instance}.service"


SERVICE_SPECS = {
    "frpc": ServiceSpec(
        name="frpc",
        binary_name="frpc",
        config_dir=ETC_DIR / "frpc",
        restart_policy="always",
        default_config=DEFAULT_FRPC_CONFIG,
    ),
    "frps": ServiceSpec(
        name="frps",
        binary_name="frps",
        config_dir=ETC_DIR / "frps",
        restart_policy="on-failure",
        default_config=DEFAULT_FRPS_CONFIG,
    ),
}


def require_linux_for_systemd() -> None:
    if sys.platform != "linux":
        raise FrpError("该命令需要在 Linux + systemd 环境下运行。")


def ensure_command(name: str) -> None:
    if shutil.which(name) is None:
        raise FrpError(f"缺少命令: {name}")


def ensure_instance_name(name: str) -> str:
    if not VALID_INSTANCE_RE.fullmatch(name):
        raise argparse.ArgumentTypeError(
            "实例名只允许字母、数字、点、下划线、短横线，且必须以字母或数字开头。"
        )
    return name


def ensure_project_layout() -> None:
    DEFAULT_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    for spec in SERVICE_SPECS.values():
        spec.config_dir.mkdir(parents=True, exist_ok=True)


def choose_editor() -> list[str]:
    editor = os.environ.get("EDITOR")
    if editor:
        parts = shlex.split(editor)
        if parts:
            return parts

    for name in ("nvim", "vim", "vi"):
        path = shutil.which(name)
        if path:
            return [path]

    raise FrpError("没有找到可用编辑器，请先设置 EDITOR 环境变量。")


def run_command(
    args: list[str],
    *,
    sudo: bool = False,
    check: bool = True,
    capture_output: bool = False,
) -> subprocess.CompletedProcess[str]:
    command = list(args)
    if sudo and os.geteuid() != 0:
        ensure_command("sudo")
        command = ["sudo", *command]

    return subprocess.run(
        command,
        check=check,
        text=True,
        capture_output=capture_output,
    )


def systemd_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def install_file(src: Path, dest: Path, mode: str) -> None:
    ensure_command("install")
    run_command(["install", "-m", mode, str(src), str(dest)], sudo=True)


def install_text(dest: Path, content: str, mode: str) -> None:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
        handle.write(content)
        tmp_path = Path(handle.name)
    try:
        install_file(tmp_path, dest, mode)
    finally:
        tmp_path.unlink(missing_ok=True)


def read_config_bytes(path: Path) -> bytes:
    return path.read_bytes() if path.exists() else b""


def is_systemd_active(unit_name: str) -> bool:
    if sys.platform != "linux" or shutil.which("systemctl") is None:
        return False

    result = run_command(
        ["systemctl", "is-active", "--quiet", unit_name],
        sudo=False,
        check=False,
    )
    return result.returncode == 0


def edit_file(path: Path) -> None:
    editor = choose_editor()
    run_command([*editor, str(path)], sudo=False)


def render_unit(spec: ServiceSpec) -> str:
    working_dir = systemd_quote(str(spec.config_dir))
    config_path = systemd_quote(str(spec.config_dir / "%i.toml"))
    return f"""[Unit]
Description={spec.name} instance %i
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory={working_dir}
ExecStart={spec.binary_path} -c {config_path}
Restart={spec.restart_policy}
RestartSec=5s

[Install]
WantedBy=multi-user.target
"""


def find_downloaded_file(root: Path, filename: str) -> Path:
    for path in root.rglob(filename):
        if path.is_file():
            return path
    raise FrpError(f"没有在下载结果中找到 {filename}")


def find_downloaded_binary(root: Path, binary_name: str) -> Path:
    for path in root.rglob(binary_name):
        if path.is_file() and os.access(path, os.X_OK):
            return path
    raise FrpError(f"没有在下载结果中找到 {binary_name}")


def require_installed_template(spec: ServiceSpec) -> None:
    require_linux_for_systemd()
    if not spec.unit_template_path.exists():
        raise FrpError(
            f"未找到 {spec.unit_template_path}，请先执行 `python3 install.py`。"
        )


def get_spec(service_name: str) -> ServiceSpec:
    return SERVICE_SPECS[service_name]


def require_config(spec: ServiceSpec, instance: str) -> Path:
    config_path = spec.config_path(instance)
    if not config_path.exists():
        raise FrpError(f"配置不存在: {config_path}")
    return config_path


def get_default_config(spec: ServiceSpec) -> tuple[str, Path | None]:
    template_path = spec.default_template_path
    if template_path.exists():
        return template_path.read_text(encoding="utf-8"), template_path
    return spec.default_config, None


def cmd_add(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    ensure_project_layout()
    config_path = spec.config_path(args.name)
    if config_path.exists():
        raise FrpError(f"配置已存在: {config_path}")

    default_config, template_path = get_default_config(spec)
    config_path.write_text(default_config, encoding="utf-8")
    LOGGER.info("创建配置: %s", config_path)
    if template_path is not None:
        LOGGER.info("使用默认模板: %s", template_path)
    else:
        LOGGER.info("默认模板缺失，回退到内置模板: %s", spec.name)
    LOGGER.info("打开编辑器: %s", config_path)
    edit_file(config_path)
    LOGGER.info("启用实例开机自启: %s", spec.unit_name(args.name))
    run_command(["systemctl", "enable", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_config(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    config_path = require_config(spec, args.name)
    LOGGER.info("编辑配置: %s", config_path)
    before = read_config_bytes(config_path)
    edit_file(config_path)
    after = read_config_bytes(config_path)

    if before != after and is_systemd_active(spec.unit_name(args.name)):
        LOGGER.info("配置已变更，重启实例: %s", spec.unit_name(args.name))
        run_command(["systemctl", "restart", spec.unit_name(args.name)], sudo=True)
    elif before == after:
        LOGGER.info("配置未变化: %s", config_path)

    return 0


def cmd_start(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("启动实例: %s", spec.unit_name(args.name))
    run_command(["systemctl", "start", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_enable(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("启用实例开机自启: %s", spec.unit_name(args.name))
    run_command(["systemctl", "enable", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_disable(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("禁用实例开机自启: %s", spec.unit_name(args.name))
    run_command(["systemctl", "disable", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_stop(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("停止实例: %s", spec.unit_name(args.name))
    run_command(["systemctl", "stop", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_restart(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("重启实例: %s", spec.unit_name(args.name))
    run_command(["systemctl", "restart", spec.unit_name(args.name)], sudo=True)
    return 0


def cmd_log(args: argparse.Namespace) -> int:
    require_linux_for_systemd()
    ensure_command("journalctl")
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("跟随日志: %s", spec.unit_name(args.name))
    run_command(["journalctl", "-u", spec.unit_name(args.name), "-f"], sudo=True)
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    config_path = require_config(spec, args.name)
    unit_name = spec.unit_name(args.name)

    LOGGER.info("禁用并停止实例: %s", unit_name)
    run_command(["systemctl", "disable", "--now", unit_name], sudo=True, check=False)
    LOGGER.info("删除配置: %s", config_path)
    config_path.unlink()
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    ensure_project_layout()
    LOGGER.info("列出配置目录: %s", spec.config_dir)

    configs = sorted(spec.config_dir.glob("*.toml"))
    for config in configs:
        print(config.stem)
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    spec = get_spec(args.service)
    require_installed_template(spec)
    require_config(spec, args.name)

    LOGGER.info("查看状态: %s", spec.unit_name(args.name))
    run_command(["systemctl", "status", spec.unit_name(args.name)], sudo=True)
    return 0


def add_name_argument(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("name", type=ensure_instance_name, help="实例名，例如: main / ssh")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="使用 systemd template 管理 frpc / frps。",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    for service_name in sorted(SERVICE_SPECS):
        service_parser = subparsers.add_parser(service_name, help=f"管理 {service_name} 实例")
        service_parser.set_defaults(service=service_name)
        actions = service_parser.add_subparsers(dest="action", required=True)

        add_parser = actions.add_parser("add", help="创建实例配置、打开编辑器并 enable")
        add_name_argument(add_parser)
        add_parser.set_defaults(func=cmd_add)

        config_parser = actions.add_parser("config", help="编辑实例配置")
        add_name_argument(config_parser)
        config_parser.set_defaults(func=cmd_config)

        start_parser = actions.add_parser("start", help="启动实例")
        add_name_argument(start_parser)
        start_parser.set_defaults(func=cmd_start)

        enable_parser = actions.add_parser("enable", help="启用实例开机自启")
        add_name_argument(enable_parser)
        enable_parser.set_defaults(func=cmd_enable)

        disable_parser = actions.add_parser("disable", help="禁用实例开机自启")
        add_name_argument(disable_parser)
        disable_parser.set_defaults(func=cmd_disable)

        stop_parser = actions.add_parser("stop", help="停止实例")
        add_name_argument(stop_parser)
        stop_parser.set_defaults(func=cmd_stop)

        restart_parser = actions.add_parser("restart", help="重启实例")
        add_name_argument(restart_parser)
        restart_parser.set_defaults(func=cmd_restart)

        log_parser = actions.add_parser("log", help="跟随日志输出")
        add_name_argument(log_parser)
        log_parser.set_defaults(func=cmd_log)

        remove_parser = actions.add_parser(
            "remove",
            aliases=["rm"],
            help="禁用实例并删除配置",
        )
        add_name_argument(remove_parser)
        remove_parser.set_defaults(func=cmd_remove)

        list_parser = actions.add_parser("list", help="列出已有配置")
        list_parser.set_defaults(func=cmd_list)

        status_parser = actions.add_parser("status", help="查看实例状态")
        add_name_argument(status_parser)
        status_parser.set_defaults(func=cmd_status)

    return parser


def main() -> int:
    configure_logging()
    parser = build_parser()
    args = parser.parse_args()

    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except FrpError as exc:
        LOGGER.error("%s", exc)
        return 1
    except subprocess.CalledProcessError as exc:
        return exc.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
