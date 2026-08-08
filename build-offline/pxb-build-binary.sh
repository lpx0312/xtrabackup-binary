#!/bin/bash
###############################################################################
# pxb-build-binary.sh —— 编译 Percona XtraBackup 并打包成可移植二进制 tarball
# ---------------------------------------------------------------------------
# 兼容 PXB 2.4.x 和 8.0+(自动识别版本,适配差异):
#   - 2.4 没有 MYSQL_VERSION 文件 → 版本号全用 XB_VERSION
#   - 2.4 的 cmake 不支持 DOWNLOAD_BOOST / WITH_MAN_PAGES → 自动跳过
#   - boost 目录命名:8.0+ 用 boost_<MYSQL版本>,2.4 用 boost_<PXB版本>
#
# 打包逻辑(gather_libs / set_runpath / replace_libs)对齐官方
# percona/percona-xtradb-cluster/build-ps/build-binary.sh,产出"自带 lib/private
# 依赖"的可移植 tarball,对标官方 glibc2.XX 二进制包。
#
# 用法:
#   bash pxb-build-binary.sh [源码目录] [输出目录]
#     源码目录: percona-xtrabackup 源码根目录(含 CMakeLists.txt、XB_VERSION)
#     输出目录: 打包产物输出位置(默认源码目录同级)
#
# 前置:
#   1. 基础镜像已装好编译依赖 + patchelf >= 0.18(用 base Dockerfile)
#   2. boost 需提前解压到 <输出目录>/boost_<版本号>/ 下:
#        - 8.0.x:boost_<MYSQL版本>(如 boost_8.0.35/boost/...)
#        - 2.4.x:boost_<PXB版本>(如 boost_2.4.29/boost/...)
#      (8.0+ 若不带 boost,cmake 会用 DOWNLOAD_BOOST 自动下载;2.4 必须本地提供)
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
# 版本号:XB_VERSION 一定有(PXB 自己的版本);MYSQL_VERSION 只有 8.0+ 有(2.4 没有)
# ----------------------------------------------------------------------------
source "$SRC_DIR/XB_VERSION"
PXB_FULL_VER="${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH}${XB_VERSION_EXTRA:-}"
# boost 目录命名:8.0+ 用 MYSQL_VERSION(如 boost_8.0.35),2.4 用 XB_VERSION(如 boost_2.4.29)
if [ -f "$SRC_DIR/MYSQL_VERSION" ]; then
    source "$SRC_DIR/MYSQL_VERSION"
    MYSQL_VER="${MYSQL_VERSION_MAJOR}.${MYSQL_VERSION_MINOR}.${MYSQL_VERSION_PATCH}"
else
    # 2.4 没有 MYSQL_VERSION,用 XB 版本号作为 boost 目录名
    MYSQL_VER="${XB_VERSION_MAJOR}.${XB_VERSION_MINOR}.${XB_VERSION_PATCH}"
fi
# glibc 次版本号,对齐官方命名(如 percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.28)
# 用 read 读首行,避开管道 SIGPIPE 与 pipefail 冲突
GLIBC_LINE=""
read -r GLIBC_LINE < <(ldd --version 2>/dev/null)
GLIBC_FULL=$(echo "$GLIBC_LINE" | awk '{print $NF}')
GLIBC_MAJOR=$(echo "$GLIBC_FULL" | cut -d. -f1)
GLIBC_MINOR=$(echo "$GLIBC_FULL" | cut -d. -f2)
GLIBC_TAG="glibc${GLIBC_MAJOR}.${GLIBC_MINOR}"
PRODUCT="percona-xtrabackup-${PXB_FULL_VER}-Linux-$(uname -m).${GLIBC_TAG}"

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

# ---- 源码 patch(按需,仅特定版本+架构触发,幂等)----
# PXB 2.4(基于 MySQL 5.7)在 aarch64 + CentOS 7(glibc 2.17)下编译报
#   sql/mysqld.cc: error: 'prctl' was not declared in this scope
# 原因:该组合的 glibc/kernel headers 不会自动声明 prctl(需显式 #include <sys/prctl.h>)。
# 仅在 2.4 + aarch64 时打补丁,其它组合(8.0 / amd64 / glibc2.28)不受影响。
if [ "${XB_VERSION_MAJOR}" -lt 8 ] 2>/dev/null && [ "$(uname -m)" = "aarch64" ]; then
    MYCC="$SRC_DIR/sql/mysqld.cc"
    if [ -f "$MYCC" ] && ! grep -q 'sys/prctl.h' "$MYCC"; then
        echo ">>> [patch] PXB 2.4 + aarch64: 给 sql/mysqld.cc 补 #include <sys/prctl.h>"
        # 不依赖具体锚点行:在第一个 #include 之后插入(C 预处理不关心顺序,
        # 只要出现在 prctl 调用之前即可)。用 awk 保证只插一次。
        awk '!done && /^#include / {print; print "#include <sys/prctl.h>"; done=1; next} 1' "$MYCC" > "$MYCC.tmp" \
            && mv "$MYCC.tmp" "$MYCC"
        grep -q 'sys/prctl.h' "$MYCC" || { echo "错误: patch prctl.h 失败"; exit 1; }
    fi
fi

echo ">>> [1/4] 编译 PXB (cmake + make) ..."

rm -rf "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$BUILD_DIR"

cd "$BUILD_DIR"
# cmake 参数:2.4 和 8.0+ 的差异通过主版本号自动适配
#   - DOWNLOAD_BOOST / WITH_MAN_PAGES 是 MySQL 8.0 cmake 才有的选项,2.4 不支持
#   - 两者都用本地 boost(BOOST_DIR 必须提前准备好),8.0 加 DOWNLOAD_BOOST 兜底
CMAKE_OPTS=(-DBUILD_CONFIG=xtrabackup_release
            -DCMAKE_BUILD_TYPE=RelWithDebInfo
            -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"
            -DWITH_BOOST="$BOOST_DIR")
if [ "${XB_VERSION_MAJOR}" -ge 8 ] 2>/dev/null; then
    # 8.0+:支持自动下载 boost 和 man pages 开关
    CMAKE_OPTS+=(-DDOWNLOAD_BOOST=1 -DWITH_MAN_PAGES=OFF)
fi
cmake "$SRC_DIR" "${CMAKE_OPTS[@]}"

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

LIBLIST="libssl.so libcrypto.so libaio.so libprocps.so libgcrypt.so \
         libsasl2.so libatomic.so libnuma.so libgssapi.so libldap_r-2.4.so.2 \
         liblber-2.4.so.2 libreadline.so libtinfo.so libbrotlidec.so \
         libbrotlicommon.so librtmp.so libfreebl3.so libsmime3.so libnss3.so \
         libnssutil3.so libplds4.so libplc4.so libnspr4.so libtirpc.so \
         libncurses.so.5 libboost_program_options libprotobuf.so \
         libprotobuf-lite.so libicudata.so libicuuc.so libicui18n.so libicuio.so"

mkdir -p lib/private

LIBPATH=""

# gather_libs: 扫描目录下所有 ELF,把白名单库拷进 lib/private 并改 soname + 建软链
# 严格对齐官方 build-binary.sh 的逻辑:
#   - soname 用"无版本号"名(libfoo.so,通过 awk $1.$2 取得)
#   - 改 soname + 在 lib/private 建无版本号软链
#   - 记录 LIBPATH 供 replace_libs 使用
gather_libs() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local elf
    while IFS= read -r elf; do
        [ -z "$elf" ] && continue
        local lib
        for lib in $LIBLIST; do
            local src
            while IFS= read -r src; do
                [ -z "$src" ] && continue
                local real base without_suffix
                real=$(readlink -f "$src")
                base=$(basename "$real")
                # 无版本号 soname:libprocps.so.7.1.0 -> libprocps.so
                # 用正则匹配 .so 前缀,兼容 liblber-2.4.so / libldap_r-2.4.so 这类库名带点的
                without_suffix=$(echo "$base" | sed -E 's/^((lib[A-Za-z0-9_.-]+)\.so).*/\1/')
                # 跳过软链源(避免拷成死链)和无版本号无法提取的库
                [ -L "$real" ] && continue
                [ "$base" = "$without_suffix" ] && continue
                # 无论库是否已存在,都记录到 LIBPATH(供 replace_libs 改 NEEDED 用)
                LIBPATH+=" $src"
                # 只在真实文件不存在时才拷贝;软链缺失时补建
                if [ ! -f "lib/private/$base" ]; then
                    echo "  + 收集 $base (soname -> $without_suffix)"
                    rm -f "lib/private/$base" "lib/private/$without_suffix"
                    cp -v "$real" lib/private/
                fi
                # 无论新拷还是已存在,都把 SONAME 改成无版本号(对齐官方)
                # 否则 NEEDED=libaio.so 与库 SONAME=libaio.so.1 不匹配会崩溃
                patchelf --set-soname "$without_suffix" "lib/private/$base" 2>/dev/null || true
                # 确保无版本号软链存在(对齐官方 soname 风格)
                if [ ! -e "lib/private/$without_suffix" ]; then
                    ln -sf "$base" "lib/private/$without_suffix"
                fi
            done < <(ldd "$elf" 2>/dev/null | grep "$lib" | awk '{print $3}' || true)
        done
    done < <(find "$dir" -maxdepth 1 -type f -exec file {} \; | grep 'ELF' | cut -d: -f1 || true)
}

# set_runpath: 设置 RPATH(用 --force-rpath 强制 DT_RPATH,而非默认 DT_RUNPATH)
set_runpath() {
    local dir="$1" rpath="$2"
    [ -d "$dir" ] || return 0
    local elf
    while IFS= read -r elf; do
        [ -z "$elf" ] && continue
        echo "  ~ RPATH  $elf -> $rpath"
        patchelf --force-rpath --set-rpath "$rpath" "$elf"
    done < <(find "$dir" -maxdepth 1 -type f -exec file {} \; | grep 'ELF' | cut -d: -f1 || true)
}

# replace_libs: 把 ELF 的 NEEDED 依赖名改成无版本号名(对齐官方)
# 例:libaio.so.1 -> libaio.so,libcrypto.so.10 -> libcrypto.so
# 逻辑:直接遍历每个 ELF 自己的 NEEDED 表,凡是 libX.so.数字 模式、
# 且对应的无版本号软链在 lib/private 里存在,就改成无版本号。
# 这样无论 bin/ lib/ lib/plugin/ lib/private/ 里的 ELF 都能正确处理。
replace_libs() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local elf
    while IFS= read -r elf; do
        [ -z "$elf" ] && continue
        # 取该 ELF 所有 NEEDED 项
        local needed
        while IFS= read -r needed; do
            [ -z "$needed" ] && continue
            # 只处理 libX.so.数字 这种带版本号的(无版本号的跳过)
            local devname
            devname=$(echo "$needed" | sed -E 's/^((lib[A-Za-z0-9_.-]+)\.so)\..*$/\1/')
            [ "$devname" = "$needed" ] && continue   # 不是 .so.X 形式,跳过
            # 只改 lib/private 里有无版本号软链的库(避免误改系统库如 libc.so.6)
            if [ -e "lib/private/$devname" ]; then
                echo "  ~ NEEDED $elf: $needed -> $devname"
                patchelf --replace-needed "$needed" "$devname" "$elf"
            fi
        done < <(readelf -d "$elf" 2>/dev/null | grep "NEEDED" | sed -E 's/.*\[(.*)\].*/\1/' || true)
    done < <(find "$dir" -maxdepth 1 -type f -exec file {} \; | grep 'ELF' | cut -d: -f1 || true)
}

gather_libs bin
gather_libs lib
[ -d lib/plugin ] && gather_libs lib/plugin

set_runpath bin '$ORIGIN/../lib/private'
set_runpath lib/private '$ORIGIN'
[ -d lib/plugin ] && set_runpath lib/plugin '$ORIGIN/../private'

replace_libs bin
replace_libs lib
[ -d lib/plugin ] && replace_libs lib/plugin
# lib/private 里的库可能相互依赖(如 libssl 依赖 libcrypto),也要处理
replace_libs lib/private

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
