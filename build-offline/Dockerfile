# syntax=docker/dockerfile:1
###############################################################################
# Percona XtraBackup 应用镜像 —— 离线编译打包(支持 2.4.x / 8.0+,glib2.17/2.28)
# ---------------------------------------------------------------------------
# 构建上下文需要包含 sources/ 目录(源码 tarball + boost):
#   xtrabackup/build-offline/
#   ├── Dockerfile
#   ├── pxb-build-binary.sh
#   └── sources/
#       ├── download.sh                          <- 提交到仓库的下载脚本
#       ├── percona-xtrabackup-<版本>.tar.gz      <- .gitignore 忽略,需先用 download.sh 下载
#       └── boost_<版本>.tar.[gz|bz2]             <- 同上
#
# 二进制文件不提交仓库(见 .gitignore),构建前需先下载:
#   cd xtrabackup/build-offline/sources && bash download.sh
#
# 构建示例:
#   # PXB 8.0.35-36 on glib2.28
#   docker build -f Dockerfile \
#       --build-arg BASE_IMAGE=xtrabackup:base-glib-2.28 \
#       --build-arg PXB_TARBALL=percona-xtrabackup-8.0.35-36.tar.gz \
#       --build-arg BOOST_TARBALL=boost_1_77_0.tar.bz2 \
#       -t xtrabackup:8.0.35-36-glib2.28 .
#
#   # PXB 2.4.29 on glib2.17
#   docker build -f Dockerfile \
#       --build-arg BASE_IMAGE=xtrabackup:base-glib-2.17 \
#       --build-arg PXB_TARBALL=percona-xtrabackup-2.4.29.tar.gz \
#       --build-arg BOOST_TARBALL=boost_1_59_0.tar.gz \
#       -t xtrabackup:2.4.29-glib2.17 .
###############################################################################

# 基础镜像(已装好编译依赖 + patchelf 0.19.1)
ARG BASE_IMAGE=xtrabackup:base-glib-2.28
FROM ${BASE_IMAGE}

WORKDIR /root

# 必填:源码 tarball 和 boost tarball 的文件名(在 sources/ 目录下)
ARG PXB_TARBALL
ARG BOOST_TARBALL

RUN test -n "$PXB_TARBALL"   || { echo "ERROR: 需要通过 --build-arg PXB_TARBALL= 指定源码包文件名"; exit 1; }
RUN test -n "$BOOST_TARBALL" || { echo "ERROR: 需要通过 --build-arg BOOST_TARBALL= 指定 boost 包文件名"; exit 1; }

# 拷贝脚本和源码资源
COPY pxb-build-binary.sh /root/pxb-build-binary.sh
COPY sources/ /tmp/sources/

# 解压 PXB 源码
# 目录名 = tarball 去掉 .tar.gz 后缀(percona-xtrabackup-8.0.35-36)
RUN PXB_SRC_DIR="/root/percona-xtrabackup" && \
    mkdir -p "$PXB_SRC_DIR" && \
    tar -xf "/tmp/sources/${PXB_TARBALL}" -C "$PXB_SRC_DIR" --strip-components=1 && \
    rm -f "/tmp/sources/${PXB_TARBALL}" && \
    echo "==> PXB 源码版本信息:" && \
    cat "$PXB_SRC_DIR/XB_VERSION"

# 准备 boost:解压到脚本期望的位置 output/boost_<版本号>/
# 脚本根据 PXB 版本决定 boost 目录名(8.0+ 用 MYSQL 版本号,2.4 用 PXB 版本号),
# 这里直接用 XB_VERSION 推导(对 2.4 正确;8.0 的 MYSQL 主次patch 通常 == XB 主次patch,
# 如 8.0.35-36 的 MYSQL_VERSION 也是 8.0.35)。为稳妥,两种目录名都建软链。
RUN set -e && \
    PXB_SRC_DIR="/root/percona-xtrabackup" && \
    . "$PXB_SRC_DIR/XB_VERSION" && \
    XB_VER="${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH}" && \
    BOOST_DIR="/root/output/boost_${XB_VER}" && \
    mkdir -p "$BOOST_DIR" && \
    cd /tmp/sources && \
    case "${BOOST_TARBALL}" in \
        *.tar.gz)  tar -xzf  "/tmp/sources/${BOOST_TARBALL}" -C "$BOOST_DIR" --strip-components=1 ;; \
        *.tar.bz2) tar -xjf  "/tmp/sources/${BOOST_TARBALL}" -C "$BOOST_DIR" --strip-components=1 ;; \
        *.tar.xz)  tar -xJf  "/tmp/sources/${BOOST_TARBALL}" -C "$BOOST_DIR" --strip-components=1 ;; \
        *) echo "ERROR: 不识别的 boost 压缩格式: ${BOOST_TARBALL}"; exit 1 ;; \
    esac && \
    rm -f "/tmp/sources/${BOOST_TARBALL}" && \
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

# 编译 + 打包(脚本自动识别 2.4 / 8.0+)
# source gcc toolset:glib2.28 用 gcc-toolset-12,glib2.17 用 devtoolset
# (基础镜像已建统一软链 /opt/rh/devtoolset -> devtoolset-{10,11},两架构通用)
RUN chmod +x /root/pxb-build-binary.sh && \
    cd /root && \
    if [ -f /opt/rh/gcc-toolset-12/enable ]; then source /opt/rh/gcc-toolset-12/enable; fi && \
    if [ -f /opt/rh/devtoolset/enable ];    then source /opt/rh/devtoolset/enable;    fi && \
    if [ -f /opt/rh/devtoolset-11/enable ]; then source /opt/rh/devtoolset-11/enable; fi && \
    if [ -f /opt/rh/devtoolset-10/enable ]; then source /opt/rh/devtoolset-10/enable; fi && \
    bash pxb-build-binary.sh percona-xtrabackup output

# 把产物放到固定位置方便提取
RUN cp /root/output/percona-xtrabackup-*.glibc*.tar.gz /root/pxb-final.tar.gz && \
    ls -lh /root/pxb-final.tar.gz
