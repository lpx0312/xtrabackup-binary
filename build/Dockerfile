# syntax=docker/dockerfile:1
###############################################################################
# Percona XtraBackup 应用镜像 —— 网络下载编译打包(支持 2.4.x / 8.0+,glib2.17/2.28)
# ---------------------------------------------------------------------------
# 与 build-offline/Dockerfile(离线 COPY 版)的区别:源码和 boost 在构建时
# 从网络下载,构建上下文只需要 Dockerfile + pxb-build-binary.sh,不需要 sources/。
# 适合 GitHub Actions 等 CI 环境(有外网)。
#
# boost 版本无需手动指定 —— 自动从源码 cmake/boost.cmake 读取:
#   8.0+ → boost_1_77_0.tar.bz2,2.4 → boost_1_59_0.tar.gz
#
# 构建上下文:
#   xtrabackup-binary/build/
#   ├── Dockerfile
#   ├── pxb-build-binary.sh
#   ├── ci-build-binary.sh
#   └── ci-build-image.sh
#
# 构建示例:
#   # PXB 8.0.35-36 on glib2.28
#   docker build -f Dockerfile \
#       --build-arg BASE_IMAGE=xtrabackup:base-glib-2.28 \
#       --build-arg PXB_VERSION=8.0.35-36 \
#       -t xtrabackup:8.0.35-36-glib2.28 .
#
#   # PXB 2.4.29 on glib2.17
#   docker build -f Dockerfile \
#       --build-arg BASE_IMAGE=xtrabackup:base-glib-2.17 \
#       --build-arg PXB_VERSION=2.4.29 \
#       -t xtrabackup:2.4.29-glib2.17 .
###############################################################################

# 基础镜像(已装好编译依赖 + patchelf 0.19.1)
ARG BASE_SYSTEM_VERSION=xtrabackup:base-glib-2.28
ARG BASE_IMG_URL="registry.cn-hangzhou.aliyuncs.com/lpx03"

FROM ${BASE_IMG_URL}/${BASE_SYSTEM_VERSION}

WORKDIR /root

# 必填:PXB 版本号(如 8.0.35-36、2.4.29)
# boost 版本无需指定 —— 自动从源码 cmake/boost.cmake 读取
#   (8.0+ → boost_1_77_0.tar.bz2,2.4 → boost_1_59_0.tar.gz)
ARG PXB_VERSION
# 可选:下载代理(GitHub Actions 一般不用,内网构建时可设为 http://x:x)
ARG DOWNLOAD_PROXY=""

RUN test -n "$PXB_VERSION" || { echo "ERROR: 需要通过 --build-arg PXB_VERSION= 指定版本(如 8.0.35-36)"; exit 1; }

# 配置下载代理(若提供)
RUN if [ -n "$DOWNLOAD_PROXY" ]; then \
        echo "==> 使用下载代理: $DOWNLOAD_PROXY"; \
        echo "export http_proxy=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export https_proxy=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
        echo "export HTTP_PROXY=$DOWNLOAD_PROXY"  >> /etc/profile.d/proxy.sh; \
        echo "export HTTPS_PROXY=$DOWNLOAD_PROXY" >> /etc/profile.d/proxy.sh; \
    fi

# 拷贝编译+打包脚本
COPY pxb-build-binary.sh /root/pxb-build-binary.sh

# ----------------------------------------------------------------------------
# 下载 PXB 源码
# URL 格式:https://downloads.percona.com/downloads/Percona-XtraBackup-<主.次>/
#           Percona-XtraBackup-<完整版本>/source/tarball/percona-xtrabackup-<完整版本>.tar.gz
# ----------------------------------------------------------------------------
RUN set -e && \
    source /etc/profile.d/proxy.sh 2>/dev/null || true && \
    MAJOR_MINOR=$(echo "${PXB_VERSION}" | cut -d. -f1,2) && \
    PXB_TARBALL="percona-xtrabackup-${PXB_VERSION}.tar.gz" && \
    PXB_URL="https://downloads.percona.com/downloads/Percona-XtraBackup-${MAJOR_MINOR}/Percona-XtraBackup-${PXB_VERSION}/source/tarball/${PXB_TARBALL}" && \
    echo "==> 下载 PXB 源码: ${PXB_URL}" && \
    curl -4 -fSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 -o "/tmp/${PXB_TARBALL}" "${PXB_URL}" && \
    mkdir -p /root/percona-xtrabackup && \
    tar -xf "/tmp/${PXB_TARBALL}" -C /root/percona-xtrabackup --strip-components=1 && \
    rm -f "/tmp/${PXB_TARBALL}" && \
    echo "==> PXB 源码版本信息:" && \
    cat /root/percona-xtrabackup/XB_VERSION

# ----------------------------------------------------------------------------
# 下载并准备 boost —— 版本自动从源码 cmake/boost.cmake 的 BOOST_PACKAGE_NAME 读取
# 8.0+ → boost_1_77_0,2.4 → boost_1_59_0;统一下载 .tar.bz2 格式(archives.boost.io
# 对所有版本都提供 .tar.bz2),解压到脚本期望位置 output/boost_<PXB版本号>/
# ----------------------------------------------------------------------------
RUN set -e && \
    source /etc/profile.d/proxy.sh 2>/dev/null || true && \
    PXB_SRC_DIR="/root/percona-xtrabackup" && \
    BOOST_CMAKE="$PXB_SRC_DIR/cmake/boost.cmake" && \
    if [ ! -f "$BOOST_CMAKE" ]; then \
        echo "ERROR: 找不到 $BOOST_CMAKE,无法自动识别 boost 版本"; exit 1; \
    fi && \
    BOOST_PKG=$(grep -m1 'SET(BOOST_PACKAGE_NAME' "$BOOST_CMAKE" | sed -E 's/.*"([^"]+)".*/\1/') && \
    BOOST_VER=$(echo "$BOOST_PKG" | sed -E 's/^boost_(.*)$/\1/' | tr '_' '.') && \
    BOOST_TARBALL="${BOOST_PKG}.tar.bz2" && \
    BOOST_URL="https://archives.boost.io/release/${BOOST_VER}/source/${BOOST_TARBALL}" && \
    echo "==> 从源码识别 boost: $BOOST_PKG (版本 $BOOST_VER)" && \
    echo "==> 下载 boost: ${BOOST_URL}" && \
    curl -4 -fSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 -o "/tmp/${BOOST_TARBALL}" "${BOOST_URL}" && \
    . "$PXB_SRC_DIR/XB_VERSION" && \
    XB_VER="${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH}" && \
    BOOST_DIR="/root/output/boost_${XB_VER}" && \
    mkdir -p "$BOOST_DIR" && \
    tar -xjf "/tmp/${BOOST_TARBALL}" -C "$BOOST_DIR" --strip-components=1 && \
    rm -f "/tmp/${BOOST_TARBALL}" && \
    echo "==> boost 已解压到 $BOOST_DIR" && \
    ls "$BOOST_DIR/boost/" >/dev/null 2>&1 && echo "==> boost 内容校验 OK" || { echo "ERROR: boost 解压后找不到 boost/ 目录"; exit 1; }

# 8.0+ 的 boost 目录用 MYSQL_VERSION 命名,若与 XB_VERSION 不同则补建软链
RUN set -e && \
    PXB_SRC_DIR="/root/percona-xtrabackup" && \
    if [ -f "$PXB_SRC_DIR/MYSQL_VERSION" ]; then \
        . "$PXB_SRC_DIR/MYSQL_VERSION" && \
        XB_VER="$(. $PXB_SRC_DIR/XB_VERSION; echo ${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH})" && \
        MYSQL_VER="${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}" && \
        if [ "$XB_VER" != "$MYSQL_VER" ] && [ -d "/root/output/boost_${XB_VER}" ]; then \
            ln -sf "boost_${XB_VER}" "/root/output/boost_${MYSQL_VER}"; \
        fi; \
    fi

# ----------------------------------------------------------------------------
# 编译 + 打包(脚本自动识别 2.4 / 8.0+)
# 自动 source 对应的 gcc toolset:
#   glib2.28 -> gcc-toolset-12
#   glib2.17 -> devtoolset(amd64=11/arm64=10,基础镜像已建统一软链 /opt/rh/devtoolset)
# 优先用统一软链,兜底各版本原始路径
# ----------------------------------------------------------------------------
RUN chmod +x /root/pxb-build-binary.sh && \
    cd /root && \
    if [ -f /opt/rh/gcc-toolset-12/enable ]; then source /opt/rh/gcc-toolset-12/enable; fi && \
    if [ -f /opt/rh/devtoolset/enable ];       then source /opt/rh/devtoolset/enable;       fi && \
    if [ -f /opt/rh/devtoolset-11/enable ];    then source /opt/rh/devtoolset-11/enable;    fi && \
    if [ -f /opt/rh/devtoolset-10/enable ];    then source /opt/rh/devtoolset-10/enable;    fi && \
    bash pxb-build-binary.sh percona-xtrabackup output

# 把产物放到固定位置方便提取
RUN cp /root/output/percona-xtrabackup-*.glibc*.tar.gz /root/pxb-final.tar.gz && \
    ls -lh /root/pxb-final.tar.gz
