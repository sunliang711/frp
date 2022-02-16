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
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi
    _runAsRoot $ed ${realFrpcIniFile}
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
[unit]
Description=frpc service ${name}

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
    <string>frpc ${name}</string>
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
    name=$(_nameFor ${nm})
    realFrpcIniFile=${runtimeClient}/${name}.ini
    if [ ! -e ${realFrpcIniFile} ];then
        echo "no such config for ${nm}"
        exit 1
    fi
    stop ${name}
    start ${name}
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
            _runAsRoot journalctl -u ${name}.service
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
newserver(){
    echo todo
}

startServer(){
    echo todo
}

stopserver(){
    echo todo
}


restartServer(){
    echo
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
