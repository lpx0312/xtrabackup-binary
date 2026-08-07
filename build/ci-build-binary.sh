#!/bin/bash
set -euo pipefail

# ============================================================
# CI 编译脚本：使用基础镜像编译 XtraBackup 二进制并提取产物
# 环境变量:
#   XTRABACKUP_VERSION  - XtraBackup 版本（如 8.4.0-6）
#   GLIB_VERSION        - glibc 版本（2.17 或 2.28）
#   BASE_IMG_URL        - 基础镜像仓库 URL
# ============================================================

XTRABACKUP_VERSION="${XTRABACKUP_VERSION:-8.4.0-6}"
GLIB_VERSION="${GLIB_VERSION:-2.28}"
BASE_IMG_URL="${BASE_IMG_URL:-registry.cn-hangzhou.aliyuncs.com/lpx03}"

BASE_TAG="xtrabackup:base-glib-${GLIB_VERSION}"
BASE_IMAGE="${BASE_IMG_URL}/${BASE_TAG}"
BUILD_IMAGE_TAG="xtrabackup-build:${XTRABACKUP_VERSION}-glib${GLIB_VERSION}"

echo "============================================"
echo "  编译 XtraBackup 二进制"
echo "============================================"
echo "  XtraBackup 版本: ${XTRABACKUP_VERSION}"
echo "  glibc 版本:      ${GLIB_VERSION}"
echo "  基础镜像:        ${BASE_IMAGE}"
echo "============================================"

# 拉取基础镜像
echo ""
echo ">>> 拉取基础镜像..."
docker pull "${BASE_IMAGE}"

# 构建编译镜像（二进制在镜像构建时编译）
echo ""
echo ">>> 构建编译镜像..."
docker build \
  --build-arg "BASE_SYSTEM_VERSION=${BASE_TAG}" \
  --build-arg "BASE_IMG_URL=${BASE_IMG_URL}" \
  --build-arg "XTRABACKUP_VERSION=${XTRABACKUP_VERSION}" \
  -t "${BUILD_IMAGE_TAG}" \
  -f build/Dockerfile \
  build/

# 创建并启动容器执行编译
echo ""
echo ">>> 启动容器编译..."
mkdir -p output

cid=$(docker create "${BUILD_IMAGE_TAG}")
docker start -a "${cid}" || {
  echo "检查容器日志..."
  docker logs "${cid}" 2>&1 || true
  docker rm "${cid}" 2>/dev/null || true
  echo "❌ 二进制编译失败"
  exit 1
}

# 提取产物
echo ""
echo ">>> 提取编译产物..."
docker cp "${cid}:/root/output/." ./output/
docker rm "${cid}"

echo ""
echo "============================================"
echo "  ✅ 编译完成！产物列表："
echo "============================================"
ls -lh output/
echo "============================================"
