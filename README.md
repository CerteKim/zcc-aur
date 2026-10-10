# zcc-aur — Xiaomi Book S 12.4 的 pacman 仓库

Xiaomi Book S 12.4（`xiaomi,book-12.4`，Qualcomm **SC8180X** / TIMI）跑
Arch Linux ARM 需要的那些包。二进制包通过 **GitHub Release** 分发：`db` 与所有
包放在同一个 Release 里，客户端直接把 `releases/latest/download` 当 Server。

配套的源码仓库：

* **<https://github.com/CerteKim/linux-a51>** — 内核源码，也是 `linux-mibook-mainline`
  分发的二进制所对应的 GPL 源码；
* **<https://github.com/CerteKim/ra9530-mainline>** — RA9530 笔充电驱动。

本仓库只放打包元数据（PKGBUILD、内核补丁、单元/规则文件）。**不含**厂商固件与
传感器注册表（专有数据，见「从源码构建」），也不含任何构建产物。

---

## 一、安装现成的二进制包

### 1.1 加仓库

`/etc/pacman.conf` 末尾加：

```ini
[zcc-aur]
SigLevel = Optional TrustAll
Server = https://github.com/CerteKim/zcc-aur/releases/latest/download
```

```sh
sudo pacman -Syu
sudo pacman -Ss zcc          # 看看有哪些
```

> **为什么是 TrustAll？** 目前 db 没有签名。自己签了名的话把 `SigLevel` 换成
> `Required DatabaseOptional` 并导入公钥即可（见 §3.5）。

### 1.2 装包

```sh
sudo pacman -S linux-mibook-mainline \
               ra9530-dkms \
               xiaomi-book-12.4-firmware \
               xiaomi-book-12.4-config \
               xiaomi-book-12.4-sensors \
               iio-sensor-proxy-ssc

# 可选：只有在想快速迭代面板驱动（DSC/时序）时才需要，见 §2
sudo pacman -S panel-himax-hx83121a-dkms

# 高通用户态服务栈，按需
sudo pacman -S qrtr qmic pd-mapper rmtfs tqftpserv
```

### 1.3 装完必须做的几步

`xiaomi-book-12.4-config` 与 `xiaomi-book-12.4-firmware` 的 `.install` 脚本会在
装包时把下面这些重复打印一遍；这里给出完整清单。

#### ⚠️ a) GRUB 必须显式传 device tree，否则内核起不来

Arch Linux ARM 的 `grub` 包**完全没有设备树支持**：`/etc/grub.d/` 与
`/usr/share/grub/` 里没有任何脚本会写 `devicetree` 行，所以 `grub-mkconfig`
生成的普通菜单项**不会**把 DTB 交给内核。而本机固件是 Windows 那套 ACPI 固件，
**不提供可用的设备树** —— 内核拿不到 DTB 就起不来。

`xiaomi-book-12.4-config` 因此装了 `/etc/grub.d/09_xiaomi_book_dtb`：命名成
`09_` 以便排在 `10_linux` **之前**，为每个已安装、且 `/boot` 下带
`dtb/<内核包名>/qcom/sc8180x-xiaomi-book-12.4.dtb` 的内核生成两个带 `devicetree`
的菜单项（普通 + fallback initramfs）。内核参数由硬件必需项加 `/etc/default/grub`
拼成，根分区 UUID 在生成时自动向系统查询，不写死。

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg     # 生效
sudo chmod -x /etc/grub.d/10_linux            # 建议：免得留下【无 DTB】的菜单项
```

换了内核包、改了设备树路径或内核参数之后，重跑第一条即可。

#### ⚠️ b) 永远不要在这台机器上跑 `grub-install`（连 `--removable` 也不要）

**它会用 ALARM 包构建的 GRUB 核覆盖 `/boot/EFI/Boot/bootaa64.efi`，而那个核在
本机起不来** —— 等于把唯一能启动的 fallback 换掉。

本机在用的 GRUB 核是从 linux-surface 的 **Surface Pro X 试验镜像**里拷出来的
（`EFI/arch/grubaa64.efi`，245760 字节），它把板级 DTB 内嵌在核里，这是它能引导
本机的原因。请把它当手工管理的关键资产，**先备份**：

```sh
sudo mkdir -p /root/grub-spx-backup
sudo cp -a /boot/EFI/arch /root/grub-spx-backup/
sudo cp -a /boot/EFI/Boot/bootaa64.efi /root/grub-spx-backup/bootaa64.efi
sudo sha256sum /boot/EFI/arch/grubaa64.efi /boot/EFI/Boot/bootaa64.efi \
     | sudo tee /root/grub-spx-backup/SHA256SUMS
```

`grub` 包与 `grub-mkconfig` **照常可用**（`09_xiaomi_book_dtb` 就是靠它生效的）
—— 只要**不跑 `grub-install`**。真要试别的核，先用链式加载试，不改任何现有文件：

```
menuentry 'GRUB: test core' {
    chainloader /EFI/test/grubaa64.efi
}
```

> **诊断记录**：跑过 `grub-install` 之后连菜单都进不去还有一个独立成因 —— 它除了
> 写文件，还会新建 `Boot####` 并插到最前面，而本固件对启动项有厂商扩展、两套顺序
> 变量（标准 `BootOrder` 与厂商 GUID 的 `BootOrderTemp`）内容不一致，只写标准的
> 工具未必改得到固件实际使用的那套。所以不要让工具去打理启动项；让 fallback 路径
> 上始终有能用的核，机器就总能起来。

#### c) 固件要进 initramfs

`xiaomi-book-12.4-firmware` 提供 `/usr/lib/initcpio/install/xiaomi-book124-firmware`，
但 `HOOKS` 是用户的配置，包不能改。把 hook 加到 `kms` **之前**：

```ini
HOOKS=(base systemd autodetect microcode modconf xiaomi-book124-firmware kms ...)
```

```sh
sudo mkinitcpio -P
```

SLPI/CDSP 在根文件系统挂载之前就要起来，所以这一步不能省。

#### d) 蓝牙地址

WCN3998 的地址由 `bluetooth-bdaddr.service` 写入（默认 `02:00:00:12:34:56`，
可改 `/etc/conf.d/bluetooth-bdaddr`）：

```sh
sudo systemctl enable --now bluetooth-bdaddr.service
```

#### e) 笔：BLE 配对 + 策略守护

设备树里的 RA9530 节点由内核包提供，**不需要对 DTB 做任何后处理**。剩下两件事：

**BLE 配对**（充电策略要读笔的电量）：

```sh
bluetoothctl
# agent on; default-agent; scan on; pair <笔地址>; trust <笔地址>
```

**策略守护** `ra9530-charge-policy.service`（由 `xiaomi-book-12.4-config` 装）
一个进程管两件事：按 BLE 电量做充电阈值（85 / 75 %），以及**笔吸在磁吸位上时
屏蔽数字化仪上报的笔事件** —— 否则停靠中的笔会被当成"悬停"，GNOME 直接把光标
拽到磁吸位（屏幕左边缘、偏上）。

```sh
sudo systemctl enable --now ra9530-charge-policy.service
journalctl -u ra9530-charge-policy -f
```

停靠闸门是**事件驱动**的：`ra9530-dkms` **>= 1.0.3** 会在霍尔跳变时
`sysfs_notify()`，守护进程用附带的小等待器阻塞等它（实测端到端 3~6 ms；旧版
1 Hz 轮询是 0.5~1 s）。等待器需要 `python3`（`optdepends`）；没有 python3、或
驱动还是旧版，守护会自动退回 1 秒一次的兜底对账，功能不受影响。

> 手工时代从上游 `ra9530-mainline` 的 `install.sh` 装过的话，
> `/etc/systemd/system/` 里那份同名单元会**盖住包内的**，先
> `sudo systemctl disable --now ra9530-charge-policy.service` 再删掉它。

#### f) 传感器栈

`xiaomi-book-12.4-sensors` 的 `.install` 会自动启用 `hexagonrpcd-sdsp.path`
（真正拉起守护进程的是这个 `.path` 单元，不是 `.service`，原因写在单元注释里）。
没自动成功就手动来一次：

```sh
sudo systemctl enable --now hexagonrpcd-sdsp.path
```

`iio-sensor-proxy-ssc` 用 `provides`/`conflicts` **替换**发行版的
`iio-sensor-proxy`：装的时候 pacman 会问要不要移除原包，选是（mutter 的依赖由
本包满足）。卸载本包后记得 `sudo pacman -S iio-sensor-proxy` 装回来。

#### g) 注销重登一次（打字时禁用触控板）

`xiaomi-book-12.4-config` 装了
`/usr/lib/udev/rules.d/99-xiaomi-book-cover-internal.rules`，把键盘盖的输入节点
标回 `internal`。libinput 只在设备加入时读一次集成度，而且它不理会 udev 的
`change` 事件，所以**必须注销并重新登录**，GNOME 的「打字时禁用触控板」才会生效。

### 1.4 验证

```sh
modinfo -n panel-himax-hx83121a                # 有装 DKMS 包时应指向 updates/dkms/
systemctl status hexagonrpcd-sdsp.service
monitor-sensor                                 # 转动设备，orientation 应跟着变
libinput list-devices | grep -A3 -i touchpad   # 打字时禁用触控板应可用
systemctl status ra9530-charge-policy.service
udevadm info /sys/class/input/event4 | grep INTEGRATION   # 应为 internal
```

### 1.5 从手工安装状态迁移过来

如果这些文件之前已经手工放到过同一路径，pacman 会以 `exists in filesystem`
拒绝安装（磁盘上存在但不属于任何包的文件）。用 `-U --overwrite` 放行对应路径，
装完再清掉会盖住包内文件的手工副本。典型需要放行的路径：

```
/usr/bin/hexagonrpcd
/usr/lib/hexagonrpc/*
/usr/lib/libhexagonrpcd.so*
/usr/share/qcom/*
/usr/lib/systemd/system/hexagonrpcd-*
/usr/lib/udev/rules.d/9?-fastrpc*.rules
/usr/lib/firmware/qcom/*
/usr/lib/initcpio/install/xiaomi-book124-firmware
/usr/lib/systemd/system/rmtfs.service
/usr/local/bin/ra9530-*.sh
/usr/lib/iio-sensor-proxy
```

`/etc/systemd/system/` 与 `/etc/udev/rules.d/` 下的同名副本**必须删掉**：
`/etc` 会盖住包内的 `/usr/lib` 版本，让新逻辑静默失效。涉及
`hexagonrpcd-sdsp.{service,path}`、`iio-sensor-proxy.service.d/{exec,debug}.conf`、
`rmtfs.service`、`ra9530-charge-policy.service`、
`99-xiaomi-book-cover-internal.rules`、`9{0,1,2}-fastrpc*.rules`、
`initcpio/install/xiaomi-book124-firmware`。

---

## 二、包清单

| 包 | 内容 |
|---|---|
| **`linux-mibook-mainline`** | 内核（含 `linux-mibook-mainline-headers`）：`cdn.kernel.org` 的 `linux-7.2.tar.xz` + 本目录里 36 个补丁文件（`git format-patch` 的产物）。不带 linux-surface 栈、不带 parked 的 IRIS/VPU 代码。 |
| **`ra9530-dkms`** | RA9530 磁吸笔充电器驱动（DKMS，`arch=any`）。装完由 DKMS 为当前内核构建；只装驱动源码，**不改动 `/boot`** —— 设备树节点由内核包的 DTS 提供。 |
| **`panel-himax-hx83121a-dkms`** | Himax HX83121A 面板驱动（DKMS，`arch=any`）。**可选**：内核包自带的那份仍会装上并生效，装本包只是为了改 DSC/时序**不用重编内核**。 |
| **`xiaomi-book-12.4-firmware`** | 厂商固件：ADSP / CDSP / SLPI / MPSS(no-modem) / GPU-zap / WLAN / venus / Adreno 680，外加 `*.jsn` 加载器元数据；**以及把固件放进 initramfs 的 mkinitcpio hook**。这些固件**不在 `linux-firmware` 里**，是从本机 Windows 分区提取的。 |
| **`xiaomi-book-12.4-config`** | ALSA UCM 配置、WCN3998 蓝牙地址修复（systemd 单元 + udev 规则 + `/etc/conf.d/bluetooth-bdaddr`）、GRUB 的 DTB 菜单项、**把键盘盖输入节点标成 internal 的 udev 规则**（打字时禁触控板）、**RA9530 笔策略守护**（充电阈值 + 停靠时屏蔽笔输入）。 |
| **`xiaomi-book-12.4-sensors`** | **SLPI 传感器栈**：从源码编译的 `hexagonrpcd`（FastRPC 守护进程，上游 `linux-msm/hexagonrpc` v0.5.0）+ SSC 传感器**注册表** + systemd 单元（含 `-R <registry root>`）+ FastRPC udev 规则 + `fastrpc` 用户/组 + 一个 system-sleep hook。没有它，加速度计/光线传感器根本不会出现。 |
| **`iio-sensor-proxy-ssc`** | 打过两个本地补丁的 `iio-sensor-proxy` 3.9（启动期 claim 竞态 + `ACCEL_MOUNT_MATRIX`）。用 `provides`/`conflicts` **替换**发行版那份。 |
| **`qrtr` `qmic` `pd-mapper` `rmtfs` `tqftpserv`** | linux-msm 的**高通用户态服务栈**：IPC 路由器（qrtr）、QMI 客户端库（qmic）、保护域映射（pd-mapper）、远端文件系统服务（rmtfs）、给 DSP 供固件的 TFTP 服务（tqftpserv）。`rmtfs` 本地改过一处：单元用 `-r -s -o /var/lib/rmtfs`（EFS 存目录而不是裸分区）。 |
| **`cdba`** | 高通的 Core Dump Bridge Agent（调试用）。 |

### 面板驱动做成 DKMS（`panel-himax-hx83121a-dkms`）

面板是这套移植里还在反复调的一块（DSC、时序），而它本来是内核树里的一个文件 ——
改一行就要重编 1~2 小时。有两条路：

| | 谁提供 | 改动路径 | 代价 |
|---|---|---|---|
| **内核包**（权威副本） | `linux-mibook-mainline` 编出的 `=m` 模块，落在 `kernel/drivers/gpu/drm/panel/` | 改 linux-a51 内核树 → 重编内核 | 1~2 小时 |
| **DKMS 包**（覆盖用，可选） | `updates/dkms/panel-himax-hx83121a.ko` | 改 `/usr/src/panel-himax-hx83121a-1.0.0/panel-himax-hx83121a.c` → `sudo dkms install -m panel-himax-hx83121a -v 1.0.0 --force` | **约 10 秒** |

要点：

* 内核里这个驱动**必须是 `=m`**（`xiaomi-only.config` 已改成 `=m`）。编进内核
  （`=y`）的话内建驱动会在启动时先绑定面板节点，DKMS 那份永远用不上 —— 包的
  `.install` 会检测并警告。
* **谁生效由 depmod 的搜索顺序决定**：`updates extramodules built-in`，
  `updates/dkms/` 排在 `kernel/` 前面。查证：
  `modinfo -n panel-himax-hx83121a`。
* **必须重建 initramfs**：`kms` hook 会把 `/drivers/gpu/drm/` 下的模块打进
  initramfs。走 pacman 安装/升级/卸载时这是自动的（`dkms` 的 `70-` hook 先重建
  模块，`mkinitcpio` 的 `90-` hook 随后重建 initramfs）；只有手工
  `dkms install --force` 那条路要自己补 `sudo mkinitcpio -P`。
* 卸载本包**不会黑屏**：内核包自带的那份仍在，depmod 会退回用它。
* **内核树是唯一权威来源**：`panel-himax-hx83121a.c` 是从 linux-a51 的
  `drivers/gpu/drm/panel/` 抄过来的，`PKGBUILD` 里的 `_kcommit` 记着来源提交。
  同步后建议出树编译体检一次：`make`（对着 `/lib/modules/$(uname -r)/build`，
  用到非导出符号会在这里暴露）。

### 关于固件包

内核的 DTS 只引用这几个 blob，所以包里**只放被引用的**：

| 文件 | 体积 | 用途 |
|---|---|---|
| `qcadsp8180.mbn` / `qccdsp8180.mbn` / `qcslpi8180.mbn` | 11.6 / 3.1 / 5.7 MB | ADSP / CDSP / SLPI |
| `qcmpss8180_nm.mbn` | 5.2 MB | MPSS，**no-modem** 变体 |
| `qcdxkmsuc8180.mbn` | 14 KB | GPU zap shader |
| `wlanmdsp.mbn` / `qcvss8180.mbn` / `qdsp6m.qdb` | 4.3 / 1.2 / 5.4 MB | WiFi / VPU(venus) / DSP 数据库 |
| `a680_sqe.fw` / `a680_gmu.bin` | — | Adreno 680（`linux-firmware-qcom` 里没有 a680） |
| `*.jsn` ×6 | ~3 KB | 加载器元数据 |

**故意不放**：`qcmpss8180.mbn`（75 MB，全功能 modem）与 `modem_pr/`（11 MB mcfg 树）
—— DTS 用的是 `_nm` 变体，这两样永远不会被加载。

---

## 三、从源码构建

### 3.1 环境

* **aarch64 的 Arch Linux**（ALARM）。只有 `arch=('any')` 的那几个包能在 x86_64 上构建。
* `base-devel`（`makepkg`、`repo-add`）、`git`。
* `scripts/build.sh` 用 `makepkg --nodeps` 调用，**不会自动装依赖**，需要自己先装：

```sh
# 高通用户态栈 + cdba：arch-meson 来自 devtools
sudo pacman -S --needed devtools meson ninja git

# cdba 还额外需要
sudo pacman -S --needed libftdi libgpiod

# 两个 DKMS 包
sudo pacman -S --needed dkms

# iio-sensor-proxy-ssc
sudo pacman -S --needed glib2 libgudev libssc polkit

# 内核包（编译 1~2 小时）
sudo pacman -S --needed xmlto docbook-xsl kmod inetutils bc dtc pahole cpio perl
```

### 3.2 构建

```sh
./scripts/build.sh                       # 构建 packages/ 下全部包 → 登记进 repo/
./scripts/build.sh ra9530-dkms           # 只构建指定的包（可多个）
./scripts/build.sh --list                # 看看 repo/ 里有什么
./scripts/build.sh --db                  # 只重建数据库（产物已在 repo/ 时）
./scripts/build.sh --collect <目录>       # 不构建，把目录里已有的 *.pkg.tar.* 收进 repo/
```

`repo/` 里同名包只保留最新版本，每次都会重建 `zcc-aur.db`。内核包编译需要
1~2 小时，通常单独 `makepkg` 构建后用 `--collect` 收进来。

### 3.3 需要自备厂商数据的两个包

`xiaomi-book-12.4-firmware` 与 `xiaomi-book-12.4-sensors` 的数据来自本机 Windows
安装，是**专有数据、不随仓库分发**，仓库里也没有采集脚本。这两个包正常就是直接
从 GitHub Release 装二进制。要自己构建，得先按 PKGBUILD 头部注释里的文件清单
自备数据并打成 PKGBUILD 期望的 tarball 名（`sha256sums` 对应项是 `SKIP`，
想固定校验就把自己的 sha256 填进去）：

| 包 | 需要的 tarball | 布局 |
|---|---|---|
| `xiaomi-book-12.4-firmware` | `xiaomi-book-12.4-firmware-1.tar.zst` | `usr/lib/firmware/qcom/...` |
| `xiaomi-book-12.4-sensors` | `xiaomi-book-12.4-sensors-registry-1.tar.zst` | `usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors/{config,registry}/` |

### 3.4 发布

```sh
sudo pacman -S github-cli && gh auth login
./scripts/publish.sh                     # 把 db + 全部包发成一个 GitHub Release
```

* **每次发布必须上传 db + 全部包**：`latest/download` 只指向最新 Release，而客户端
  是按文件名去取的，所以每个 Release 都得是完整快照；
* 内核包约 70 MB，Release 单个资源上限 2 GB，没问题。

### 3.5 签名（可选）

```sh
gpg --full-generate-key                  # 若还没有密钥
# 在 /etc/makepkg.conf 里设 PKGEXT/SIGN，或直接：
gpg --detach-sign --use-agent repo/zcc-aur.db.tar.gz
./scripts/publish.sh
```

签名后 `Server` 不变，把 `SigLevel` 改成 `Required DatabaseOptional`，并在客户端
`sudo pacman-key --add <公钥> && sudo pacman-key --lsign-key <keyid>`。

---

## 四、注意事项

* **不要在这台机器上跑 `grub-install`** —— 见 §1.3b。
* **`iio-sensor-proxy-ssc` 会替换发行版的 `iio-sensor-proxy`**（`provides` +
  `conflicts`）：安装时 pacman 会询问是否移除原包，选是。卸载本包后记得
  `sudo pacman -S iio-sensor-proxy` 装回来（mutter 依赖它）。
* **`ra9530-dkms` 会自己清理旧模块副本**：包里的 `.install` 会先删掉
  `/lib/modules/<ver>` 下除 `updates/dkms/` 之外的 `ra9530-charger.ko`
  （`updates/` 优先级高于 `extra/`，残留会让 `modprobe` 一直加载旧版）。
* **`panel-himax-hx83121a-dkms` 是唯一「覆盖内核内建模块」的包**：DKMS 装到
  `updates/dkms/`，内核包装到 `kernel/drivers/gpu/drm/panel/`，路径不同、不冲突，
  前者优先。它要求内核里对应选项是 `=m`；`ra9530-dkms` 那种纯粹的外挂驱动没有
  这个前提 —— 写别的 DKMS 包时别照抄错这一点。
* **GPL 与源码**：分发内核二进制时必须能提供对应源码。内核源码公开在
  **<https://github.com/CerteKim/linux-a51>**（`linux-mibook-mainline` 的补丁集就是
  它的导出产物），GPL 义务因此已经满足。
* **固件是厂商专有 blob**（从本机 Windows 分区提取）：仓库不把它们放进 git，
  是否把打好的二进制包公开到 Release 由你自己决定。
* **驱动与内核版本**：两个 DKMS 包都会跟随已安装内核重建 —— `dkms` 的 `70-` hook
  在内核头文件包更新时自动重建，随后 `mkinitcpio` 的 `90-` hook 重建 initramfs，
  所以内核升级后无需手动干预（前提是新内核提供 `/lib/modules/<ver>/build`）。
  面板那份还必须让内核选项保持 `=m`。
* **屏幕自动旋转还有一个 GNOME 侧的坑**：mutter 在登录时可能不去认领加速度计
  （mutter#4931），表现为 `HasAccelerometer=true` 但屏幕永不旋转。这属于用户会话
  配置，仓库不接管。
