# frp Systemd Template Manager

使用 Python 标准库实现的 frp 安装与管理脚本。

这个项目解决两件事：

1. 用 [download.py](download.py) 下载并安装 `frpc` / `frps` 到 `/usr/local/bin`
2. 用 systemd template 方式管理多个 `frpc` / `frps` 实例

对应的 systemd 用法是：

```bash
systemctl start frpc@office.service
systemctl start frps@main.service
```

项目内配置文件放在仓库自己的 `etc` 目录中：

```text
etc/
  frpc/
    office.toml
  frps/
    main.toml
```

`etc/` 属于本地运行时目录，已加入 `.gitignore`，不会纳入版本管理。

## 特点

- 仅使用 Python 标准库
- `frpc` 和 `frps` 都支持 `add`、`config`、`start`、`stop`、`restart`、`enable`、`disable`、`status`、`log`、`remove`
- 所有子命令都会输出简洁的标准库 `logging` 日志，说明当前动作
- `add` 创建配置后会自动执行 `systemctl enable ...`
- `start` 只执行 `systemctl start ...`
- `log` 使用 `journalctl -f`，按 `Ctrl+C` 退出时不会打印 Python traceback
- 配置和实例名直接映射到 systemd template

## 环境要求

- Linux
- systemd
- Python 3.9+
- `sudo`
- `systemctl`
- `journalctl`
- `install`

## 安装

在仓库目录执行：

```bash
python3 install.py
```

显式写法：

```bash
python3 install.py install
```

指定 frp 版本：

```bash
python3 install.py install --version 0.68.0
```

卸载已安装内容：

```bash
python3 install.py uninstall
```

安装完成后会写入：

- `/usr/local/bin/frpc`
- `/usr/local/bin/frps`
- `/usr/local/bin/frp.py`
- `/usr/local/bin/frp.py.project`
- `/etc/systemd/system/frpc@.service`
- `/etc/systemd/system/frps@.service`

其中 `/usr/local/bin/frp.py.project` 用来记录仓库绝对路径，让安装后的 `frp.py` 仍然使用仓库里的 `etc` 目录。
`etc/` 目录会在以下时机自动创建：

- 执行 `python3 install.py`
- 执行 `/usr/local/bin/frp.py frpc add ...`
- 执行 `/usr/local/bin/frp.py frps add ...`

## 配置

创建一个 `frpc` 客户端实例：

```bash
/usr/local/bin/frp.py frpc add office
```

创建一个 `frps` 服务端实例：

```bash
/usr/local/bin/frp.py frps add main
```

创建后会自动打开编辑器：

- 优先使用 `$EDITOR`
- 否则回退到 `nvim` / `vim` / `vi`

默认配置文件位置：

- `etc/frpc/<name>.toml`
- `etc/frps/<name>.toml`

## 用法

### frpc

```bash
/usr/local/bin/frp.py frpc add office
/usr/local/bin/frp.py frpc config office
/usr/local/bin/frp.py frpc start office
/usr/local/bin/frp.py frpc enable office
/usr/local/bin/frp.py frpc disable office
/usr/local/bin/frp.py frpc stop office
/usr/local/bin/frp.py frpc restart office
/usr/local/bin/frp.py frpc status office
/usr/local/bin/frp.py frpc log office
/usr/local/bin/frp.py frpc remove office
/usr/local/bin/frp.py frpc list
```

### frps

```bash
/usr/local/bin/frp.py frps add main
/usr/local/bin/frp.py frps config main
/usr/local/bin/frp.py frps start main
/usr/local/bin/frp.py frps enable main
/usr/local/bin/frp.py frps disable main
/usr/local/bin/frp.py frps stop main
/usr/local/bin/frp.py frps restart main
/usr/local/bin/frp.py frps status main
/usr/local/bin/frp.py frps log main
/usr/local/bin/frp.py frps remove main
/usr/local/bin/frp.py frps list
```

## 行为说明

- `start` 会执行 `systemctl start`
- `enable` 会执行 `systemctl enable`
- `disable` 会执行 `systemctl disable`
- `add` 会执行 `systemctl enable`，只设置开机自启，不立即启动
- `config` 编辑完成后，如果实例正在运行且配置内容发生变化，会自动重启
- `remove` 会执行 `systemctl disable --now`，然后删除对应 TOML 配置
- `log` 会跟随查看 unit 日志
- `uninstall` 会删除已安装的二进制、管理脚本和 template unit，但默认保留仓库里的 `etc/` 配置

## 注意事项

- 安装后的 `frp.py` 依赖仓库路径记录文件来定位项目 `etc` 目录
- 如果你移动了仓库目录，需要重新执行一次 `python3 install.py`
- systemd template 使用的是 `%i.toml`，实例名建议保持简单，例如 `main`、`office`、`ssh`

## 建议

- 如果你经常使用这个工具，可以后续再加一个不带 `.py` 的启动别名，例如 `/usr/local/bin/frp`
- 如果实例越来越多，可以再补一个 `doctor` 子命令，用来检查二进制、template、配置文件和 unit 状态
- 如果你担心误删配置，可以给 `remove` 增加归档备份目录
