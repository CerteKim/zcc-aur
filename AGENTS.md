# AGENTS.md — 本仓库的维护说明

给 AI agent 和未来的维护者。**面向用户/安装者的说明在 [README.md](README.md)**，
这里只写「怎么改这个仓库」以及改的时候容易踩的东西。

---

## 0. 一句话

`zcc-aur` 是 Xiaomi Book S 12.4（`xiaomi,book-12.4`，Qualcomm **SC8180X** / TIMI）
那台 aarch64 笔记本跑 Arch Linux ARM 所需的 pacman 包装配。仓库只放**打包元数据**
（PKGBUILD、内核补丁、单元/规则文件）；厂商固件与传感器注册表是专有数据，不进 git；
`repo/` 与 `packages/*/{src,pkg}/` 是产物，也不进 git。

目标不是「能编译」，而是**能被本机安装并正常启动**。涉及启动链（GRUB、DTB、
initramfs、DKMS 模块优先级）的改动要格外小心。

---

## 1. 硬约束

1. **永远不要建议或执行 `grub-install`**（包括 `--removable`）。本机在用的 GRUB 核
   是从 linux-surface 的 Surface Pro X 试验镜像里拿的、内嵌板级 DTB 的那一份；
   ALARM 的 `grub` 包构建出来的核在本机进不了菜单。`grub-mkconfig` 可以随便跑。
2. **`/etc` 会盖住 `/usr/lib`**。任何 `systemd` 单元 / udev 规则 / initcpio hook，
   只要 `/etc` 下还留着手工时代的同名文件，包内那份就静默失效。相关 `.install`
   都会提示，删的时候要连 `daemon-reload` / 重登一起说清楚。
3. **打包用的 `sha256sums` 必须和文件同步**。`xiaomi-book-12.4-config`、
   `iio-sensor-proxy-ssc`、`rmtfs`、`xiaomi-book-12.4-firmware`（hook 那一项）用的是
   真实哈希；改了对应源文件就要重算，否则 makepkg 直接失败。其余本地文件是 `SKIP`。
4. **内核补丁必须是 4 位数字前缀、平铺在包目录里**，因为 `makepkg` 按 basename 把本地
   源拷进 `$srcdir`，补丁不能放子目录（`_patches=([0-9][0-9][0-9][0-9]-*.patch)`）。
5. **改包内容（含 `.install`、单元文件、hook）就要 bump `pkgrel`**；改 `pkgver` 时
   记得同步 `dkms.conf` 里的 `PACKAGE_VERSION` 与 `.install` 里的 `FALLBACK_VER`。

---

## 2. 目录结构

```
packages/<pkgname>/       每个包一个目录，makepkg 在这里跑
  PKGBUILD
  *.patch                 iio-sensor-proxy-ssc / rmtfs / linux-mibook-mainline
  *.install               pacman 钩子（提示、DKMS 重建、disable 单元）
  0001..0036-*.patch      linux-mibook-mainline 的补丁集（平铺）
  base.config             linux-mibook-mainline：ALARM bring-up 配置
  xiaomi-only.config      在其上的精简片段（含两个不能删的选项，见 §5）
scripts/
  build.sh                构建 packages/ 下的包并登记进 repo/
  publish.sh              把 db + 全部包发成一个 GitHub Release
repo/                     gitignored：本地 pacman 仓库（db + 二进制包）
README.md                 面向构建/安装的人
AGENTS.md                 本文件
```

`packages/*/src/`、`packages/*/pkg/`、`packages/<vcs-pkg>/<pkgname>/`（makepkg 的
VCS 检出）、`packages/*/*.tar.{gz,xz,zst}` 全部 gitignored。本机磁盘上这些加起来
约 15 GB（内核源码占绝大部分）。

---

## 3. 构建与发布

```sh
./scripts/build.sh                    # 全部包
./scripts/build.sh ra9530-dkms        # 单个/多个
./scripts/build.sh --list             # repo/ 里现有什么
./scripts/build.sh --db               # 只重建 db
./scripts/build.sh --collect <dir>    # 收编别处构建好的 *.pkg.tar.*
./scripts/publish.sh                  # 需要 gh + 已登录
```

* `build.sh` 用 `makepkg --nodeps --force --cleanbuild --noconfirm`，
  **不会自动装依赖** —— 装依赖是人的事（README §3.1 有清单）。
* `prune_old()` 按**每个文件自己解析出的 pkgname**分组，不能用前缀 glob：
  `linux-mibook-mainline` 是 `linux-mibook-mainline-headers` 的前缀，前缀 glob 会让
  前者把后者吞进来，然后「保留最新」把内核包删掉、只留 `-headers`。
* `prune_old()` 只删**同名包的旧版本**。`repo/` 里如果还留着**已 retirement 的包**
  （例如 `xiaomi-book-12.4-tools-*.pkg.tar.xz`），`--db` 不会清掉它，`publish.sh`
  会照样发出去。发布前先手动确认 `repo/` 里没有废弃包。
* 发布必须**一次性上传 db + 全部包**：客户端用
  `releases/latest/download`，每个 Release 都得是完整快照。

### 依赖链（构建顺序）

`qmic` → `pd-mapper` / `rmtfs` / `tqftpserv`（`makedepends=('git' 'qmic')`）。
`qrtr` 是它们的运行时依赖。`build.sh` 按目录名顺序构建，**不是拓扑序**，所以
从零构建时可能要跑两遍，或者先单独构建 `qrtr`/`qmic`。

---

## 4. 两个包无法从仓库独立构建

`xiaomi-book-12.4-firmware` 与 `xiaomi-book-12.4-sensors` 的 tarball 来自本机
Windows 安装的厂商数据，**不进 git，仓库里也没有采集脚本**（这是有意的策略：
不公开发布专有数据）。PKGBUILD 头部注释写了各自需要的文件清单与目标布局。
正常情况下这两个包只从 Release 装二进制，不要试图「修复」它们的 `sha256sums=('SKIP')`。

---

## 5. 内核包（`linux-mibook-mainline`）

* 源是 `cdn.kernel.org` 的 `linux-7.2.tar.xz`，delta 是平铺的 36 个补丁，
  它们是分支 `xiaomi-mainline-7.2`（基线 `upstream-v7.2`）的 `git format-patch` 导出。
* `arch=("aarch64")`，`options=("!strip")`，`makedepends` 见 PKGBUILD。
* 安装布局（`/boot` 下都是自己的名字，可与别的内核并存）：

  ```
  /boot/vmlinuz-linux-mibook-mainline
  /boot/initramfs-linux-mibook-mainline.img
  /boot/dtb/linux-mibook-mainline/qcom/sc8180x-xiaomi-book-12.4.dtb
  ```

### 5.1 `xiaomi-only.config` 里不能删的选项

| 选项 | 为什么 |
|---|---|
| `CONFIG_DRIVER_DEFERRED_PROBE_TIMEOUT=-1` | 7.2 把这个 delay 的默认值变成 10 秒。本机 GPU 偶尔 10 秒后才就位，内核一放弃依赖 `msm-mdss` 就探测失败，显示子系统整个起不来 —— 表现为**背光亮着的白屏**。负值 = 无限等，等同 6.18 那棵树里的板级 hack。 |
| `CONFIG_DRM_PANEL_HIMAX_HX83121A=m` | 必须是 `=m`，`panel-himax-hx83121a-dkms` 才有机会通过 depmod 的 `updates` 优先级覆盖它。`=y` 则内建驱动先绑定面板节点，DKMS 那份永远用不上。 |

`base.config` 是这台机器 bring-up 用的 ALARM 配置；`prepare()` 用
`merge_config.sh` 合并后跑 `olddefconfig`，7.2 新增/删除的符号由它处理。

### 5.2 维护补丁集

权威副本是内核开发分支（公开在 <https://github.com/CerteKim/linux-a51>）。
仓库里的 `00??-*.patch` 是导出产物。

* **摘提交**：在开发树里 `git rebase -i` 删行（`GIT_SEQUENCE_EDITOR` 非交互），
  不要用 `git revert` —— 那会在序列里留下垃圾提交。改写前把旧 tip 记到
  `refs/backup/...`。摘完**重新导出并重新编号**。
* **重新导出**：`git format-patch -o <pkgdir> upstream-v7.2..xiaomi-mainline-7.2`，
  先清掉旧的 `00??-*.patch`。
* **跟进上游基线**：fetch 新 tag（如 `v7.3`）→ 在开发树 rebase → 重新导出 →
  PKGBUILD 里改 `pkgver`/`pkgrel`、tarball URL、`sha256sums` 第一项。
* `makepkg -e`（`--noextract`）**不会**刷新 `$srcdir` 里的补丁或重新应用它们；
  补丁增删后要么手工同步 `src/linux-7.2`，要么全量重建。

### 5.3 几个值得记住的补丁（改序列前先读）

| 补丁 | 内容 |
|---|---|
| 0028 | `drm/msm/adreno: restore the CX GBIF config on A640 and A680`。上游 `60a4e18e0e8a` 把 `GBIF_QSB_SIDE0..3` 搬进 catalog 时漏给 `ADRENO_6XX_GEN2` 挂 list，GEN2 的 GBIF QoS 侧配置整批丢失 → 进 GNOME 几十秒后 GPU 卡死、GMU 不再响应 HFI；GBIF 在 CX 域而 `a6xx_recover()` 复位的是 GX 域，所以复位救不回来。**通用缺陷，值得发上游**（带 `Fixes:` 与 `Signed-off-by`）。 |
| 0030 / 0031 | 触摸在 resume 时挂掉：Himax `HIMX1234`（HID `4858:121a`）NAK `SET_POWER(SLEEP)`，abort 让 GENI 连后续传输也做不完。DTS 加 `wakeup-source` + 驱动加 `NO_SLEEP_ON_SUSPEND`（`hid-ids.h` 里加该 id），于是挂起阶段这条总线零流量。 |
| 0034 | 背光 PWM 频率对齐原厂（19200 Hz / 9-bit）。`pwm-qcom-lpg` 会把周期量化到 `resolution × pre_div × 2^M / refclk` 的格点，原厂值**精确不可达**；取 `53230 ns` 得 18786 Hz（低 2.2%）。**陷阱**：填原厂的 `52083 ns` 会掉到 6-bit 分辨率、落到 `52500 ns`，频率只近 1.4% 但占空从 511 级掉到 63 级 —— 必须从**上方**逼近。 |
| 0032 / 0033 / 0035 | 内置麦克风（DTS 的 `audio-routing` 要 `"DMICn" -> "MIC BIASx"` **和** `"DMICn" -> "MCLK"`）、采集前端收窄到 `S16_LE`、`DEC0 Volume` 限幅到 0 dB（UCM 把它当采集音量暴露，WirePlumber 100% 会映射到控件最大值 +40 dB）。 |
| 0036 | `pinctrl: qcom: sc8180x` 标记坏掉的 PDC 双边沿 errata。 |

---

## 6. 已知陷阱

* **`09_xiaomi_book_dtb` 的 `KERNELS` 顺序 = 菜单默认项**。它为 `/boot` 下**实际存在**
  的内核生成条目（检查 `vmlinuz-<k>` 与 `dtb/<k>/qcom/sc8180x-xiaomi-book-12.4.dtb`），
  第一个匹配的成为 `GRUB_DEFAULT=0`。若一个都没匹配（`/boot` 没挂），它会**仍然**为
  首选内核生成条目，避免生成一个起不来的菜单。改这个脚本后**务必**用假 `/boot`
  跑一遍三种情况（两个内核都在 / 只有一个 / 都没有）。
* **改 `09_xiaomi_book_dtb` 要重算 PKGBUILD 里第一个 `sha256sums`**（§1.3）。
* **`.install` 里的版本号**：pacman 传给 `post_install` 的是完整版本串
  `pkgver-pkgrel`，DKMS 只认不带 `pkgrel` 的 `PACKAGE_VERSION`，所以 `ra9530-dkms`
  里用 `dkms_version()` 砍掉结尾。按 `$2` 取版本是错的（历史上撞过一次）。
* **`panel-himax-hx83121a-dkms` 覆盖内核内建模块的唯一前提是 `=m`**。
  `ra9530-dkms` 是纯外挂驱动，没有这个前提 —— 写新 DKMS 包时别照抄错。
* **`iio-sensor-proxy-ssc` 用 `provides`/`conflicts` 顶替发行版**：升级时要保证
  `provides` 的版本号跟着 `pkgver` 走，否则依赖方会以为没装。
* **`91-fastrpc-sensors.rules` 补的是上游缺口**：上游
  `80-iio-sensor-proxy.rules` 只给 FastRPC 设备打 `ssc-light ssc-compass`，而
  `drv-ssc-accel.c` / `drv-ssc-proximity.c` 各自要求精确字符串，所以加速度计和
  接近传感器永远不会被拉起。`92-fastrpc-accel-matrix.rules` 的安装矩阵**只有打了
  补丁的 iio-sensor-proxy 才认**。
* **`hexagonrpcd-sdsp.path` 才是拉起守护进程的那个单元**，不是 `.service`：服务自带
  的 `ConditionPathExists` 会在 `/dev/fastrpc-sdsp` 出现前 1.3 秒就判定失败，而
  systemd 不重试失败的条件。
* **不要在 `linux-mibook-mainline` 的 `_package()` 里改用 `$(make -s image_name)`**：
  arm64 上它展开成 `Image.gz`，再 gzip 一次会得到 GRUB 引导不了的「gzip 套 gzip」。
* **头文件包必须带 `tools/bpf/resolve_btfids/resolve_btfids`**：`CONFIG_DEBUG_INFO_BTF_MODULES=y`
  时每个外部 `.ko` 都要它，否则 DKMS 报 exit 127。PKGBUILD 里已按 Arch 的做法处理。

---

## 7. 历史决策（不要翻案）

* **`packages/linux-mibook`（6.18 + linux-surface 栈）已删除**。它的 `source` 指向维护者
  本机的一个 3+ GB 内核 mirror（`file://`），别处根本构建不出来，差分也不可读。
  现在唯一的内核包是 `linux-mibook-mainline`（上游 tarball + 可读补丁集）。
* **`xiaomi-book-12.4-tools` 已撤回**：它把一批运维脚本又拷了一份进包，而系统上从未
  安装过、两份拷贝已经漂移。脚本不再随仓库分发。
* **`rmtfs-dummy` 未收录**：它的 `0001-Redirect-file-lookups-to-var-lib-rmtfs.patch`
  跟不上上游（`rmtfs.service.in` 处 `patch does not apply`），`prepare()` 直接失败。
  它想做的事（EFS 走目录而不是裸分区）现在由 `rmtfs` 包自己的单元 `-r -s -o /var/lib/rmtfs`
  加 `/usr/lib/tmpfiles.d/rmtfs.conf` 完成。
* **fastrpc 的 remote-heap 补丁不要装回来**：它假定 sensors PD 必须走 remote heap，但本机
  fastrpc 节点没有 `memory-region`，remote-heap 分配会把 DSP 打死（整机起不来）；
  而它想取代的 context-bank 路径在本板本来就是好的。
* **IRIS/VPU 视频不在补丁集里**：硬件卡在 TZ/VTL1，DT 里 `venus` 节点保持 `disabled`。
* **`driver_deferred_probe_timeout` 用配置表达，不要改 `drivers/base/dd.c`**（见 §5.1）。
* **GRUB 核是手工资产**：不要试图用 `grub-install`「修好」它。

---

## 8. 改动前后的检查清单

提交前至少跑一遍（都在仓库根目录）：

```sh
# 1. shell 语法
for f in scripts/*.sh packages/*/*.install packages/xiaomi-book-12.4-config/09_xiaomi_book_dtb; do
    bash -n "$f" || echo "FAIL $f"
done

# 2. PKGBUILD 的 source / sha256sums 数量一致（数组长度不等 makepkg 会直接报错）
for d in packages/*/; do (cd "$d" && bash -c '
    shopt -s nullglob; source ./PKGBUILD >/dev/null 2>&1
    [ "${#source[@]}" -eq "${#sha256sums[@]}" ] \
      && echo "ok   $PWD" || echo "MISMATCH $PWD"'); done

# 3. 真实哈希的本地源文件仍然是当前内容
for d in packages/*/; do (cd "$d" && bash -c '
    shopt -s nullglob; source ./PKGBUILD >/dev/null 2>&1 || exit 0
    bad=""
    for i in "${!source[@]}"; do
        h=${sha256sums[$i]:-}; s=${source[$i]}
        [ "$h" = SKIP ] && continue
        case "$s" in *::*|*://*) continue;; esac      # 只管本地文件
        printf "%s  %s\n" "$h" "$s" | sha256sum -c --status 2>/dev/null || bad="$bad $s"
    done
    [ -n "$bad" ] && echo "BAD HASH:$bad" || echo "ok   $PWD"'); done

# 4. 没有指向已删除文件/本机路径的悬空引用
git grep -nE 'SYSTEM-CONFIG|maintainer/|sync-panel-dkms|make-(firmware|sensors-registry)-tarball|regen-patches|drop-commits|/home/certe|aarch64-packages|qcom-slpi'
```

另外：

* 改了内核补丁集 → 确认 36 个补丁**编号连续**且 `linux-mibook-mainline/PKGBUILD`
  的 `_patches` glob 能匹配到它们；
* 改了 `09_xiaomi_book_dtb` → 用假 `/boot` 验证 §6 里的三种情况；
* bump 了 `pkgver`/`pkgrel` → 同步 `dkms.conf` 的 `PACKAGE_VERSION`（DKMS 包）与
  `iio-sensor-proxy-ssc` 的 `provides`；
* 发布前 → 确认 `repo/` 里没有已撤回的包（§3）。
