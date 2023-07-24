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

if [ -r ${SHELLRC_ROOT}/shellrc.d/shelllib ];then
    source ${SHELLRC_ROOT}/shellrc.d/shelllib
elif [ -r /tmp/shelllib ];then
    source /tmp/shelllib
else
    # download shelllib then source
    shelllibURL=https://gitee.com/sunliang711/init2/raw/master/shell/shellrc.d/shelllib
    (cd /tmp && curl -s -LO ${shelllibURL})
    if [ -r /tmp/shelllib ];then
        source /tmp/shelllib
    fi
fi


###############################################################################
# write your code below (just define function[s])
# function is hidden when begin with '_'
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
        echo "config file changed,and service is running,restart it.."
        restart ${nm}
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


# write your code above
###############################################################################

em(){
    $ed $0
}

function _help(){
    cd "${this}"
    cat<<EOF2
Usage: $(basename $0) ${bold}CMD${reset}

${bold}CMD${reset}:
EOF2
    perl -lne 'print "\t$2" if /^\s*(function)?\s*(\S+)\s*\(\)\s*\{$/' $(basename ${BASH_SOURCE}) | perl -lne "print if /^\t[^_]/"
}

case "$1" in
     ""|-h|--help|help)
        _help
        ;;
    *)
        "$@"
esac
