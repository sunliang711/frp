#!/bin/bash

if [ -z "${BASH_SOURCE}" ]; then
    this=${PWD}
else
    rpath="$(readlink ${BASH_SOURCE})"
    if [ -z "$rpath" ]; then
        rpath=${BASH_SOURCE}
    elif echo "$rpath" | grep -q '^/'; then
        # absolute path
        echo
    else
        # relative path
        rpath="$(dirname ${BASH_SOURCE})/$rpath"
    fi
    this="$(cd $(dirname $rpath) && pwd)"
fi

user="${SUDO_USER:-$(whoami)}"
home="$(eval echo ~$user)"

# 定义颜色
# Use colors, but only if connected to a terminal(-t 1), and that terminal supports them(ncolors >=8.
if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors 2>/dev/null)
fi
if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    # 品红色
    MAGENTA=$(tput setaf 5)
    # 青色
    CYAN="$(tput setaf 6)"
    # 粗体
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    BLUE=""
    BOLD=""
    NORMAL=""
fi

# 日志级别常量
LOG_LEVEL_FATAL=1
LOG_LEVEL_ERROR=2
LOG_LEVEL_WARNING=3
LOG_LEVEL_SUCCESS=4
LOG_LEVEL_INFO=5
LOG_LEVEL_DEBUG=6

# 默认日志级别
LOG_LEVEL=$LOG_LEVEL_INFO

# 导出 PATH 环境变量
export PATH=$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

err_require_command=100
err_require_root=200
err_require_linux=300
err_create_dir=400

_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

_require_command() {
    if ! _command_exists "$1"; then
        echo "Require command $1" 1>&2
        exit ${err_require_command}
    fi
}

_require_commands() {
    errorNo=0
    for i in "$@";do
        if ! _command_exists "$i"; then
            echo "need command $i" 1>&2
            errorNo=$((errorNo+1))
        fi
    done

    if ((errorNo > 0 ));then
        exit ${err_require_command}
    fi
}

function _ensureDir() {
    local dirs=$@
    for dir in ${dirs}; do
        if [ ! -d ${dir} ]; then
            mkdir -p ${dir} || {
                echo "create $dir failed!"
                exit $err_create_dir
            }
        fi
    done
}

rootID=0

function _root() {
    if [ ${EUID} -ne ${rootID} ]; then
        echo "need root privilege." 1>&2
        return $err_require_root
    fi
}

function _require_root() {
    if ! _root; then
        exit $err_require_root
    fi
}

function _linux() {
    if [ "$(uname)" != "Linux" ]; then
        echo "need Linux" 1>&2
        return $err_require_linux
    fi
}

function _require_linux() {
    if ! _linux; then
        exit $err_require_linux
    fi
}

function _wait() {
    # secs=$((5 * 60))
    secs=${1:?'missing seconds'}

    while [ $secs -gt 0 ]; do
        echo -ne "$secs\033[0K\r"
        sleep 1
        : $((secs--))
    done
    echo -ne "\033[0K\r"
}

function _parseOptions() {
    if [ $(uname) != "Linux" ]; then
        echo "getopt only on Linux"
        exit 1
    fi

    options=$(getopt -o dv --long debug --long name: -- "$@")
    [ $? -eq 0 ] || {
        echo "Incorrect option provided"
        exit 1
    }
    eval set -- "$options"
    while true; do
        case "$1" in
        -v)
            VERBOSE=1
            ;;
        -d)
            DEBUG=1
            ;;
        --debug)
            DEBUG=1
            ;;
        --name)
            shift # The arg is next in position args
            NAME=$1
            ;;
        --)
            shift
            break
            ;;
        esac
        shift
    done
}

# 设置ed
ed=vi
if _command_exists vim; then
    ed=vim
fi
if _command_exists nvim; then
    ed=nvim
fi
# use ENV: editor to override
if [ -n "${editor}" ]; then
    ed=${editor}
fi

rootID=0
_checkRoot() {
    if [ "$(id -u)" -ne 0 ]; then
        # 检查是否有 sudo 命令
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: 'sudo' command is required." >&2
            return 1
        fi

        # 检查用户是否在 sudoers 中
        echo "Checking if you have sudo privileges..."
        if ! sudo -v 2>/dev/null; then
            echo "You do NOT have sudo privileges or failed to enter password." >&2
            return 1
        fi
    fi
}

_runAsRoot() {
    if [ "$(id -u)" -eq 0 ]; then
        echo "Running as root: $*"
        "$@"
    else
        if ! command -v sudo >/dev/null 2>&1; then
            echo "Error: 'sudo' is required but not found." >&2
            return 1
        fi
        echo "Using sudo: $*"
        sudo "$@"
    fi
}

# 日志级别名称数组及最大长度计算
LOG_LEVELS=("FATAL" "ERROR" "WARNING" "INFO" "SUCCESS" "DEBUG")
MAX_LEVEL_LENGTH=0

for level in "${LOG_LEVELS[@]}"; do
  len=${#level}
  if (( len > MAX_LEVEL_LENGTH )); then
    MAX_LEVEL_LENGTH=$len
  fi
done
MAX_LEVEL_LENGTH=$((MAX_LEVEL_LENGTH+2))

# 日志级别名称填充
pad_level() {
  printf "%-${MAX_LEVEL_LENGTH}s" "[$1]"
}

# 打印带颜色的日志函数
log() {
  local level="$(echo "$1" | awk '{print toupper($0)}')" # 转换为大写以支持大小写敏感
  shift
  local message="$@"
  local padded_level=$(pad_level "$level")
  local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  case "$level" in
    "FATAL")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_FATAL ]; then
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
        exit 1
      fi
      ;;

    "ERROR")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_ERROR ]; then
        echo -e "${RED}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "WARNING")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_WARNING ]; then
        echo -e "${YELLOW}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "INFO")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_INFO ]; then
        echo -e "${BLUE}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "SUCCESS")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_SUCCESS ]; then
        echo -e "${GREEN}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    "DEBUG")
      if [ $LOG_LEVEL -ge $LOG_LEVEL_DEBUG ]; then
        echo -e "${CYAN}${BOLD}[$timestamp] $padded_level${NC} $message${NORMAL}"
      fi
      ;;
    *)
      echo -e "${NC}[$timestamp] [$level] $message${NORMAL}"
      ;;
  esac
}

# 设置日志级别的函数
set_log_level() {
  local level="$(echo "$1" | awk '{print toupper($0)}')"
  case "$level" in
    "FATAL")
      LOG_LEVEL=$LOG_LEVEL_FATAL
      ;;
    "ERROR")
      LOG_LEVEL=$LOG_LEVEL_ERROR
      ;;
    "WARNING")
      LOG_LEVEL=$LOG_LEVEL_WARNING
      ;;
    "INFO")
      LOG_LEVEL=$LOG_LEVEL_INFO
      ;;
    "SUCCESS")
      LOG_LEVEL=$LOG_LEVEL_SUCCESS
      ;;
    "DEBUG")
      LOG_LEVEL=$LOG_LEVEL_DEBUG
      ;;
    *)
      echo "无效的日志级别: $1"
      ;;
  esac
}

# 显示帮助信息
show_help() {
  echo "Usage: $0 [-l LOG_LEVEL] <command>"
  echo ""
  echo "Commands:"
  for cmd in "${COMMANDS[@]}"; do
    echo "  $cmd"
  done
  echo ""
  echo "Options:"
  echo "  -l LOG_LEVEL  Set the log level (FATAL ERROR, WARNING, INFO, SUCCESS, DEBUG)"
}

# ------------------------------------------------------------
# 子命令数组
COMMANDS=("help" "new" "config" "list" "start" "stop" "restart" "status" "log" "rm" "configserver" "startserver" "restartserver" "logserver")

runtimeDir=/usr/local/frp
runtimeServer=${runtimeDir}/server
runtimeClient=${runtimeDir}/frpc
binaryDest=/usr/local/bin
agentDir=$home/Library/LaunchAgents
serviceDest=/etc/systemd/system

if [ ! -d ${runtimeServer} ];then
    _runAsRoot mkdir -p ${runtimeServer}
fi

if [ ! -d ${runtimeClient} ];then
    _runAsRoot mkdir -p ${runtimeClient}
fi

_nameFor(){
    echo "frpc-${1}"
}

_agentFor(){
    echo "${agentDir}/${1}.plist"
}

new(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})


    tmpFrpcIniFile=/tmp/frpc-tmp.ini
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ -e ${realFrpcIniFile} ];then
        echo "already exists ${nm}"
        exit 1
    fi
    cat <<EOF >${tmpFrpcIniFile}
[common]
server_addr = 127.0.0.1
server_port = 7000
token = xxx

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 6000
EOF
    _runAsRoot mv ${tmpFrpcIniFile} ${realFrpcIniFile}
    $ed ${runtimeClient}/${name}.ini
}

config(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    configFile=${runtimeClient}/${name}.ini
    if [ ! -e ${configFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    before="$(md5sum ${configFile})"
    _runAsRoot $ed ${configFile}
    after="$(md5sum ${configFile})"

    if _isRunning ${nm};then
	    if [[ "${before}" != "${after}" ]] ;then
		echo "config file changed,and service is running,restart it.."
		restart ${nm}
	    fi
    fi
}

_isRunning(){
    name=${1:?'missing name'}
    if ps aux | grep frpc-${name}.ini | grep 'frpc -c' | grep -vq grep;then
        return 0
    else
        return 1
    fi
}

list(){
    cd ${runtimeClient}
    for ini in $(ls *.ini);do
        ini=${ini#frpc-}
        ini=${ini%.ini}
        echo "client: ${ini}"
    done
}

start(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    # create service file
    case $(uname) in
        Linux)
        _create_linux_service_file ${name} ${binaryDest}/frpc ${runtimeClient}/${name}.ini
        _runAsRoot systemctl daemon-reload
        _runAsRoot systemctl start ${name}.service
        ;;
        Darwin)
        _create_macos_service_file ${name} ${binaryDest}/frpc ${runtimeClient}/${name}.ini
        # start
        launchctl load -w $(_agentFor ${name})
        ;;
        *)
        echo "os error"
        exit 1
    esac

}

_create_linux_service_file(){
    name=${1:?'missing name'}
    exe=${2:?'missing execStart'}
    config=${3:?'missing config file'}

    tmpFrpcServiceFile=/tmp/frpc-tmp.service
    cat<<EOF >${tmpFrpcServiceFile}
[Unit]
Description=frp service ${name}

[Service]
Type=simple
ExecStart=${exe} -c ${config}

[Install]
WantedBy=multi-user.target
EOF
    _runAsRoot mv ${tmpFrpcServiceFile} ${serviceDest}/${name}.service
    _runAsRoot systemctl enable ${name}.service
}

_create_macos_service_file(){
    name=${1:?'missing name'}
    exe=${2:?'missing execStart'}
    config=${3:?'missing config file'}

    cat<<EOF>$(_agentFor ${name})
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>frp ${name}</string>
    <key>WorkingDirectory</key>
    <string>TODO</string>
    <key>ProgramArguments</key>
    <array>
        <string>${exe}</string>
        <string>-c</string>
        <string>${config}</string>
    </array>
    <key>StandardOutPath</key>
    <string>/tmp/${name}.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/${name}.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>

EOF

}

stop(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    case $(uname) in
        Linux)
            _runAsRoot systemctl stop ${name}.service
            ;;
        Darwin)
            echo "TODO"
            ;;
    esac

}

restart(){
    nm=${1:?'missing name'}
    stop ${nm}
    start ${nm}
}

status(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    case $(uname) in
        Linux)
            _runAsRoot systemctl status ${name}.service
            ;;
        Darwin)
            echo TODO
            ;;
    esac
}

log(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    case $(uname) in
        Linux)
            _runAsRoot journalctl -u ${name}.service -f
            ;;
        Darwin)
            echo TODO
            ;;
    esac
}

rm(){
    nm=${1:?'missing name'}
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi

    case $(uname) in
        Linux)
            _runAsRoot systemctl stop ${name}.service
            _runAsRoot /bin/rm -rf ${serviceDest}/${name}.service
            ;;
        Darwin)
            launchctl unload -w $(_agentFor ${name})
            _runAsRoot /bin/rm -rf $(_agentFor ${name})
            ;;
    esac
    _runAsRoot /bin/rm -rf ${runtimeClient}/${name}.ini

}
# server actions
configserver(){
    frpsIniFile=${runtimeServer}/frps.ini
    if [ ! -e ${frpsIniFile} ];then
        _create_frps_config
    fi
    before=$(md5sum ${frpsIniFile})
    $ed ${frpsIniFile}
    after=$(md5sum ${frpsIniFile})

    if [[ "$before" != "$after" ]];then
        echo "config file changed, restart .."
        restartserver
    fi
}

_create_frps_config(){
        cat<<-EOF>/tmp/frps.ini
[common]
bind_addr = 0.0.0.0
bind_port = 7000

dashboard_addr = 0.0.0.0
dashboard_port = 7500
dashboard_user = admin
dashboard_pwd = admin
dashboard_tls_mode = false
# dashboard_tls_cert_file = server.crt
# dashboard_tls_key_file = server.key

# enable_prometheus will export prometheus metrics on {dashboard_addr}:{dashboard_port} in /metrics api.
enable_prometheus = false


# console or real logFile path like ./frps.log
log_file = ./frps.log

# trace, debug, info, warn, error
log_level = info
log_max_days = 3
# disable log colors when log_file is console, default is false
disable_log_color = false
# DetailedErrorsToClient defines whether to send the specific error (with debug info) to frpc. By default, this value is true.
detailed_errors_to_client = true

# authentication_method specifies what authentication method to use authenticate frpc with frps.
# If "token" is specified - token will be read into login message.
# If "oidc" is specified - OIDC (Open ID Connect) token will be issued using OIDC settings. By default, this value is "token".
authentication_method = token

# authenticate_heartbeats specifies whether to include authentication token in heartbeats sent to frps. By default, this value is false.
authenticate_heartbeats = false

# AuthenticateNewWorkConns specifies whether to include authentication token in new work connections sent to frps. By default, this value is false.
authenticate_new_work_conns = false

# auth token
token = 12345678

# oidc_issuer specifies the issuer to verify OIDC tokens with.
# By default, this value is "".
oidc_issuer =

# oidc_audience specifies the audience OIDC tokens should contain when validated.
# By default, this value is "".
oidc_audience =

# oidc_skip_expiry_check specifies whether to skip checking if the OIDC token is expired.
# By default, this value is false.
oidc_skip_expiry_check = false

# oidc_skip_issuer_check specifies whether to skip checking if the OIDC token's issuer claim matches the issuer specified in OidcIssuer.
# By default, this value is false.
oidc_skip_issuer_check = false

# heartbeat configure, it's not recommended to modify the default value
# the default value of heartbeat_timeout is 90. Set negative value to disable it.
# heartbeat_timeout = 90

# user_conn_timeout configure, it's not recommended to modify the default value
# the default value of user_conn_timeout is 10
# user_conn_timeout = 10

# only allow frpc to bind ports you list, if you set nothing, there won't be any limit
allow_ports = 2000-3000,3001,3003,4000-50000

# pool_count in each proxy will change to max_pool_count if they exceed the maximum value
max_pool_count = 5

# max ports can be used for each client, default value is 0 means no limit
max_ports_per_client = 0

# tls_only specifies whether to only accept TLS-encrypted connections. By default, the value is false.
tls_only = false

# tls_cert_file = server.crt
# tls_key_file = server.key
# tls_trusted_ca_file = ca.crt

# if tcp stream multiplexing is used, default is true
# tcp_mux = true

EOF
    _runAsRoot mv /tmp/frps.ini ${frpsIniFile}

}

startserver(){
    frpsIniFile=${runtimeServer}/frps.ini
    if [ ! -e ${frpsIniFile} ];then
        _create_frps_config
    fi

    # create service file
    case $(uname) in
        Linux)
        _create_linux_service_file frps ${binaryDest}/frps ${frpsIniFile}
        _runAsRoot systemctl daemon-reload
        _runAsRoot systemctl enable --now frps.service
        ;;
        Darwin)
        _create_macos_service_file frps ${binaryDest}/frps ${frpsIniFile}
        # start
        launchctl load -w $(_agentFor frps)
        ;;
        *)
        echo "os error"
        exit 1
    esac
}

stopserver(){
    _runAsRoot systemctl stop frps.service
}


restartserver(){
    _runAsRoot systemctl restart frps.service
}

logserver(){
    _runAsRoot journalctl -u frps -f
}

# ------------------------------------------------------------

# 解析命令行参数
while getopts ":l:" opt; do
  case ${opt} in
    l )
      set_log_level "$OPTARG"
      ;;
    \? )
      show_help
      exit 1
      ;;
    : )
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      show_help
      exit 1
      ;;
  esac
done
# NOTE: 这里全局使用了OPTIND，如果在某个函数中也使用了getopts，那么在函数的开头需要重置OPTIND (OPTIND=1)
shift $((OPTIND -1))

# 解析子命令
command=$1
shift

if [[ -z "$command" ]]; then
  show_help
  exit 0
fi

case "$command" in
  help)
    show_help
    ;;
  *)
    ${command} "$@"
    ;;
esac
