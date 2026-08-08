# Percona XtraBackup 便携二进制 & Docker 镜像

容器化构建 [Percona XtraBackup](https://github.com/percona/percona-xtrabackup) 的便携式二进制 tarball
和 Docker 镜像。二进制自带运行时依赖(ssl / crypto / libaio / procps 等),**跨发行版可移植**——
在 glibc ≥ 编译版本的任意 Linux 上解压即用。

## 支持的版本

每个 PXB 版本一个 Release,下含该版本的全部 glibc × 架构组合:

| PXB 版本 | glibc | boost | 架构 | 适用场景 |
|----------|-------|-------|------|---------|
| 8.0.35-36 | 2.17(CentOS 7)/ 2.28(Rocky 8) | 1.77.0 | amd64 + arm64 | 主流(MySQL 8.0) |
| 2.4.29 | 2.17(CentOS 7)/ 2.28(Rocky 8) | 1.59.0 | amd64 + arm64 | 老版本(MySQL 5.7) |

---

## 一、使用二进制(下载即用)

已发布的二进制在 [Releases](../../releases) 页面。**Release 版本以 PXB 版本为准**(如 `v8.0.35-36`),
一个 Release 下汇总该 PXB 版本的全部变体——文件名含架构与 glibc 后缀以区分:

```
percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.17.tar.gz      # amd64 + glibc 2.17
percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.28.tar.gz      # amd64 + glibc 2.28
percona-xtrabackup-8.0.35-36-Linux-aarch64.glibc2.17.tar.gz     # arm64 + glibc 2.17
percona-xtrabackup-8.0.35-36-Linux-aarch64.glibc2.28.tar.gz     # arm64 + glibc 2.28
```

### 如何选择包

按目标机的 **CPU 架构** + **glibc 版本** 选对应 tarball:

```bash
uname -m           # x86_64 = amd64,aarch64 = arm64
ldd --version      # 看 glibc 版本(第一行末尾)
```

> **向后兼容**:glibc 2.17 的包能在 ≥ 2.17 的任何系统跑。不确定就选低版本(2.17),兼容性最广。

### 安装(以 glibc2.28 + x86_64 为例)

```bash
# 1. 解压并固定目录名(避免版本号路径)
tar -xzf percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.28.tar.gz -C /usr/local/
mv /usr/local/percona-xtrabackup-* /usr/local/xtrabackup

# 2. 加入 PATH(永久生效)
echo 'export PATH=/usr/local/xtrabackup/bin:$PATH' >> /etc/profile
source /etc/profile

# 3. 检查动态链接库(应无 not found 输出)
ldd /usr/local/xtrabackup/bin/xtrabackup | grep "not found"

# 4. 测试
xtrabackup --version
```

无需安装任何系统依赖——ssl/crypto/libaio/procps 等已打包进 `lib/private`,通过 RPATH 自动加载。

## 二、使用 Docker 镜像

镜像已推送到阿里云 ACR,支持多架构(`linux/amd64` + `linux/arm64`):

```bash
docker pull registry.cn-hangzhou.aliyuncs.com/lpx03/xtrabackup:8.0.35-36-glib2.28

docker run --rm registry.cn-hangzhou.aliyuncs.com/lpx03/xtrabackup:8.0.35-36-glib2.28 --version
```

镜像 ENTRYPOINT 是 `xtrabackup`,可直接传参:

```bash
docker run --rm \
  -v /data:/data \
  registry.cn-hangzhou.aliyuncs.com/lpx03/xtrabackup:8.0.35-36-glib2.28 \
  --backup --target-dir=/data/backup
```

> Docker 镜像 tag 规则:`<PXB版本>-glib<glibc版本>`,如 `8.0.35-36-glib2.28`。

---

## 三、CI 流水线(三条独立工作流,手动触发)

三条 GitHub Actions 工作流各司其职,**完全独立**触发:

```
build-base-image.yml   →  产出编译环境基础镜像(ACR)
build-binary.yml       →  编译 + 发 Release(纯二进制,不碰镜像)
build-image.yml        →  从 Release 拉 tarball → 打 Docker 镜像 → 推 ACR
```

在仓库 **Actions** 页面选对应工作流 → `Run workflow` → 填参数即可。

### 1. 构建基础镜像(`build-base-image.yml`)

编译环境的依赖打成一个可复用镜像,推到 ACR。**改了 `base/` 才需要重跑**,正常情况下跑一次长期复用。

| 参数 | 说明 | 示例 |
|------|------|------|
| `glib_version` | glibc 版本,决定用哪个 Dockerfile | `2.28` / `2.17` |
| `architecture` | 目标架构 | `all`(amd64+arm64) / `amd64` / `arm64` |
| `zone` | yum 源区域加速 | 空(官方源) / `cn`(南大镜像,国内加速) |

产出 tag:`<ACR>/<NS>/xtrabackup:base-glib-<glib>`(多架构)。

### 2. 编译二进制(`build-binary.yml`)

用基础镜像编译 PXB,产出便携式 tarball 并发到 GitHub Release。**Release 版本以 PXB 版本为准**——
同一 PXB 版本选不同 `glib_version` 多次触发,产物会**累积到同一个 Release**(tag `v<PXB>`)。

| 参数 | 说明 | 示例 |
|------|------|------|
| `PXB_VERSION` | PXB 完整版本号(决定 Release tag) | `8.0.35-36` / `2.4.29` |
| `glib_version` | glibc 版本(决定用哪个基础镜像 + tarball 的 glibc 后缀) | `2.28` / `2.17` |

产出:Release tag `v<PXB>`,每次追加该 glib 的两架构 tarball。
要凑齐全 4 个组合(2 glib × 2 架构),需用相同 `PXB_VERSION` 触发两次(`glib_version` 分别选 2.17 / 2.28)。

> ⚠️ 前置:对应 `base-glib-<glib>` 基础镜像已推到 ACR(先跑工作流 1)。

### 3. 构建 Docker 镜像(`build-image.yml`)

从已发布的 Release 下载 tarball,打成 Docker 镜像推到 ACR。可对**任意已发布版本**单独重打镜像。

| 参数 | 说明 | 示例 |
|------|------|------|
| `PXB_VERSION` | 对应已发布的 Release tag(不含 glib 后缀) | `8.0.35-36` |
| `glib_version` | 要打镜像的 glibc 版本(决定下哪个 tarball) | `2.28` |
| `architecture` | 目标架构 | `all` / `amd64` / `arm64` |

产出 tag:`<ACR>/<NS>/xtrabackup:<PXB>-glib<glib>`(多架构)。

> ⚠️ 前置:① 目标 Release 已发布对应 glib 的 tarball(先跑工作流 2);② `base-glib-<glib>` 基础镜像已在 ACR。

### 典型完整流程(从零到镜像)

```
1. build-base-image.yml   glib=2.28, arch=all, zone=cn   →  base-glib-2.28 推 ACR
2. build-binary.yml       PXB=8.0.35-36, glib=2.28        →  Release v8.0.35-36(追加 glib2.28 的 tarball)
3. build-image.yml        PXB=8.0.35-36, glib=2.28, all   →  xtrabackup:8.0.35-36-glib2.28 镜像
```

> 想让一个 PXB 版本的 Release 凑齐全 4 个组合(2 glib × 2 架构):用相同 `PXB_VERSION`
> 把工作流 2 跑两次(`glib_version` 分别 2.17 / 2.28),产物累积到同一个 `v<PXB>` Release。

amd64 / arm64 各用原生 runner 并行编译(`ubuntu-latest` + `ubuntu-24.04-arm`),不走 QEMU。

---

## 四、本地构建

不想走 CI 也可以本地构建。离线版(`build-offline/`)适合无网/内网环境。

### 1. 构建基础镜像

```bash
cd base

# glib2.28(Rocky 8,多架构)
docker build -f Dockerfile-glib2.28 -t xtrabackup:base-glib-2.28 .
# 国内构建加速(南大镜像源)
docker build -f Dockerfile-glib2.28 --build-arg ZONE=cn -t xtrabackup:base-glib-2.28 .
# 多架构(需 buildx + QEMU)
docker buildx build --platform linux/amd64,linux/arm64 -f Dockerfile-glib2.28 -t xtrabackup:base-glib-2.28 .
```

### 2. 构建二进制

```bash
# 先下载源码包到 build-offline/sources/
cd build-offline/sources && bash download.sh && cd ../../

# 离线构建(接受本地基础镜像 tag)
cd build-offline
docker build -f Dockerfile \
    --build-arg BASE_IMAGE=xtrabackup:base-glib-2.28 \
    --build-arg PXB_TARBALL=percona-xtrabackup-8.0.35-36.tar.gz \
    --build-arg BOOST_TARBALL=boost_1_77_0.tar.bz2 \
    -t xtrabackup:8.0.35-36-glib2.28 .

# 提取产物
docker create --name tmp xtrabackup:8.0.35-36-glib2.28
docker cp tmp:/root/pxb-final.tar.gz .
docker rm tmp
```

> `download.sh` 清单含 8.0.35-36 / 2.4.29;其它版本需自行准备源码包,或用网络版 `build/`(构建时 curl 下载)。

### 3. 验证产物可移植性

编译机环境不纯净,务必拷到**没有同版本系统库**的机器验证:

```bash
tar -xzf percona-xtrabackup-*.glibc*.tar.gz -C /tmp/
DIR=$(ls -d /tmp/percona-xtrabackup-*)

# 检查依赖无缺失
ldd $DIR/bin/xtrabackup | grep 'not found' && echo '✗ 缺失' || echo '✓ 无缺失'
$DIR/bin/xtrabackup --version
```

---

## 目录结构

```
xtrabackup-binary/
├── base/                 # 基础镜像(编译环境,固定不变,可长期缓存)
│   ├── Dockerfile-glib2.17   # CentOS 7(glibc 2.17)
│   └── Dockerfile-glib2.28   # Rocky 8(glibc 2.28)
├── build/                # 网络构建(CI 用:构建时 curl 下载源码)
├── build-offline/        # 离线构建(本地用:COPY 本地源码,适合无网/内网)
│   └── sources/download.sh   # 下载脚本(二进制包不入库)
└── .github/workflows/    # 三条 CI 流水线
    ├── build-base-image.yml  # 基础镜像
    ├── build-binary.yml      # 二进制编译 + 发 Release
    └── build-image.yml       # 从 Release 打 Docker 镜像
```

## 技术要点

- **patchelf ≥ 0.18**:旧版对大 ELF 处理 `--force-rpath`/`--set-soname` 会静默失败
- **RPATH 而非 RUNPATH**:`$ORIGIN/../lib/private`,RPATH 会传递给依赖库的依赖
- **ssl/crypto 自带**:白名单收集到 `lib/private`,避免跨发行版缺库(如 CentOS7 的 `libssl.so.10` vs KylinV10 的 `libssl.so.1.1`)
- **NEEDED + SONAME 改无版本号**:三者必须同时改,否则段错误

> 详细的容器化构建方法、迭代测试 SOP、踩坑记录见 [AGENTS.md](AGENTS.md)。

## 已知限制

- 全部 4 组合(PXB 8.0.35-36 / 2.4.29 × glibc 2.17 / 2.28)的 amd64 + arm64 均已构建通过
- **CI 所需仓库配置**(已配好):Variables `ALIYUN_REGISTRY` / `ALIYUN_NAME_SPACE` / `ALIYUN_REGISTRY_USER`,Secret `ALIYUN_REGISTRY_PASSWORD`
