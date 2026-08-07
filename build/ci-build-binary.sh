#!/bin/bash
set -euo pipefail

# ============================================================
# CI 编译脚本:用基础镜像按指定架构编译 XtraBackup 二进制并提取 tarball
# ---------------------------------------------------------------------------
# 环境变量:
#   PXB_VERSION    - PXB 完整版本号(必填,如 8.0.35-36、2.4.29)
#   GLIB_VERSION   - glibc 版本(必填,2.17 / 2.28),决定用哪个基础镜像
#   ARCH           - 目标架构(必填,amd64 / arm64)
#   BASE_IMG_URL   - 基础镜像仓库 URL(如 registry.cn-hangzhou.aliyuncs.com/lpx03)
#
# 产物:output/percona-xtrabackup-*.tar.gz(文件名自带架构与 glibc 后缀,
#       由 pxb-build-binary.sh 内部 uname -m / ldd --version 产生)
# ============================================================

PXB_VERSION="${PXB_VERSION:?ERROR: 必须设置 PXB_VERSION(如 8.0.35-36)}"
GLIB_VERSION="${GLIB_VERSION:?ERROR: 必须设置 GLIB_VERSION(2.17 或 2.28)}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"
BASE_IMG_URL="${BASE_IMG_URL:?ERROR: 必须设置 BASE_IMG_URL(ACR 仓库 URL)}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH(应为 amd64 或 arm64)"; exit 1 ;;
esac

# 由 GLIB_VERSION 拼出基础镜像名(与 build-base-image.yml 推送的 tag 一致)
BASE_SYSTEM_VERSION="xtrabackup:base-glib-${GLIB_VERSION}"
BUILD_IMAGE_TAG="xtrabackup-build:${PXB_VERSION}-glib${GLIB_VERSION}-${ARCH}"
PLATFORM="linux/${ARCH}"

echo "============================================"
echo "  编译 XtraBackup 二进制"
echo "============================================"
echo "  PXB 版本:    ${PXB_VERSION}"
echo "  glibc 版本:  ${GLIB_VERSION}"
echo "  目标架构:    ${ARCH} (${PLATFORM})"
echo "  基础镜像:    ${BASE_IMG_URL}/${BASE_SYSTEM_VERSION}"
echo "============================================"

# 先拉基础镜像(明确失败点;buildx 也会拉,但单独拉能让错误更清晰)
echo ""
echo ">>> 拉取基础镜像..."
docker pull "${BASE_IMG_URL}/${BASE_SYSTEM_VERSION}"

# 单架构构建,用 --output type=local 把 /root/pxb-final.tar.gz 直接提取到本地。
# (foreign arch 不能用 --load,故统一用 local 输出;amd64/arm64 走同一套逻辑)
echo ""
echo ">>> 构建编译镜像并提取产物(${PLATFORM})..."
WORKDIR="$(mktemp -d)"
docker buildx build \
    --platform "${PLATFORM}" \
    --build-arg "BASE_IMG_URL=${BASE_IMG_URL}" \
    --build-arg "BASE_SYSTEM_VERSION=${BASE_SYSTEM_VERSION}" \
    --build-arg "PXB_VERSION=${PXB_VERSION}" \
    -t "${BUILD_IMAGE_TAG}" \
    -f build/Dockerfile \
    --output type=local,dest="${WORKDIR}" \
    build/

# 编译镜像在最后一步会把产物复制到 /root/pxb-final.tar.gz
if [ ! -f "${WORKDIR}/root/pxb-final.tar.gz" ]; then
    echo "❌ 构建完成但未找到 ${WORKDIR}/root/pxb-final.tar.gz"
    echo "    构建输出目录内容:"
    ls -laR "${WORKDIR}/root" 2>/dev/null | head -40 || true
    rm -rf "${WORKDIR}"
    exit 1
fi

# 整理到 output/(artifact 上传 + Release 用)
echo ""
echo ">>> 整理产物到 output/..."
mkdir -p output
TARBALL="$(basename "${WORKDIR}/root/pxb-final.tar.gz")"
# pxb-final.tar.gz 是固定名,改成真实产物名(从镜像内 output/ 目录取)
REAL_TARBALL="$(ls "${WORKDIR}/root/output/"percona-xtrabackup-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -n "${REAL_TARBALL}" ]; then
    cp "${REAL_TARBALL}" "output/"
else
    # 兜底:用 pxb-final.tar.gz
    cp "${WORKDIR}/root/pxb-final.tar.gz" "output/percona-xtrabackup-${PXB_VERSION}-glib${GLIB_VERSION}-${ARCH}.tar.gz"
fi

echo ""
echo "============================================"
echo "  ✅ 编译完成!产物列表:"
echo "============================================"
ls -lh output/
echo "============================================"

# 清理
rm -rf "${WORKDIR}"
