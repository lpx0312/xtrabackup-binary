#!/bin/bash
set -euo pipefail

# ============================================================
# CI 发布镜像脚本:用编译好的二进制 tarball 构建单架构 Docker 镜像并推送到 ACR
# ---------------------------------------------------------------------------
# 每个 ARCH 各跑一次,推送带后缀的单架构 tag:
#   xtrabackup:<PXB_VERSION>-glib<GLIB_VERSION>-amd64
#   xtrabackup:<PXB_VERSION>-glib<GLIB_VERSION>-arm64
# 多架构 manifest 的合并由 workflow 的 merge-manifest job 完成(docker manifest create/push)。
#
# 环境变量:
#   PXB_VERSION         - PXB 完整版本号(必填)
#   GLIB_VERSION        - glibc 版本(必填,2.17 / 2.28)
#   ARCH                - 目标架构(必填,amd64 / arm64)
#   ALIYUN_REGISTRY     - ACR 地址(如 registry.cn-hangzhou.aliyuncs.com)
#   ALIYUN_NAME_SPACE   - ACR 命名空间(如 lpx03)
#
# 依赖:output/ 下已有该架构的 tarball(由 ci-build-binary.sh 产出,
#       或从已发布的 GitHub Release 下载 —— 见 build-image.yml)
# ============================================================

PXB_VERSION="${PXB_VERSION:?ERROR: 必须设置 PXB_VERSION}"
GLIB_VERSION="${GLIB_VERSION:?ERROR: 必须设置 GLIB_VERSION}"
ARCH="${ARCH:?ERROR: 必须设置 ARCH(amd64 或 arm64)}"
ACR_URL="${ALIYUN_REGISTRY:?ERROR: 必须设置 ALIYUN_REGISTRY}"
ACR_NS="${ALIYUN_NAME_SPACE:?ERROR: 必须设置 ALIYUN_NAME_SPACE}"

case "$ARCH" in
    amd64|arm64) ;;
    *) echo "❌ 无效 ARCH: $ARCH"; exit 1 ;;
esac

# 发布镜像的 FROM 用 PXB base 镜像(与编译基础镜像同名,运行时只需 xtrabackup 二进制 + lib/private)
BASE_IMAGE="${ACR_URL}/${ACR_NS}/xtrabackup:base-glib-${GLIB_VERSION}"
# 单架构 tag 带后缀,合并成多架构的不带后缀(由 merge-manifest job 处理)
RELEASE_TAG="xtrabackup:${PXB_VERSION}-glib${GLIB_VERSION}-${ARCH}"
TARGET="${ACR_URL}/${ACR_NS}/${RELEASE_TAG}"
PLATFORM="linux/${ARCH}"

echo "============================================"
echo "  构建 XtraBackup 发布镜像(单架构)"
echo "============================================"
echo "  PXB 版本:    ${PXB_VERSION}"
echo "  glibc 版本:  ${GLIB_VERSION}"
echo "  目标架构:    ${ARCH} (${PLATFORM})"
echo "  基础镜像:    ${BASE_IMAGE}"
echo "  目标镜像:    ${TARGET}"
echo "============================================"

# 找到该架构的 tarball
# 产物文件名含架构后缀(percona-xtrabackup-...-Linux-x86_64/aarch64.glibc*.tar.gz)
case "$ARCH" in
    amd64) TARBALL=$(ls output/percona-xtrabackup-*Linux-x86_64*.tar.gz 2>/dev/null | head -1) ;;
    arm64) TARBALL=$(ls output/percona-xtrabackup-*Linux-aarch64*.tar.gz 2>/dev/null | head -1) ;;
esac
if [ -z "${TARBALL}" ]; then
    # 兜底:如果只有一个 tarball 就用它(可能未带架构后缀)
    TARBALL=$(ls output/percona-xtrabackup-*.tar.gz 2>/dev/null | head -1)
fi
if [ -z "${TARBALL}" ]; then
    echo "❌ 未找到 ${ARCH} 架构的编译产物!请先运行 ci-build-binary.sh。"
    echo "    output/ 目录内容:"
    ls -lh output/ 2>/dev/null || true
    exit 1
fi
echo ">>> 产物: ${TARBALL}"

# 临时构建目录
TMP_DIR=$(mktemp -d)
TARBALL_BASENAME=$(basename "${TARBALL}")
cp "${TARBALL}" "${TMP_DIR}/"

# 生成临时 Dockerfile
# 解压到 /opt/xtrabackup,设置 PATH,tarball 自带 lib/private 依赖(RPATH 已指向 $ORIGIN/../lib/private)
cat > "${TMP_DIR}/Dockerfile" <<'DOCKERFILE_EOF'
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

echo ""
echo ">>> 构建并推送单架构镜像(${PLATFORM})..."
docker buildx build \
    --platform "${PLATFORM}" \
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
echo "  ✅ 单架构镜像构建推送成功"
echo "  ${TARGET}"
echo "============================================"
echo "  提示:多架构合并(-> ${PXB_VERSION}-glib${GLIB_VERSION}) 由 merge-manifest job 完成。"
