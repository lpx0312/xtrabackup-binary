ARG BASE_SYSTEM_VERSION=xtrabackup:base-glib-2.28
ARG BASE_IMG_URL="registry.cn-hangzhou.aliyuncs.com/lpx03"

FROM ${BASE_IMG_URL}/${BASE_SYSTEM_VERSION}
WORKDIR /root

ARG XTRABACKUP_VERSION=8.4.0-6

COPY ./pxb-build-binary.sh /root

RUN set -e && \
    # 从版本号提取主次版本（例: 8.4.0-6 → 8.4，8.0.35-36 → 8.0）
    MAJOR_MINOR=$(echo "${XTRABACKUP_VERSION}" | cut -d. -f1,2) && \
    SRC_FILE="percona-xtrabackup-${XTRABACKUP_VERSION}.tar.gz" && \
    SRC_URL="https://downloads.percona.com/downloads/Percona-XtraBackup-${MAJOR_MINOR}/Percona-XtraBackup-${XTRABACKUP_VERSION}/source/tarball/${SRC_FILE}" && \
    echo "==> 下载源码: ${SRC_URL}" && \
    curl -fSL --retry 3 -o "/tmp/${SRC_FILE}" "${SRC_URL}" && \
    mkdir /root/percona-xtrabackup && \
    tar -xf "/tmp/${SRC_FILE}" -C /root/percona-xtrabackup --strip-components=1 && \
    rm -f "/tmp/${SRC_FILE}" && \
#    # 从 CMakeLists.txt 提取 boost 版本（例: boost_1_77_0 → 1.77.0）
#    BOOST_VER=$(sed -n 's/.*SET.*BOOST_PACKAGE_NAME.*"boost_\([0-9._]*\)".*/\1/p' /root/percona-xtrabackup/CMakeLists.txt | head -1) && \
#    BOOST_VER="${BOOST_VER:-1.77.0}" && \
#    BOOST_FILE="boost_${BOOST_VER}.tar.bz2" && \
#    BOOST_URL="https://archives.boost.io/release/${BOOST_VER}/source/${BOOST_FILE}" && \
#    # 读取 MYSQL_VERSION 确定 BOOST_DIR 路径
#    . /root/percona-xtrabackup/MYSQL_VERSION && \
#    BOOST_DIR="/root/output/boost_${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}" && \
#    mkdir -p "${BOOST_DIR}" && \
#    echo "==> 下载 boost ${BOOST_VER} 到 ${BOOST_DIR}" && \
#    curl -fSL --retry 3 --connect-timeout 60 -o "/tmp/${BOOST_FILE}" "${BOOST_URL}" && \
#    tar -xjf "/tmp/${BOOST_FILE}" -C "${BOOST_DIR}" --strip-components=1 && \
#    rm -f "/tmp/${BOOST_FILE}" && \
    chmod +x /root/pxb-build-binary.sh && \
    echo "==> 开始编译 PXB ${XTRABACKUP_VERSION} ..." && \
    bash pxb-build-binary.sh percona-xtrabackup output
