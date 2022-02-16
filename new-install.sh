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
# link format $(uname)$(uname -m)
Darwinx86_64=https://source711.oss-cn-shanghai.aliyuncs.com/frp/0.34.3/frp_0.34.3_darwin_amd64.tar.gz
Linuxx86_64=https://source711.oss-cn-shanghai.aliyuncs.com/frp/0.34.3/frp_0.34.3_linux_amd64.tar.gz
Linuxaarch64=https://source711.oss-cn-shanghai.aliyuncs.com/frp/0.34.3/frp_0.34.3_linux_arm64.tar.gz

link="$(uname)$(uname -m)"
link=${!link}
tarName=${link##*/}
dirName=${tarName%.tar.gz}
binaryDest=/usr/local/bin

install(){
    _download
    _installScript
}

_download(){
    _require_command curl
    _require_root
    downloadDir=/tmp/frp.tmp
    if [ ! -d ${downloadDir} ];then
        mkdir -p ${downloadDir}
    fi

    (
        # download
        cd ${downloadDir}
        if [ ! -e $tarName ];then
            echo -n "download $link.."
            curl -LO ${link} && { echo "ok"; } || { echo "download failed!"; exit 1; }
        fi

        # extract
        echo -n "extract $tarName.."
        tar xf $tarName && { echo "ok"; } || { echo "extract $tarName failed!"; exit 1; }

        echo -n "install frpc frps to ${binaryDest}.."
        if [ ! -d ${binaryDest} ];then
            mkdir -p ${binaryDest}
        fi

        $(which install) -m 755 ${dirName}/{frpc,frps} ${binaryDest} && { echo "ok"; } || { echo "failed"; exit 1; }

        /bin/rm -rf ${dirName}
    )
}

_installScript(){
    _require_root
    $(which install) -m 755 ${this}/frp.sh ${binaryDest}
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
