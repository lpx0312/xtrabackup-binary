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

# 单架构构建,--load 载入本地 docker,再用 docker create + docker cp 提取产物。
# 之前用 --output type=local 直接提取,但 buildx 的 docker-container 驱动下 buildkitd
# 跑在独立容器里,经 easimon/maximize-build-space 重挂载 /var/lib/docker 后,往 host
# 写同步标记文件(openat enable)会 permission denied。--load 走 docker 标准存储,
# 再 docker cp 提取,完全绕开 buildx local exporter,最可靠。
# (前提:runner 与目标镜像同架构 —— 已由原生 runner 保证:amd64 job 用 ubuntu-latest,
#  arm64 job 用 ubuntu-24.04-arm)
echo ""
echo ">>> 构建编译镜像并提取产物(${PLATFORM})..."
docker buildx build \
    --load \
    --build-arg "BASE_IMG_URL=${BASE_IMG_URL}" \
    --build-arg "BASE_SYSTEM_VERSION=${BASE_SYSTEM_VERSION}" \
    --build-arg "PXB_VERSION=${PXB_VERSION}" \
    -t "${BUILD_IMAGE_TAG}" \
    -f build/Dockerfile \
    build/

# 从镜像提取产物:docker create + docker cp(最标准的提取方式)
# 镜像内产物位置:
#   /root/output/percona-xtrabackup-*.glibc*.tar.gz  ← 真实命名(Dockerfile 产出)
#   /root/pxb-final.tar.gz                            ← 上面的固定名副本
EXTRACT_CID="pxb-extract-$$"
echo ""
echo ">>> 从镜像提取产物..."
docker create --name "${EXTRACT_CID}" "${BUILD_IMAGE_TAG}" /bin/true >/dev/null

# 先取真实命名的 tarball;失败则兜底取 pxb-final.tar.gz
mkdir -p output
docker cp "${EXTRACT_CID}:/root/output/." output/ 2>/dev/null || true
REAL_TARBALL="$(ls output/percona-xtrabackup-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "${REAL_TARBALL}" ]; then
    echo ">>> /root/output/ 无真实命名 tarball,兜底取 /root/pxb-final.tar.gz"
    docker cp "${EXTRACT_CID}:/root/pxb-final.tar.gz" \
        "output/percona-xtrabackup-${PXB_VERSION}-glib${GLIB_VERSION}-${ARCH}.tar.gz" 2>/dev/null || true
fi
docker rm -f "${EXTRACT_CID}" >/dev/null

# 只保留 tarball(清理 docker cp 可能带出的 boost 目录等无关内容)
find output/ ! -name '*.tar.gz' -type f -delete 2>/dev/null || true
find output/ -type d -empty -delete 2>/dev/null || true

# 最终校验
REAL_TARBALL="$(ls output/percona-xtrabackup-*.tar.gz 2>/dev/null | head -1 || true)"
if [ -z "${REAL_TARBALL}" ]; then
    echo "❌ 未能从镜像提取任何 percona-xtrabackup-*.tar.gz 产物"
    exit 1
fi

echo ""
echo "============================================"
echo "  ✅ 编译完成!产物列表:"
echo "============================================"
ls -lh output/
echo "============================================"

# 清理编译镜像(腾出空间,避免 runner 磁盘爆)
docker rmi "${BUILD_IMAGE_TAG}" 2>/dev/null || true
