#!/bin/bash
set -euo pipefail

# ============================================================
# CI 镜像构建脚本：将编译好的二进制打包为多架构 Docker 镜像
# 环境变量:
#   XTRABACKUP_VERSION  - XtraBackup 版本
#   GLIB_VERSION        - glibc 版本
#   BASE_IMG_URL        - 基础镜像仓库 URL
#   ALIYUN_REGISTRY     - ACR 地址
#   ALIYUN_NAME_SPACE   - ACR 命名空间
# ============================================================

XTRABACKUP_VERSION="${XTRABACKUP_VERSION:-8.4.0-6}"
GLIB_VERSION="${GLIB_VERSION:-2.28}"
BASE_IMG_URL="${BASE_IMG_URL:-registry.cn-hangzhou.aliyuncs.com/lpx03}"
ACR_URL="${ALIYUN_REGISTRY:-registry.cn-hangzhou.aliyuncs.com}"
ACR_NS="${ALIYUN_NAME_SPACE:-lpx03}"

BASE_TAG="xtrabackup:base-glib-${GLIB_VERSION}"
BASE_IMAGE="${BASE_IMG_URL}/${BASE_TAG}"
RELEASE_TAG="xtrabackup:${XTRABACKUP_VERSION}-glib${GLIB_VERSION}"
TARGET="${ACR_URL}/${ACR_NS}/${RELEASE_TAG}"

echo "============================================"
echo "  构建 XtraBackup 发布镜像（多架构）"
echo "============================================"
echo "  XtraBackup 版本: ${XTRABACKUP_VERSION}"
echo "  glibc 版本:      ${GLIB_VERSION}"
echo "  基础镜像:        ${BASE_IMAGE}"
echo "  目标镜像:        ${TARGET}"
echo "  目标架构:        linux/amd64,linux/arm64"
echo "============================================"

# 检查产物是否存在
TARBALL=$(ls output/percona-xtrabackup-*.tar.gz 2>/dev/null | head -1)
if [ -z "${TARBALL}" ]; then
  echo "❌ 未找到编译产物！请先运行编译步骤。"
  exit 1
fi
echo ">>> 产物: ${TARBALL}"

# 临时构建目录
TMP_DIR=$(mktemp -d)
cp "${TARBALL}" "${TMP_DIR}/"

# 生成临时 Dockerfile
cat > "${TMP_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG TARBALL_FILE
COPY ${TARBALL_FILE} /tmp/

RUN cd /opt && \
    tar -xzf /tmp/${TARBALL_FILE} && \
    rm -f /tmp/${TARBALL_FILE} && \
    mv /opt/percona-xtrabackup-* /opt/xtrabackup

ENV PATH="/opt/xtrabackup/bin:${PATH}"
ENV XTRABACKUP_HOME="/opt/xtrabackup"

ENTRYPOINT ["xtrabackup"]
CMD ["--version"]
DOCKERFILE_EOF

TARBALL_BASENAME=$(basename "${TARBALL}")

echo ""
echo ">>> 构建并推送多架构镜像..."
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "TARBALL_FILE=${TARBALL_BASENAME}" \
  -t "${TARGET}" \
  --no-cache \
  --push \
  "${TMP_DIR}"

# 清理临时目录
rm -rf "${TMP_DIR}"

echo ""
echo "============================================"
echo "  ✅ 发布镜像构建推送成功"
echo "  ${TARGET}"
echo "============================================"
