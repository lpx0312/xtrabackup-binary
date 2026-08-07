#!/bin/bash
###############################################################################
# build-xtrabackup-tarball.sh
# ---------------------------------------------------------------------------
# 在 KylinV10 SP3 上从源码编译 Percona XtraBackup 8.0.35,并打包成
# "自带 lib/private 依赖"的可移植 tarball(对标官方 glibc2.28 二进制包)。
#
# 打包逻辑来自官方 percona/percona-xtradb-cluster/build-ps/build-binary.sh 的
# gather_libs / set_runpath / check_libs / tar 流程。
#
# 用法:
#   bash pxb-build-binary.sh [源码目录] [输出目录]
#     源码目录: percona-xtrabackup 源码 git 仓库根目录(含 CMakeLists.txt)
#     输出目录: 打包产物输出位置(默认源码目录同级)
#
# 前置依赖(KylinV10 上需提前装好):
#   dnf install -y cmake gcc gcc-c++ make libaio libaio-devel bison \
#                  ncurses-devel libgcrypt-devel libcurl-devel libev-devel \
#                  patchelf git tar
#   boost 会由 cmake 的 -DDOWNLOAD_BOOST=1 自动下载,无需手动准备
###############################################################################
set -euo pipefail

# ----------------------------------------------------------------------------
# 参数解析(强制转绝对路径,避免后续 cd 后相对路径失效)
# ----------------------------------------------------------------------------
RAW_SRC="${1:-$(pwd)}"
RAW_OUT="${2:-}"

SRC_DIR="$(cd "$RAW_SRC" 2>/dev/null && pwd)" || {
    echo "错误: 源码目录不存在: $RAW_SRC"; exit 1; }
if [ -n "$RAW_OUT" ]; then
    mkdir -p "$RAW_OUT"
    OUT_DIR="$(cd "$RAW_OUT" && pwd)"
else
    OUT_DIR="$(dirname "$SRC_DIR")"
fi

# 校验源码目录确实是 PXB 源码根
[ -f "$SRC_DIR/CMakeLists.txt" ] || { echo "错误: $SRC_DIR 下找不到 CMakeLists.txt,不是有效的源码目录"; exit 1; }
[ -f "$SRC_DIR/XB_VERSION" ]     || { echo "错误: $SRC_DIR 下找不到 XB_VERSION,确定是 percona-xtrabackup 源码吗?"; exit 1; }

# ----------------------------------------------------------------------------
# 版本号(用 XB_VERSION,PXB 的版本号在 XB_VERSION_EXTRA 里,如 -36)
# ----------------------------------------------------------------------------
source "$SRC_DIR/XB_VERSION"
source "$SRC_DIR/MYSQL_VERSION"
MYSQL_VER="${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}"
PXB_FULL_VER="${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH}${XB_VERSION_EXTRA:-}"
PRODUCT="percona-xtrabackup-${PXB_FULL_VER}-Linux-$(uname -m)"

echo "================================================================"
echo " PXB 版本     : $PXB_FULL_VER"
echo " 源码目录     : $SRC_DIR"
echo " 输出目录     : $OUT_DIR"
echo " 产物名       : ${PRODUCT}.tar.gz"
echo "================================================================"

# 工作区(全部基于绝对路径)
BUILD_DIR="$OUT_DIR/build-${PRODUCT}"
STAGE_DIR="$OUT_DIR/stage-${PRODUCT}"
INSTALL_PREFIX="$STAGE_DIR/usr/local/$PRODUCT"
BOOST_DIR="$OUT_DIR/boost_${MYSQL_VER}"

# 工具检查
for t in cmake gcc g++ make patchelf git file tar; do
    command -v "$t" >/dev/null 2>&1 || { echo "错误: 缺少工具 [$t],请先安装"; exit 1; }
done

PROCESSORS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 4)
MAKE_JFLAG="${MAKE_JFLAG:--j$PROCESSORS}"

# ----------------------------------------------------------------------------
# Step 1: 编译 PXB
# ----------------------------------------------------------------------------
echo ">>> [1/4] 编译 PXB (cmake + make) ..."

rm -rf "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR"
# 用 -DBUILD_CONFIG=xtrabackup_release(官方打包用的配置)。
cmake "$SRC_DIR" \
    -DBUILD_CONFIG=xtrabackup_release \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DDOWNLOAD_BOOST=1 \
    -DWITH_BOOST="$BOOST_DIR" \
    -DWITH_MAN_PAGES=OFF

make $MAKE_JFLAG

echo ">>> [2/4] make install -> $INSTALL_PREFIX"
make install

cd "$INSTALL_PREFIX"

# 检查产物存在
[ -f bin/xtrabackup ] || { echo "编译失败: bin/xtrabackup 不存在"; exit 1; }

# ----------------------------------------------------------------------------
# Step 3: 收集第三方依赖库到 lib/private(对应官方 gather_libs)
# ----------------------------------------------------------------------------
echo ">>> [3/4] 收集第三方库 + 设置 RUNPATH (patchelf) ..."

LIBLIST="libaio.so libprocps.so libgcrypt.so libsasl2.so libatomic.so \
         libnuma.so libgssapi.so libldap_r-2.4.so.2 liblber-2.4.so.2 \
         libreadline.so libtinfo.so libbrotlidec.so libbrotlicommon.so \
         librtmp.so libfreebl3.so libsmime3.so libnss3.so libnssutil3.so \
         libplds4.so libplc4.so libnspr4.so libtirpc.so libncurses.so.5 \
         libboost_program_options libprotobuf.so libprotobuf-lite.so \
         libicudata.so libicuuc.so libicui18n.so libicuio.so"

mkdir -p lib/private

gather_libs() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local elf
    while IFS= read -r elf; do
        [ -z "$elf" ] && continue
        local lib src real base soname
        for lib in $LIBLIST; do
            while IFS= read -r src; do
                [ -z "$src" ] && continue
                real=$(readlink -f "$src")
                base=$(basename "$real")
                # soname 取到主版本号:libfoo.so.7.1.0 -> libfoo.so.7
                # 加载器按 soname(如 libprocps.so.7)找库,必须带主版本号
                soname=$(echo "$base" | sed -E 's/^((lib[^.]+\.so\.[0-9]+).*)$/\2/')
                if [ -f "lib/private/$base" ] || [ -L "lib/private/$soname" ]; then
                    continue
                fi
                echo "  + 收集 $base"
                cp -v "$real" lib/private/
                patchelf --set-soname "$soname" "lib/private/$base" 2>/dev/null || true
                ln -sf "$base" "lib/private/$soname"
            done < <(ldd "$elf" 2>/dev/null | grep "$lib" | awk '{print $3}')
        done
    done < <(find "$dir" -maxdepth 1 -type f -exec file {} \; | grep 'ELF' | cut -d: -f1)
}

set_runpath() {
    local dir="$1" rpath="$2"
    [ -d "$dir" ] || return 0
    local elf
    while IFS= read -r elf; do
        [ -z "$elf" ] && continue
        echo "  ~ RUNPATH  $elf -> $rpath"
        patchelf --set-rpath "$rpath" "$elf"
    done < <(find "$dir" -maxdepth 1 -type f -exec file {} \; | grep 'ELF' | cut -d: -f1)
}

gather_libs bin
gather_libs lib
[ -d lib/plugin ] && gather_libs lib/plugin

set_runpath bin '$ORIGIN/../lib/private/'
set_runpath lib/private '$ORIGIN'
[ -d lib/plugin ] && set_runpath lib/plugin '$ORIGIN/../private/'

echo "  = ldd 校验 ="
CHECK_FAIL=0
while IFS= read -r elf; do
    [ -z "$elf" ] && continue
    missing=$(ldd "$elf" 2>/dev/null | grep "not found" || true)
    if [ -n "$missing" ]; then
        echo "  ✗ FAIL: $elf"; echo "$missing"
        CHECK_FAIL=1
    else
        echo "  ✓ $elf"
    fi
done < <(find bin lib -type f -exec file {} \; | grep ELF | cut -d: -f1)

if [ "$CHECK_FAIL" -ne 0 ]; then
    echo "ldd 校验失败:仍有库找不到,请检查 LIBLIST 是否遗漏"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 4: 打包成 tarball
# ----------------------------------------------------------------------------
echo ">>> [4/4] 打包 ${PRODUCT}.tar.gz"

cd "$STAGE_DIR/usr/local"
find "$PRODUCT" -type f -name 'core.*' -delete 2>/dev/null || true

TARBALL="$OUT_DIR/${PRODUCT}.tar.gz"
tar --owner=0 --group=0 -czf "$TARBALL" "$PRODUCT"

echo
echo "================================================================"
echo " 完成!"
echo " 产物: $TARBALL"
echo " 大小: $(du -h "$TARBALL" | cut -f1)"
echo "================================================================"
echo " 验证方法(在任意机器解压后):"
echo "   tar -xzf ${PRODUCT}.tar.gz -C /usr/local/"
echo "   /usr/local/${PRODUCT}/bin/xtrabackup --version"
echo "================================================================"
