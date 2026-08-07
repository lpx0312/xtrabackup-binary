#!/bin/bash
###############################################################################
# download.sh —— 下载 PXB 源码和 boost(构建依赖)
# ---------------------------------------------------------------------------
# 因为二进制文件不能提交到 GitHub,这些大文件改用本脚本按需下载。
# 用法:
#   cd xtrabackup/build-offline/sources
#   bash download.sh              # 下载全部 4 个文件
#   bash download.sh pxb80        # 只下载 PXB 8.0.35-36
#   bash download.sh pxb24        # 只下载 PXB 2.4.29
#   bash download.sh boost177     # 只下载 boost 1.77.0
#   bash download.sh boost159     # 只下载 boost 1.59.0
#
# 可选环境变量:
#   DOWNLOAD_PROXY  下载代理,如 http://192.168.0.225:7897(内网用)
#   GITHUB_PROXY    GitHub 代理前缀(本脚本不下载 GitHub 资源,预留)
###############################################################################
set -euo pipefail

# 下载代理(可选)
PROXY="${DOWNLOAD_PROXY:-}"
CURL_OPTS=(-fSL --retry 5 --retry-delay 10 --connect-timeout 30)
if [ -n "$PROXY" ]; then
    CURL_OPTS+=(-x "$PROXY")
    echo "==> 使用下载代理: $PROXY"
fi

# ----------------------------------------------------------------------------
# 文件清单:名字 => URL
# ----------------------------------------------------------------------------
declare -A FILES=(
    ["percona-xtrabackup-8.0.35-36.tar.gz"]="https://downloads.percona.com/downloads/Percona-XtraBackup-8.0/Percona-XtraBackup-8.0.35-36/source/tarball/percona-xtrabackup-8.0.35-36.tar.gz"
    ["percona-xtrabackup-2.4.29.tar.gz"]="https://downloads.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-2.4.29/source/tarball/percona-xtrabackup-2.4.29.tar.gz"
    ["boost_1_77_0.tar.bz2"]="https://archives.boost.io/release/1.77.0/source/boost_1_77_0.tar.bz2"
    ["boost_1_59_0.tar.bz2"]="https://archives.boost.io/release/1.59.0/source/boost_1_59_0.tar.bz2"
)

# 速记别名 => 实际文件名
declare -A ALIAS=(
    ["pxb80"]="percona-xtrabackup-8.0.35-36.tar.gz"
    ["pxb24"]="percona-xtrabackup-2.4.29.tar.gz"
    ["boost177"]="boost_1_77_0.tar.bz2"
    ["boost159"]="boost_1_59_0.tar.bz2"
    ["all"]=""
)

# ----------------------------------------------------------------------------
# 下载单个文件(带跳过已存在、大小校验)
# ----------------------------------------------------------------------------
download_one() {
    local fname="$1"
    local url="${FILES[$fname]:-}"
    if [ -z "$url" ]; then
        echo "✗ 未知文件: $fname" >&2
        return 1
    fi
    # 已存在且非空则跳过
    if [ -s "$fname" ]; then
        echo "✓ 已存在,跳过: $fname ($(du -h "$fname" | cut -f1))"
        return 0
    fi
    echo "==> 下载: $fname"
    echo "    URL : $url"
    curl "${CURL_OPTS[@]}" -o "$fname" "$url"
    # 校验下载结果
    if [ -s "$fname" ]; then
        echo "✓ 完成: $fname ($(du -h "$fname" | cut -f1))"
    else
        echo "✗ 失败: $fname 下载后为空" >&2
        rm -f "$fname"
        return 1
    fi
}

# ----------------------------------------------------------------------------
# 解析参数
# ----------------------------------------------------------------------------
# 脚本所在目录就是下载目标目录(无论从哪调用)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "==> 下载目录: $SCRIPT_DIR"
echo

if [ $# -eq 0 ]; then
    # 无参数:下载全部
    echo "=== 下载全部 4 个文件 ==="
    for fname in "${!FILES[@]}"; do
        download_one "$fname" || exit 1
        echo
    done
else
    # 有参数:按别名/文件名下载
    for arg in "$@"; do
        target="${ALIAS[$arg]:-$arg}"
        if [ -z "$target" ]; then
            # all
            for fname in "${!FILES[@]}"; do
                download_one "$fname" || exit 1
            done
        else
            download_one "$target" || exit 1
        fi
        echo
    done
fi

echo "================================================================"
echo " 全部完成!当前目录文件:"
ls -lh "$SCRIPT_DIR" | grep -vE "^total|download.sh|^d"
echo "================================================================"
