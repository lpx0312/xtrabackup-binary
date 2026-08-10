# PXB 二进制打包 —— 容器化构建与迭代测试流程

> 本文档记录 Percona XtraBackup 二进制 tarball 的容器化构建方法、CI/CD 流水线,
> 以及一套 **"基础镜像 + 临时容器手动验证 + 回填"** 的迭代测试 SOP。任何对
> Dockerfile 或打包脚本的改动,都应按此流程验证通过后再合并。

## 目录结构

```
xtrabackup-binary/
├── base/                         # 基础镜像(编译环境,固定不变,可长期缓存)
│   ├── Dockerfile-glib2.17       # CentOS 7(glibc 2.17)编译环境
│   └── Dockerfile-glib2.28       # Rocky 8(glibc 2.28)编译环境
├── build/                        # 网络构建(构建时 curl 下载源码,适合 CI/有外网)
│   ├── Dockerfile                #   ARG: BASE_IMG_URL + BASE_SYSTEM_VERSION + PXB_VERSION
│   ├── pxb-build-binary.sh       #   编译+打包脚本(与 build-offline/ 保持一致)
│   ├── ci-build-binary.sh        #   CI: 拉基础镜像 → 编译 → --load + docker cp 提取 tarball
│   └── ci-build-image.sh         #   CI: 用 tarball 构建单架构发布镜像并推 ACR(合并由 workflow 做)
├── build-offline/                # 离线构建(本地 COPY 源码,适合无网/内网/本地调试)
│   ├── Dockerfile                #   ARG: BASE_IMAGE + PXB_TARBALL + BOOST_TARBALL
│   ├── pxb-build-binary.sh       #   编译+打包脚本(与 build/ 保持一致)
│   └── sources/
│       ├── download.sh           #   下载脚本(提交入库)
│       └── *.tar.gz/*.tar.bz2    #   由 download.sh 下载,不入库(见"已知差异")
├── .github/
│   ├── workflows/
│   │   ├── build-base-image.yml  # 手动触发: 构建并推送基础镜像(多架构)到 ACR
│   │   ├── build-binary.yml      # 手动触发: 编译 → 发 Release(只做二进制,不碰镜像)
│   │   └── build-image.yml       # 手动触发: 从 Release 拉 tarball → 打 Docker 镜像 → 推 ACR
│   └── actions/setup/            # 复合 action: 清磁盘 + QEMU + buildx
├── .gitattributes                # 强制 *.sh/*.yml 用 LF 换行
└── AGENTS.md                     # 本文档
```

**关键设计原则**:
- `base/` 只装编译依赖 + patchelf(≥ 0.18),不含源码,可长期复用、缓存。
- `build/` 和 `build-offline/` **共用同一份 `pxb-build-binary.sh`**(统一脚本,自动识别
  PXB 2.4 / 8.0+),区别只在源码/boost 的获取方式(curl 下载 vs COPY 本地)。
  > ⚠️ 当前两份脚本是**手动保持同步**的副本,仓库里没有"根目录主脚本"。改其中一份时,
  > 必须同步另一份(见 [迭代测试 SOP 第 9 步](#第-9-步回填验证通过后更新-dockerfile--脚本)
  > 与 [已知差异与待改进](#已知差异与待改进))。
- 二进制文件(源码包、boost 包)**不提交仓库**,由 `download.sh` 按需下载。

## 各目录角色速查

| 目录 | 源码获取 | 基础镜像来源 | 典型场景 |
|------|---------|-------------|---------|
| `base/` | — | 自建(从 Rocky/CentOS 官方镜像起步) | 产出可复用编译环境 |
| `build/` | 构建时 curl 下载 | **从 ACR 拉**(`${BASE_IMG_URL}/${BASE_SYSTEM_VERSION}`) | GitHub Actions / 有外网 |
| `build-offline/` | COPY 本地 `sources/` | **本地 tag**(`--build-arg BASE_IMAGE=...`) | 内网/无网/本地快速调试 |

> **本地调试选哪个?** `build-offline/Dockerfile` 接受任意 `BASE_IMAGE`(可以是本地 `docker build`
> 出来的 tag),最省事;`build/Dockerfile` 走 ACR,适合 CI。两者打包产物一致。

## CI/CD 流水线

GitHub Actions 提供三条手动触发的流水线(`workflow_dispatch`),**职责拆分**:基础镜像构建、
二进制编译、镜像打包各成独立流水线,互不耦合。每条流水线都经 `.github/actions/setup` 做磁盘清理
(`easimon/maximize-build-space`)+ QEMU + buildx。**多架构用原生 runner 并行**(不走 QEMU 模拟):
amd64 job 用 `ubuntu-latest`,arm64 job 用 `ubuntu-24.04-arm`(免费的原生 arm64 runner)。

> ⚠️ 不用 `strategy.matrix` + `runs-on: ${{ matrix.runner }}`。实测该写法在 GitHub 启动阶段
> 无法可靠解析动态 runner label,会触发 `startup_failure`。故每个架构拆成**独立 job**,
> `runs-on` 用静态字符串(commit `0683d07` 踩坑记录)。

```
build-base-image.yml          build-binary.yml              build-image.yml
  base 镜像(编译环境)          二进制 tarball                  发布镜像(Docker)
  ──────────────────          ──────────────────            ──────────────────
  build-amd64  (u-latest)  ─┐ compile-amd64  (u-latest)  ─┐ build-image-amd64 (u-latest)  ─┐
  build-arm64  (u-24.04-arm)┘ compile-arm64  (u-24.04-arm)┘ build-image-arm64 (u-24.04-arm)┘
        │                            │                            │
        ↓                            ↓                            ↓
   merge-manifest                release                  merge-manifest
   (合并多架构 tag)           (发版,挂两架构 tarball)        (合并多架构 tag)
```

> 架构说明:`u-latest` = `ubuntu-latest`(原生 amd64),`u-24.04-arm` = `ubuntu-24.04-arm`(原生 arm64)。

### 1. `build-base-image.yml` —— 构建并推送基础镜像

- **输入**:`glib_version`(`2.28` / `2.17`)、`architecture`(`all` / `amd64` / `arm64`,默认 all)、
  `zone`(区域加速:空=官方源;`cn`=南大镜像,国内 CI 加速 yum/DNF,默认空)。
- **行为**:`docker buildx build --platform <按 architecture 推导> -f base/Dockerfile-glib${GLIB}
  [--build-arg ZONE=cn] -t ${ACR}/${NS}/xtrabackup:base-glib-${GLIB} --push base/`。
- **用途**:`base/` 改动后跑一次,把新基础镜像(多架构)推到 ACR,供 `build-binary` 流水线拉取。

### 2. `build-binary.yml` —— 编译 + 发版(只做二进制,不碰镜像)

入参:`PXB_VERSION`(完整版本号,描述提示 8.0.35-36/2.4.29)、`glib_version`。
三个 job,**纯编译 + 发 Release**,镜像构建已拆到 `build-image.yml`:

| job | runner | 职责 |
|-----|--------|------|
| `compile-amd64` | `ubuntu-latest`(原生 amd64) | 调 `ci-build-binary.sh` 编译 → `--load` 载入本地 docker → `docker create`+`docker cp` 提取 tarball 到 `output/` → `upload-artifact`。**不登录 ACR**(只需匿名拉公开基础镜像) |
| `compile-arm64` | `ubuntu-24.04-arm`(原生 arm64) | 同上,arm64 |
| `release` (`needs: [compile-amd64, compile-arm64]`) | `ubuntu-latest` | `download-artifact` 合并两架构 → `softprops/action-gh-release@v2` 发到同一 tag `v<PXB>`(**不含 glib 后缀**)。同一 PXB 版本多次触发(不同 glib)会往同一 Release 累加 assets |

**Release 规则**:**版本以 PXB 为准**,tag 为 `v<PXB_VERSION>`(不含 glib 后缀)。
同一 PXB 版本选不同 `glib_version` 多次触发,产物**累积到同一个 Release**(tarball 文件名
含 `.glibc<ver>` + 架构后缀,不会冲突)。要凑齐全 4 组合(2 glib × 2 架构)需触发两次。
文件名由 `pxb-build-binary.sh` 的 `uname -m` + `ldd --version` 自动产生,如
`percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.28.tar.gz`。

### 3. `build-image.yml` —— 从 Release 拉二进制打 Docker 镜像(独立流水线)

**职责单一**:不编译,二进制由 `build-binary.yml` 产出并发布到 Release;本流水线只负责
把已发布的 tarball 打成 Docker 镜像推 ACR。可对**任意已发布的版本**单独重打镜像。

入参:`PXB_VERSION`、`glib_version`、`architecture`(`all` / `amd64` / `arm64`,默认 all)。

| job | runner | 触发条件 | 职责 |
|-----|--------|---------|------|
| `build-image-amd64` | `ubuntu-latest`(原生 amd64) | `architecture` ∈ {all, amd64} | 用 GitHub API 按 tag 查 Release assets → `wget` 对应架构 tarball 到 `output/`(公开仓库免鉴权)→ 登录 ACR → 调 `ci-build-image.sh` 推带 `-amd64` 后缀的单架构 tag |
| `build-image-arm64` | `ubuntu-24.04-arm`(原生 arm64) | `architecture` ∈ {all, arm64} | 同上,arm64 |
| `merge-manifest` (`needs: [build-image-amd64, build-image-arm64]`, `if: architecture==all`) | `ubuntu-latest` | 仅 all | `docker buildx imagetools create` 把 `-amd64` + `-arm64` 合并成不带后缀的多架构 tag |

**镜像 tag 规则**(由 `build-image.yml` 产出):
```
<ACR>/<NS>/xtrabackup:<PXB_VERSION>-glib<glib>-amd64     ← build-image job 产出
<ACR>/<NS>/xtrabackup:<PXB_VERSION>-glib<glib>-arm64     ← build-image job 产出
<ACR>/<NS>/xtrabackup:<PXB_VERSION>-glib<glib>           ← merge-manifest 合并的多架构 tag
```

**前置依赖**(缺失会在对应步骤报错):
1. **目标 Release 已发布对应 glib 的 tarball**:`build-binary.yml` 用相同 `PXB_VERSION` +
   `glib_version` 跑过,Release tag `v<PXB>` 下存在匹配 `<arch>.glibc<glib>` 的 tarball。
2. **基础镜像已推 ACR**:`build-base-image.yml` 推过 `base-glib-<glib>` 多架构 tag
   (`ci-build-image.sh` 的 FROM 依赖它)。

> **多架构合并为何用 `buildx imagetools create` 而非 `docker manifest create`**:
> `buildx --push` 推的单架构镜像本身也是 manifest list 格式,`docker manifest create`
> 不接受 manifest list 作为输入(报 "is a manifest list")。`imagetools create` 专门处理
> manifest list,能正确合并多架构。base image 流水线同理。

### CI 脚本职责

| 脚本 | 调用者 | 入参(env) | 作用 |
|------|--------|----------|------|
| `build/ci-build-binary.sh` | build-binary 的 compile-amd64/compile-arm64 job | `PXB_VERSION` `GLIB_VERSION` `ARCH` `BASE_IMG_URL` | 由 `GLIB_VERSION` 拼 `BASE_SYSTEM_VERSION=xtrabackup:base-glib-${GLIB}`,单架构 `buildx build --load` 载入本地 docker → `docker create`+`docker cp` 提取 tarball 到 `output/` |
| `build/ci-build-image.sh` | build-image 的 build-image-amd64/arm64 job | `PXB_VERSION` `GLIB_VERSION` `ARCH` `ALIYUN_*` | 从 `output/` 找 tarball(由 ci-build-binary.sh 产出**或从 Release 下载**)构建单架构镜像(FROM = PXB base 镜像),推带 `-amd64`/`-arm64` 后缀的 tag。**不做多架构合并**(交给 merge-manifest job)。脚本自身不登录 ACR,由调用方先 `docker login` |

> 关键点:`ci-build-binary.sh` 用 `--load` 载入镜像再 `docker create`+`docker cp` 提取产物,
> 而**不是** `--output type=local`。原因:buildx 用 `docker-container` 驱动(buildkitd 跑在
> 独立容器里),经 `easimon/maximize-build-space` 重挂载 `/var/lib/docker` 后,local exporter
> 往 host 写同步标记文件会 `permission denied`(报 "failed to create enable: openat enable")。
> `--load` 走 docker 标准存储再 `docker cp`,彻底绕开该坑。前提:runner 与目标镜像同架构
> ——已由原生 runner 保证(amd64 job 在 amd64 runner,arm64 job 在 arm64 runner)。
> `ci-build-image.sh` 与编译无耦合——只要 `output/` 有正确命名的 tarball 即可工作,
> 故 `build-image.yml` 从 Release 下载 tarball 后能直接复用。

### CI 环境变量

| 变量 | 含义 | 来源 |
|------|------|------|
| `PXB_VERSION` | PXB 完整版本号,透传给 `build/Dockerfile` 的 `ARG PXB_VERSION` | CI 输入(自由文本) |
| `GLIB_VERSION` | glibc 版本,决定 `base-glib-<X>` 基础镜像 | CI 输入(`2.28`/`2.17`) |
| `ARCH` | 目标架构(各 job 静态写入:compile-amd64 传 `amd64`,compile-arm64 传 `arm64`) | `amd64` / `arm64` |
| `ZONE` | 区域加速:空=官方源;`cn`=南大镜像 | build-base-image CI 输入(透传给 Dockerfile 的 `ARG ZONE`) |
| `BASE_IMG_URL` | 基础镜像仓库 URL | `${ACR}/${NS}` |
| `ALIYUN_REGISTRY` | ACR 地址 | repo var |
| `ALIYUN_NAME_SPACE` | ACR 命名空间 | repo var |
| `ALIYUN_REGISTRY_USER` / `_PASSWORD` | ACR 登录 | repo var / **secret** |
| `GITHUB_TOKEN` | 发 Release | 自动注入 |

### CI 所需的仓库配置(已配置完毕)

GitHub 仓库 **Settings → Variables / Secrets**(已在 `lpx0312/xtrabackup-binary` 配好):

- **Variables**:`ALIYUN_REGISTRY`、`ALIYUN_NAME_SPACE`、`ALIYUN_REGISTRY_USER`
- **Secrets**:`ALIYUN_REGISTRY_PASSWORD`

> 命名空间/账号与参考仓库 `lpx0312/dockerBuild` 一致。脚本里 ACR 变量也带默认值兜底
> (`registry.cn-hangzhou.aliyuncs.com` / `lpx03` / `lipanx`),方便本地手跑。

### 已知限制

- **PXB 2.4 + aarch64 + glibc2.17 需要 prctl 补丁**:PXB 2.4(基于 MySQL 5.7)在该组合下
  编译报 `prctl was not declared`,`pxb-build-binary.sh` 已内置条件 patch(仅此组合触发,
  给 `sql/mysqld.cc` 补 `#include <sys/prctl.h>`)。其它组合(8.0 / amd64 / glibc2.28)无此问题。
- glib2.17 的 `base/Dockerfile-glib2.17` 基于 `centos:7.9.2009`,Docker Hub 只有 amd64,
  但 Dockerfile 已用 vault `altarch` 源适配 arm64,**实测四组合(2 PXB × 2 glib)amd64+arm64 全部通过**。
- arm64 走**原生 runner** `ubuntu-24.04-arm`(不走 QEMU),编译约 20 分钟,与 amd64 并行,不互相阻塞。

## 为什么需要"临时容器手动验证"

直接用 `docker build` 测试应用 Dockerfile 有两个问题:
1. **每次失败都要从编译步骤重来**——PXB 8.0 编译要 30+ 分钟,反复试错代价极高。
2. **Dockerfile 出错时,中间产物都在镜像层里**,难以现场排查。

因此采用**分层验证**:基础镜像先构建好,然后基于它启动一个长期存活的临时容器,
把源码/boost/脚本 COPY 进去手动跑,边跑边改。验证通过后,把成功的步骤**回填**
到 Dockerfile 和脚本。这样:
- 编译产物在容器里**持久保留**,改打包逻辑不用重新编译。
- 排错时可以直接 `docker exec` 进容器现场调试。

## 迭代测试 SOP(完整流程)

### 第 0 步:准备本地资源(首次或网络不通时)

二进制源码包不入库,需先下载到 `build-offline/sources/`(离线场景)或
本地任意目录(临时容器场景):

```bash
# 方式 A:用 download.sh 下载(走外网或代理)
cd build-offline/sources
bash download.sh                    # 下载全部 4 个文件
# bash download.sh pxb80            # 只下 PXB 8.0.35-36
# bash download.sh pxb24            # 只下 PXB 2.4.29
# DOWNLOAD_PROXY=http://x:y bash download.sh   # 走代理

# 方式 B:手动准备(网络不通时,把已有文件放本地)
# 需要:percona-xtrabackup-<版本>.tar.gz + boost_<版本>.tar.bz2
```

### 第 1 步:构建基础镜像(改动 base/ 后才需重做)

```bash
cd base

# 默认(直连 GitHub 下 patchelf)
docker build -f Dockerfile-glib2.28 -t xtrabackup:base-glib-2.28 .
docker build -f Dockerfile-glib2.17 -t xtrabackup:base-glib-2.17 .

# 国内构建(yum/DNF 走南大镜像加速,也可在 CI 用 zone=cn)
docker build -f Dockerfile-glib2.28 --build-arg ZONE=cn -t xtrabackup:base-glib-2.28 .
docker build -f Dockerfile-glib2.17 --build-arg ZONE=cn -t xtrabackup:base-glib-2.17 .

# 内网走代理(下载 patchelf 时)
docker build -f Dockerfile-glib2.28 --build-arg GH_PROXY=https://gh.1102345.xyz/ \
           -t xtrabackup:base-glib-2.28 .

# 多架构(需要 buildx + QEMU)
docker buildx build --platform linux/amd64,linux/arm64 \
           -f Dockerfile-glib2.28 -t xtrabackup:base-glib-2.28 .
```

> `base/Dockerfile-glib2.28` 的 `FROM` 是
> `registry.cn-hangzhou.aliyuncs.com/lpx03/rockylinux:8.9.20231119`(ACR 上的定制 Rocky);
> `glib2.17` 基于 CentOS 7。本地构建需能拉到该基础镜像。

验证基础镜像关键组件:
```bash
docker run --rm xtrabackup:base-glib-2.28 bash -c '
  echo "patchelf: $(patchelf --version)";   # 应 >= 0.18(镜像装的是 0.19.1)
  echo "glibc:   $(ldd --version | head -1)";
  echo "gcc:     $(gcc -dumpversion)";
  rpm -q procps-ng-devel bzip2 || true;     # 应已装
'
```

### 第 2 步:启动临时容器,COPY 资源进去

按测试矩阵选择基础镜像,启动一个**长期存活**的容器(用 `sleep infinity`):

```bash
# 以 glib2.28 + PXB 8.0.35-36 为例
docker rm -f pxb-test 2>/dev/null
docker run -d --name pxb-test xtrabackup:base-glib-2.28 sleep infinity

# COPY 脚本 + 源码包 + boost 包(从本地准备好的文件)
docker cp build/pxb-build-binary.sh                  pxb-test:/root/
docker cp /path/to/percona-xtrabackup-8.0.35-36.tar.gz  pxb-test:/root/
docker cp /path/to/boost_1_77_0.tar.bz2                 pxb-test:/root/
```

> **Windows + Git Bash 注意**:`docker exec` 里写 `/root/` 会被 Git Bash 的
> 路径转换搞坏。要么用 `MSYS_NO_PATHCONV=1 docker exec ... bash -c '...'`,
> 要么命令里用 `//root/`(双斜杠)。后续示例统一加 `MSYS_NO_PATHCONV=1`。

### 第 3 步:容器内准备源码和 boost

按应用 Dockerfile 的逻辑,在容器里手动解压:

```bash
MSYS_NO_PATHCONV=1 docker exec pxb-test bash -c '
  cd /root
  # 解压 PXB 源码
  tar -xzf percona-xtrabackup-8.0.35-36.tar.gz
  # 解压 boost 到脚本期望位置:output/boost_<MYSQL版本>/(8.0) 或 boost_<PXB版本>/(2.4)
  mkdir -p /root/output/boost_8.0.35
  tar -xjf boost_1_77_0.tar.bz2 -C /root/output/boost_8.0.35 --strip-components=1
  # 确认 boost 目录结构
  ls /root/output/boost_8.0.35/boost/ >/dev/null && echo "boost OK"
'
```

> **boost 目录命名规则**(脚本 `pxb-build-binary.sh` 内部决定,这里要配合):
> - PXB 8.0+:`boost_<MYSQL_VERSION 主次patch>`,如 `boost_8.0.35`
>   (对应 `MYSQL_VERSION` 文件里的 8.0.35,不是 XB_VERSION 的 8.0.35-36)
> - PXB 2.4:`boost_<XB_VERSION 主次patch>`,如 `boost_2.4.29`
>   (2.4 没有 `MYSQL_VERSION` 文件)
> - Dockerfile 里还会在 `boost_<XB版本>` 与 `boost_<MYSQL版本>` 不一致时补建软链兜底。

### 第 4 步:容器内执行编译 + 打包(后台)

按应用 Dockerfile 最后一步的逻辑,后台跑脚本。注意要 source 对应的 gcc toolset
(glib2.28 用 gcc-toolset-12,glib2.17 用 devtoolset-11):

```bash
# 启动后台编译,日志写文件(避免长命令超时 / SIGPIPE)
MSYS_NO_PATHCONV=1 docker exec -d pxb-test bash -c '
  # glib2.28 用这个:
  source /opt/rh/gcc-toolset-12/enable 2>/dev/null || true
  # glib2.17 用这个:
  source /opt/rh/devtoolset-11/enable  2>/dev/null || true
  cd /root
  bash pxb-build-binary.sh percona-xtrabackup output > /root/build.log 2>&1
'
```

### 第 5 步:轮询进度,确认完成

PXB 8.0 编译约 20~40 分钟(取决于 CPU),2.4 约 10 分钟。轮询日志:

```bash
MSYS_NO_PATHCONV=1 docker exec pxb-test bash -c '
  ps aux | grep -qE "[c]c1plus|[m]ake" && echo "编译中" || echo "已结束"
  grep -oE "\[[0-9]+%\] Building" /root/build.log | tail -2
  grep -E ">>> \[|完成!|FAIL|Error|FATAL" /root/build.log | tail -3
'
```

### 第 6 步:验证产物(关键)

产物在容器的 `/root/output/percona-xtrabackup-*.glibc*.tar.gz`。验证三个对齐官方的
关键点 + 运行测试:

```bash
MSYS_NO_PATHCONV=1 docker exec pxb-test bash -c '
  STAGE=$(ls -d /root/output/stage-*/usr/local/percona-xtrabackup-* | head -1)
  echo "=== 产物目录: $STAGE ==="
  # 1. RPATH(应是 RPATH 不是 RUNPATH)
  readelf -d $STAGE/bin/xtrabackup | grep -iE "\(RPATH\)|\(RUNPATH\)"
  # 2. NEEDED 无版本号(libaio.so 而非 libaio.so.1)
  readelf -d $STAGE/bin/xtrabackup | grep NEEDED | grep -iE "aio|procps|ssl|crypto"
  # 3. ssl 自带(应从 lib/private 加载,不是 /lib64)
  ldd $STAGE/bin/xtrabackup | grep -iE "libssl|libcrypto"
  # 4. 运行测试(不应段错误)
  $STAGE/bin/xtrabackup --version
  echo "退出码: $?"
'
```

### 第 7 步:跨环境验证(拷到目标机跑)

编译机环境不纯净(有完整 ssl 等),必须拷到一台**没有同版本系统库**的机器验证
(这才是可移植性的真正考验):

```bash
# 从容器拷出 tarball
docker cp pxb-test:/root/output/percona-xtrabackup-8.0.35-36-Linux-x86_64.glibc2.28.tar.gz ./

# 上传到目标机(如 KylinV10 SP3,glibc 2.28 但 ssl 版本不同)
scp *.tar.gz root@192.168.1.45:/root/

# 目标机验证
ssh root@192.168.1.45 "
  rm -rf /tmp/v && mkdir /tmp/v
  tar -xzf /root/percona-xtrabackup-*.glibc*.tar.gz -C /tmp/v
  DIR=\$(ls -d /tmp/v/percona-xtrabackup-*)
  ldd \$DIR/bin/xtrabackup | grep 'not found' && echo '✗ 缺失' || echo '✓ 无缺失'
  \$DIR/bin/xtrabackup --version
"
```

### 第 8 步:清理临时容器

```bash
docker rm -f pxb-test
```

### 第 9 步:回填(验证通过后更新 Dockerfile / 脚本)

临时容器里手动执行的命令,本质就是应用 Dockerfile 的步骤。验证通过后:

1. **对比**临时容器里实际执行的命令 vs `build/Dockerfile` / `build-offline/Dockerfile`
   里的对应 RUN 段,把差异(新增依赖、修复的逻辑)**写回两个 Dockerfile**。
   注意两者 ARG 不同(`build/` 用 `PXB_VERSION` + curl,`build-offline/` 用
   `PXB_TARBALL`/`BOOST_TARBALL` + COPY),别抄错。
2. **同步 `pxb-build-binary.sh` 到两处**(`build/` 和 `build-offline/`,内容必须逐字节一致):
   ```bash
   # 任选一份作为改动的源头,覆盖另一份后用 diff 验证
   cp build/pxb-build-binary.sh build-offline/pxb-build-binary.sh
   diff build/pxb-build-binary.sh build-offline/pxb-build-binary.sh && echo "已同步"
   ```
3. 如改了基础镜像依赖(如新增 `procps-ng-devel`),回填 `base/Dockerfile-glib2.*` 并
   **重新构建基础镜像**(第 1 步);若走 CI,还要重跑 `build-base-image.yml` 推到 ACR。

### 第 10 步:用 Dockerfile 端到端验证

临时容器验证只能证明"命令本身对",最后一定要用完整的 `docker build` 跑一遍
应用 Dockerfile,确认 Dockerfile 的编排逻辑也正确:

```bash
# === 离线版(推荐本地用:接受本地基础镜像 tag,需先 download.sh 准备 sources/)===
cd build-offline
docker build -f Dockerfile \
    --build-arg BASE_IMAGE=xtrabackup:base-glib-2.28 \
    --build-arg PXB_TARBALL=percona-xtrabackup-8.0.35-36.tar.gz \
    --build-arg BOOST_TARBALL=boost_1_77_0.tar.bz2 \
    -t xtrabackup:8.0.35-36-glib2.28 .

# === 网络版(CI 用:基础镜像从 ACR 拉,构建时 curl 下载源码)===
# 注意 ARG 与离线版不同:BASE_IMG_URL + BASE_SYSTEM_VERSION 组成基础镜像全名,
# PXB_VERSION 决定下载哪个版本。基础镜像必须已推到 ACR(或 BASE_IMG_URL 指向本地 registry)。
cd ../build
docker build -f Dockerfile \
    --build-arg BASE_IMG_URL=registry.cn-hangzhou.aliyuncs.com/lpx03 \
    --build-arg BASE_SYSTEM_VERSION=xtrabackup:base-glib-2.28 \
    --build-arg PXB_VERSION=8.0.35-36 \
    -t xtrabackup:8.0.35-36-glib2.28 .

# 提取产物(两种 Dockerfile 都把产物放到 /root/pxb-final.tar.gz)
docker create --name tmp xtrabackup:8.0.35-36-glib2.28
docker cp tmp:/root/pxb-final.tar.gz .
docker rm tmp
```

## 测试矩阵

每次改动应覆盖足够多的组合。已知可行的组合:

| 组合 | 基础镜像 | PXB 版本 | boost | 用途 |
|------|---------|---------|-------|------|
| A | base-glib-2.28 | 8.0.35-36 | 1.77.0 | 主流(Rocky8/KylinV10) |
| B | base-glib-2.17 | 8.0.35-36 | 1.77.0 | 老 glibc 兼容性 |
| C | base-glib-2.17 | 2.4.29 | 1.59.0 | 老版本 PXB(MySQL 5.7) |

> CI 的 `PXB_VERSION` 是自由文本输入(默认 `8.0.35-36`,描述里提示 8.0.35-36/2.4.29),
> 理论上可填任意 Percona 发布过的版本。`download.sh` 清单只有 8.0.35-36/2.4.29,
> 离线构建其它版本(如 8.4.x)需自行准备源码;`build/` 走网络下载不受此限制。

跨环境验证目标机建议:
- **KylinV10 SP3**(glibc 2.28,但 ssl 是 1.1.1):验证 ssl 自包含
- **Rocky8 / CentOS8**(glibc 2.28):验证 glib2.28 产物
- 任意 glibc ≥ 编译机的发行版:验证向后兼容

## 关键技术要点(踩坑总结)

这些是打包逻辑必须对齐官方的地方,改动 `pxb-build-binary.sh` 时务必保持:

1. **patchelf 必须 ≥ 0.18**(基础镜像已装 0.19.1)
   - 0.10 版本对 PXB 这种 256-notes 的大 ELF 处理 `--force-rpath` / `--set-soname`
     会**静默失败**(退出码 0 但实际没改)。这是最大的坑。
   - 必须用 `--force-rpath --set-rpath`(顺序不能反,反了会生成 RUNPATH 而非 RPATH)。

2. **RPATH 而非 RUNPATH**:`patchelf --force-rpath --set-rpath '$ORIGIN/../lib/private'`
   - 官方包用 DT_RPATH(`0xf`),不是 DT_RUNPATH(`0x1d`)。RPATH 会传递给依赖库,
     RUNPATH 不会,影响库依赖库的场景。

3. **NEEDED 改成无版本号 + SONAME 改成无版本号**(对齐官方)
   - 二进制的 NEEDED 从 `libssl.so.10` → `libssl.so`(用 `--replace-needed`)
   - 库文件的 SONAME 也改成 `libssl.so`(用 `--set-soname`)
   - lib/private 里建无版本号软链:`libssl.so -> libssl.so.1.0.2k`
   - **三者必须同时改**,否则会段错误(NEEDED 找得到文件但 SONAME 不匹配)。
   - replace_libs 要覆盖 `bin/`、`lib/`、`lib/plugin/`、`lib/private/`(库会相互依赖,
     如 libssl 依赖 libcrypto)。

4. **ssl/crypto 必须收集到 lib/private**(白名单含 `libssl.so libcrypto.so`)
   - 否则跨发行版会缺库(CentOS7 编的依赖 `libssl.so.10`,KylinV10 只有 `libssl.so.1.1`)。
   - 官方包就是这么做的(glibc2.17 包自带 ssl,任何机器都能跑)。

5. **boost 版本自动识别**:网络版从 `cmake/boost.cmake` 读 `BOOST_PACKAGE_NAME`,
   统一下载 `.tar.bz2`。不要依赖源码里的 URL(2.4 的是 jenkins.percona.com 内网地址)。

6. **`set -euo pipefail` + 管道的坑**:脚本里所有 `grep`/`awk` 管道必须加 `|| true`,
   否则 grep 无匹配返回 1 会触发 `set -e` 静默退出(排查极难)。

7. **CentOS 7 / EPEL 7 已 EOL,必须用存档源**(glib2.17 基础镜像)
   - 镜像内 `mirrorlist.centos.org` 和 `dl.fedoraproject.org/pub/epel/7/` 都已下架(404)。
   - **vault 源**(CentOS 7 base/updates/extras/SCL):`ZONE` 决定用哪个存档——
     - 默认(海外):`https://vault.centos.org/centos/...`(注意 `vault.centos.org` 后**必须带 `/centos`**,
       少了这段会 404)。arm64 用 `https://vault.centos.org/altarch/...`(altarch 根无需 `/centos`)。
     - `cn`(南大):`https://mirror.nju.edu.cn/centos-vault/centos/...`
       (arm64 用 `.../centos-vault/altarch/...`)。
   - **EPEL 源**:同样 EOL,默认主站 `dl.fedoraproject.org/pub/epel/7/` 已 404。改用:
     - 默认(海外):`https://archives.fedoraproject.org/pub/archive/epel/7/...`
     - `cn`(南大):`https://mirror.nju.edu.cn/epel/7/...`
   - Dockerfile 里用 `ZONE` ARG 统一控制这两个源,改路径时**默认分支和 cn 分支都要核对**
     (曾因只测了 cn 路径、默认分支漏了 `/centos` 段导致 CI 404)。

## 版本/路径速查

| 项 | 8.0.35-36 | 2.4.29 | 8.4.x(CI 可构建) |
|----|-----------|--------|------------------|
| MySQL 基线 | 8.0.35 | 5.7.44 | 8.4.0 |
| `MYSQL_VERSION` 文件 | 有 | **无**(版本号全用 XB_VERSION) | 有 |
| boost 需求 | 1.77.0(`.tar.bz2`) | 1.59.0(`.tar.bz2`) | 自动从 `boost.cmake` 识别 |
| boost 目录名 | `boost_8.0.35`(MYSQL 版本号) | `boost_2.4.29`(XB 版本号) | 同 8.0 规则 |
| cmake `DOWNLOAD_BOOST` | 支持 | **不支持**(必须本地提供) | 支持 |
| gcc toolset | gcc-toolset-12(glib2.28) / devtoolset-11(glib2.17) | devtoolset-11(glib2.17) | 同 8.0 |
| `download.sh` 清单 | ✓ | ✓ | ✗(需自行准备/走网络版) |

## 下载地址(URL 已核实)

```
# PXB 源码(Percona 官方)
https://downloads.percona.com/downloads/Percona-XtraBackup-8.0/Percona-XtraBackup-8.0.35-36/source/tarball/percona-xtrabackup-8.0.35-36.tar.gz
https://downloads.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-2.4.29/source/tarball/percona-xtrabackup-2.4.29.tar.gz

# boost(archives.boost.io,所有版本都有 .tar.bz2)
https://archives.boost.io/release/1.77.0/source/boost_1_77_0.tar.bz2
https://archives.boost.io/release/1.59.0/source/boost_1_59_0.tar.bz2

# patchelf(GitHub releases,多架构:amd64→x86_64,arm64→aarch64)
https://github.com/NixOS/patchelf/releases/download/0.19.1/patchelf-0.19.1-x86_64.tar.gz
```

### 官方下载渠道(参考)

本项目从源码编译,产出便携式二进制。如需 Percona 官方原版(rpm/deb 包、按平台选择的 tarball):

- **官方下载中心**:<https://www.percona.com/downloads/> —— 按产品/版本/平台筛选,含 XtraBackup
  的二进制 tarball 及安装说明。
- **官方软件包仓库**:<https://repo.percona.com/> —— rpm/deb 仓库,XtraBackup 在:
  - `pxb-24/` —— PXB 2.4
  - `pxb-80/` —— PXB 8.0
  - `pxb-84-lts/` —— PXB 8.4 LTS
  - `pxb-8x-innovation/` —— PXB 8.x 创新版
- **PXB 官方文档**:<https://docs.percona.com/percona-xtrabackup/>

## 已知差异与待改进

记录文档与代码、或代码内部的不一致,改动时优先处理:

1. **缺少 `.gitignore`**:文档说"二进制不入库,gitignore 忽略",但仓库**没有** `.gitignore`。
   目前 `build-offline/sources/*.tar.*` 只是恰好没被 `git add`,存在误提交风险。
   建议新增:
   ```gitignore
   # build-offline 源码/boost 包(由 download.sh 按需下载)
   build-offline/sources/*.tar.gz
   build-offline/sources/*.tar.bz2
   build-offline/sources/*.tar.xz
   # 编译产物
   output/
   ```

2. **`pxb-build-binary.sh` 没有唯一源头**:两份副本(`build/`、`build-offline/`)手动同步,
   没有"根目录主脚本"。建议二选一:(a) 在根目录放主脚本、两处改为软链或 CI 拷贝;
   (b) 在 CI 里加一步 `diff` 校验两份一致,防止漂移。

3. **`download.sh` 清单不含 8.4.x**:CI 的 `PXB_VERSION` 是自由输入可填任意版本,但
   `build-offline/sources/download.sh` 的 `FILES`/`ALIAS` 只有 8.0.35-36 和 2.4.29。
   要离线构建其它版本(如 8.4.x),需手动准备源码,或补 `download.sh` 条目。
