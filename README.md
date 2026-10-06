# zcc-aur — Xiaomi Book S 12.4 的 pacman 仓库

这台机器（`xiaomi,book-12.4`，SC8180X / TIMI）上跑 mainline 需要的一些包，
做成一个可以直接 `pacman -S` 的仓库。二进制包通过 **GitHub Release** 分发，
`db` 与所有包放在同一个 Release 里，客户端用 `releases/latest/download` 作为 Server。

配套的驱动源码仓库：**<https://github.com/CerteKim/ra9530-mainline>**

---

## 客户端配置

`/etc/pacman.conf` 末尾加：

```ini
[zcc-aur]
SigLevel = Optional TrustAll
Server = https://github.com/CerteKim/zcc-aur/releases/latest/download
```

然后：

```sh
sudo pacman -Syu
sudo pacman -Ss zcc          # 看看有哪些
sudo pacman -S linux-mibook ra9530-dkms xiaomi-book-12.4-config \
               xiaomi-book-12.4-tools xiaomi-book-12.4-sensors \
               iio-sensor-proxy-ssc

# 可选：只有在你想快速迭代面板驱动时才需要（见「面板驱动做成 DKMS」）
sudo pacman -S panel-himax-hx83121a-dkms
```

> 这台机器上原先有一批**手工**放进系统的配置（键盘打字禁触控板的 libinput quirk、
> SLPI 传感器栈、打补丁的 iio-sensor-proxy、rmtfs 的 EFS 目录、固件的 initramfs
> hook……）。它们现在都有对应的包了，逐条清单和删除顺序见 **[SYSTEM-CONFIG.md](SYSTEM-CONFIG.md)**。
> 第一次从手工状态迁过来要放行已存在的文件，那里有现成的 `--overwrite` 命令。

> **为什么是 TrustAll？** 目前 db 没有签名（本机没有 GPG 私钥）。
> 如果你签了名（见下面「签名」），把 `SigLevel` 换成 `Required DatabaseOptional`
> 并导入你的公钥即可。

### 装完还需一步：笔的 BLE 配对

设备树节点由 `linux-mibook` 的内核源码提供（`charger@3b` 与 `i2c7` 的 400 kHz
都写在 DTS 里），装好该内核即自带，**不需要再对 DTB 做任何后处理**。

**笔的 BLE 配对**（充电策略需要读取笔的电量）：
   ```sh
   bluetoothctl -> agent on; default-agent; scan on; pair <笔地址>; trust <笔地址>
   ```

**笔策略守护**（`ra9530-charge-policy.service`，由 `xiaomi-book-12.4-config` 装）
一个进程管两件事：按 BLE 电量做充电阈值（85/75%），以及**笔吸在磁吸位上时屏蔽
数字化仪上报的笔事件** —— 否则停靠中的笔会被当成"悬停"，GNOME 直接把光标拽到
磁吸位（屏幕左边缘、偏上）。装上就能用：

   ```sh
   sudo systemctl enable --now ra9530-charge-policy.service
   journalctl -u ra9530-charge-policy -f
   ```

停靠闸门是**事件驱动**的：`ra9530-dkms` **>= 1.0.3** 会在霍尔跳变时
`sysfs_notify()` 那个属性，守护进程用附带的小等待器阻塞等它（实测端到端
3~6 ms，旧版 1 Hz 轮询是 0.5~1 s）。等待器需要 `python3`（`optdepends`）；
没有 python3、或驱动还是旧版，守护会自动退回 1 秒一次的兜底对账，功能不受影响。

> 手工时代从上游 `ra9530-mainline` 的 `install.sh` 装过的话，`/etc/systemd/system/`
> 里那份同名单元会**盖住包内的**，先删掉它再启用（包的 `.install` 会提示）。

### ⚠️ GRUB：本机必须显式传 device tree

Arch Linux ARM 的 `grub` 包**完全没有设备树支持**：`/etc/grub.d/` 与
`/usr/share/grub/` 里没有任何脚本会写 `devicetree` 行（唯一匹配 "dtb" 的是个主题
PNG），所以 `grub-mkconfig` 生成的菜单项**不会**把 DTB 交给内核。而本机固件是
Windows 那套 ACPI 固件，**不提供可用的设备树** —— 内核拿不到 DTB 就起不来。

`xiaomi-book-12.4-config` 因此装了一个 `/etc/grub.d/09_xiaomi_book_dtb`：命名成
`09_` 以便排在 `10_linux` **之前**，生成两个**带 `devicetree`** 的菜单项（普通 +
fallback initramfs）；内核参数由硬件必需项加 `/etc/default/grub` 拼成，根分区 UUID
在生成时自动向系统查询（不写死）。

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg     # 生效
sudo chmod -x /etc/grub.d/10_linux            # 建议：免得留下【无 DTB】的菜单项
```

改设备树路径或内核参数后，重新执行上面第一条即可。

### ⚠️ 永远不要在这台机器上跑 `grub-install`（连 `--removable` 也不要）

**它会用 ALARM 包构建的核覆盖 `/boot/EFI/Boot/bootaa64.efi`，而那个核在本机起不来**
✗ —— 等于把唯一能启动的 fallback 换掉。（本文档早先写过 `--removable --no-nvram` 是
安全刷新的办法，那是错的 ✗：它确实不碰 NVRAM，但会覆盖这个文件。）

本机在用的 GRUB 核是从 linux-surface 的 **Surface Pro X 试验镜像**手工拷来的
（`EFI/arch/grubaa64.efi`，245760 字节）。实测对照：

| | 在用的核（SPX 镜像） | ALARM `grub-install` 生成的核 |
|---|---|---|
| 大小 / 唯一字符串 | 245760 / 1626 | 159744 / 672 |
| 内嵌设备树 | **有** ✓（`xiaomi,book-12.4`、BOOK124 固件路径…） | **无** ✗ |
| 本机能否引导 | 能 ✓ | **不能** ✗（在 Windows 里把 UEFI 启动项指过去实测失败） |
| PE 头 / 烘焙 prefix | PE32+ EFI application / ARM64 / `(,gpt1)/grub` | **完全相同** |
| 模块查找 | 共用 `/boot/grub/arm64-efi/` | 同上 |

ALARM 核里**独有的非 DT 字符串是 0** —— 两者是**同一个 GRUB 构建**，SPX 那份多出来的
正是内嵌的板级 DTB。既然 PE 头与 prefix 完全一致，ALARM 核起不来只能归因于**代码级
补丁差异**（字符串看不出来）。结论：**不要把核换掉** ✗，把在用的那份当作手工管理的
关键资产。

**正确做法（先备份）**：

```sh
sudo mkdir -p /root/grub-spx-backup
sudo cp -a /boot/EFI/arch /root/grub-spx-backup/
sudo cp -a /boot/EFI/Boot/bootaa64.efi /root/grub-spx-backup/bootaa64.efi
sudo sha256sum /boot/EFI/arch/grubaa64.efi /boot/EFI/Boot/bootaa64.efi \
     | sudo tee /root/grub-spx-backup/SHA256SUMS
```

- `grub` 包的 `/etc/grub.d/` 与 `grub-mkconfig` **照常可用** ✓（`09_xiaomi_book_dtb`
  就是靠它生效的 ✓）—— 只要**不跑 `grub-install`** ✓。
- 哪天真要试别的核：**先用链式加载试，不改任何现有文件** ✓，确认能进菜单再替换：
  ```
  menuentry 'GRUB: test core' {
      chainloader /EFI/test/grubaa64.efi
  }
  ```

### 固件启动项的坑（诊断记录）

跑 `grub-install` 之后连菜单都进不去，还有一个独立成因：它除了写文件，还会新建
`Boot####` 并插到最前面，而本固件对启动项有厂商扩展、两套顺序变量内容不一致：

| 变量 | 内容 |
|---|---|
| `BootOrder`（标准 GUID） | `0000, 0003` → Windows、arch |
| `BootOrderTemp`（厂商 GUID `97bf7a1b…`） | `0000, 0001, 0002, 0003`，其中 `BootTemp0001` 指向 `\EFI\Boot\bootaa64.efi` |
| `BootCurrent` | `0003` → `\EFI\arch\grubaa64.efi` |

只写标准 `BootOrder` 的工具未必改得到固件实际使用的那套 ✗，所以**不要让工具去打理
启动项**；让 fallback 路径上始终有能用的核，机器就总能起来 ✓。自救顺序：固件 boot
menu 选 `arch` → 或浏览到 `\EFI\Boot\bootaa64.efi` → 进系统后
`efibootmgr -v` / `-b <号> -B` / `-o 3,0` ✓，或直接从备份拷回 ✓。

---

## 包清单

| 包 | 内容 |
|---|---|
| **`linux-mibook`** | 内核（含 `linux-mibook-headers`）：mainline + 面板/音频/GPU 等本地补丁。**编译需 1~2 小时**，通常单独构建后用 `--collect` 收进仓库。 |
| **`ra9530-dkms`** | RA9530 磁吸笔充电器驱动（DKMS，`arch=any`）。装完由 DKMS 为当前内核构建；只装驱动源码，**不改动 `/boot`** —— 设备树节点由 `linux-mibook` 的内核源码提供。 |
| **`panel-himax-hx83121a-dkms`** | Himax HX83121A 面板驱动（DKMS，`arch=any`）。**可选**：内核包自带的那份仍会装上并生效，装本包只是为了改 DSC/时序**不用重编内核**（见下文）。 |
| **`xiaomi-book-12.4-firmware`** | 厂商固件：ADSP / CDSP / SLPI / MPSS(no-modem) / GPU-zap / WLAN / venus，外加 `*.jsn` 加载器元数据；**以及把固件放进 initramfs 的 mkinitcpio hook**。这些固件**不在 `linux-firmware` 里**，是从本机 Windows 分区提取的。 |
| **`xiaomi-book-12.4-config`** | ALSA UCM 配置、WCN3998 蓝牙地址修复（systemd 单元 + udev 规则 + `/etc/conf.d/bluetooth-bdaddr`）、GRUB 的 DTB 菜单项、**libinput 的键盘盖 quirks（打字时禁触控板）**、**RA9530 笔策略守护**（充电阈值 + 停靠时屏蔽笔输入，`ra9530-charge-policy.service`）。 |
| **`xiaomi-book-12.4-tools`** | 日常/调试脚本：音频修复与测试、GPU OC 检查、面板/DTB 切换、固件重打包、挂起测试、libinput DWT quirk 安装（修复用；正常路径已由 config 包直接安装）等。 |
| **`xiaomi-book-12.4-sensors`** | **SLPI 传感器栈**：从源码编译的 `hexagonrpcd`（FastRPC 守护进程，上游 `linux-msm/hexagonrpc` v0.5.0）+ SSC 传感器**注册表**（从本机 Windows 提取）+ systemd 单元（含 `-R <registry root>`）+ FastRPC udev 规则 + `fastrpc` 用户/组。没有它，加速度计/光线传感器根本不会出现。 |
| **`iio-sensor-proxy-ssc`** | 打过两个本地补丁的 `iio-sensor-proxy` 3.9（启动期 claim 竞态 + `ACCEL_MOUNT_MATRIX`）。用 `provides`/`conflicts` **替换**发行版那份 —— 装的时候 pacman 会问你要不要移除 `iio-sensor-proxy`，选是（mutter 的依赖由本包满足）。 |
| **`qrtr` `qmic` `pd-mapper` `rmtfs` `tqftpserv`** | linux-msm 的**高通用户态服务栈**：IPC 路由器（qrtr）、QMI 客户端库（qmic）、保护域映射（pd-mapper）、远端文件系统服务（rmtfs）、给 DSP 供固件的 TFTP 服务（tqftpserv）。PKGBUILD 沿用 Maximilian Luz 的版本（上游 BSD）。`rmtfs` 本地改过一处：单元用 `-r -s -o /var/lib/rmtfs`（EFS 存目录而不是裸分区），原来靠 `/etc` 覆盖实现。 |
| **`cdba`** | 高通的 Core Dump Bridge Agent（调试用）。构建前需先 `sudo pacman -S libftdi`（在 `extra` 里）。 |

`maintainer/` 目录里是**不打包**的开发脚本（写死了维护者的检出路径），仅供仓库维护使用；
其中 `cleanup-stale-system-files.sh` 用来清掉手工时代遗留的、会盖住包内文件的副本，
`stage-mibook-usb.sh` + `make-mibook-usb.sh` 用来做**本机能引导的救援/live U 盘**
（本机固件不提供设备树，只有 Surface Pro X 镜像里那份 GRUB 核能引导，详见
`grub-spx-backup-README.md`），`mibook-install.sh` 随 live U 盘提供，用来修启动链。

> 这台机器上"手工加进系统"的配置逐条清单（原来在哪、现在归谁、哪些能删）见
> **[SYSTEM-CONFIG.md](SYSTEM-CONFIG.md)**。

> 高通栈里 **`rmtfs-dummy` 未收录** ✗：它的 `0001-Redirect-file-lookups-to-var-lib-rmtfs.patch`
> 已经跟不上上游（`rmtfs.service.in` 处 `patch does not apply`），`prepare()` 直接失败。
> 它想做的事（EFS 走目录）现在由 `rmtfs` 包自己的单元完成。

### 面板驱动做成 DKMS（`panel-himax-hx83121a-dkms`）

面板是这套移植里还在反复调的一块（DSC、时序），而它原来是内核树里的一个文件 ——
改一行就要重编 1~2 小时。现在有两条路：

| | 谁提供 | 改动路径 | 代价 |
|---|---|---|---|
| **内核包**（权威副本） | `linux-mibook` 编出的 `=m` 模块，落在 `kernel/drivers/gpu/drm/panel/` | 改 linux-a51 内核树 → 重编内核 | 1~2 小时 |
| **DKMS 包**（覆盖用，可选） | `updates/dkms/panel-himax-hx83121a.ko` | 改 `/usr/src/panel-himax-hx83121a-1.0.0/panel-himax-hx83121a.c` → `sudo dkms install -m panel-himax-hx83121a -v 1.0.0 --force` | **约 10 秒** |

要点：

* 内核里这个驱动**必须是 `=m`**（`xiaomi-only.config` 已改成 =m）。如果编进了内核
  （`=y`），内建驱动会在启动时先绑定面板节点，DKMS 那份永远用不上 ✗ ——
  包的 `.install` 会检测并警告。
* **谁生效由 depmod 的搜索顺序决定**：`updates extramodules built-in`，
  `updates/dkms/` 排在 `kernel/` 前面 ✓。查证：
  ```sh
  modinfo -n panel-himax-hx83121a     # 应指向 /lib/modules/<ver>/updates/dkms/
  ```
* **必须重建 initramfs**：`kms` hook 会把 `/drivers/gpu/drm/` 下的模块打进
  initramfs，不重建的话开机加载的仍是旧副本。走 pacman 安装/升级/卸载时这是自动的
  （`dkms` 的 `70-` hook 先重建模块，`mkinitcpio` 的 `90-` hook 随后重建 initramfs）；
  只有手工 `dkms install --force` 那条路要自己补 `sudo mkinitcpio -P`。
* 卸载本包**不会黑屏**：内核包自带的那份仍在，`depmod` 会退回用它 ✓（内容较旧）。
* **内核树是唯一权威来源**，改完内核那边把拷贝同步过来（顺带做出树编译体检）：
  ```sh
  ./scripts/sync-panel-dkms.sh          # 默认从 linux-surface/src/kernel 取
  ./scripts/sync-panel-dkms.sh ~/src/linux
  ```

### 关于固件包

参考内核的 DTS 只引用这几个 blob，所以包里**只放被引用的**：

| 文件 | 体积 | 用途 |
|---|---|---|
| `qcadsp8180.mbn` / `qccdsp8180.mbn` / `qcslpi8180.mbn` | 11.6 / 3.1 / 5.7 MB | ADSP / CDSP / SLPI |
| `qcmpss8180_nm.mbn` | 5.2 MB | MPSS，**no-modem** 变体 |
| `qcdxkmsuc8180.mbn` | 14 KB | GPU zap shader |
| `wlanmdsp.mbn` / `qcvss8180.mbn` / `qdsp6m.qdb` | 4.3 / 1.2 / 5.4 MB | WiFi / VPU(venus) / DSP 数据库 |
| `*.jsn` ×6 | ~3 KB | 加载器元数据 |

**故意不放**：`qcmpss8180.mbn`（75 MB，全功能 modem）与 `modem_pr/`（11 MB mcfg 树）——
DTS 用的是 `_nm` 变体，这两样永远不会被加载。整棵树 118 MB，必需部分是 36 MB。

源码 tarball 由 `scripts/make-firmware-tarball.sh` 在本机生成（从 `/usr/lib/firmware`
或 Windows 挂载点收集），**不进 git**（30+ MB 的专有 blob），只把打好的二进制包
发布到 Release。

---

## 构建与发布（维护者）

```sh
./scripts/build.sh                       # 构建 packages/ 下全部包 → 登记进 repo/
./scripts/build.sh ra9530-dkms           # 只构建一个
./scripts/sync-panel-dkms.sh             # 从内核树同步面板驱动（含出树编译体检）
./scripts/make-sensors-registry-tarball.sh   # 传感器注册表 tarball（构建 sensors 包前必须）
./scripts/build.sh --collect ~/aarch64-packages/linux-surface   # 收编已构建好的内核包
./scripts/build.sh --list                # 看看 repo/ 里有什么

sudo pacman -S github-cli && gh auth login
./scripts/publish.sh                     # 把 db + 全部包发成一个 Release
```

要点：

* `repo/` 里同名包只保留最新版本，每次重建 `zcc-aur.db`；
* **每次发布必须上传 db + 全部包**（`latest/download` 只指向最新 Release，
  而客户端是按文件名去取的，所以每个 Release 都是完整快照）；
* 内核包约 70 MB，Release 单个资源上限 2 GB，没问题；
* **两个包依赖本机生成的 tarball**（不进 git，厂商数据）：
  `xiaomi-book-12.4-firmware`（`scripts/make-firmware-tarball.sh`）与
  `xiaomi-book-12.4-sensors`（`scripts/make-sensors-registry-tarball.sh`）。
  换机器构建时先跑对应脚本，并把打印出来的 sha256 填进 PKGBUILD。

### 签名（可选）

```sh
gpg --full-generate-key                  # 若还没有密钥
# 在 /etc/makepkg.conf 里设 PKGEXT/SIGN 或直接用:
gpg --detach-sign --use-agent repo/zcc-aur.db.tar.gz
./scripts/publish.sh
```
签名后把 `Server` 不变、`SigLevel` 改成 `Required DatabaseOptional`，
并在客户端 `sudo pacman-key --add <你的公钥> && sudo pacman-key --lsign-key <keyid>`。

---

## 注意事项

* **从手工安装迁移过来时**：`xiaomi-book-12.4-firmware` 里的固件、`xiaomi-book-12.4-config`
  里的 `/usr/local/bin/bluetooth-bdaddr.sh`、`xiaomi-book-12.4-sensors` 的
  `/usr/bin/hexagonrpcd` 与传感器注册表等，如果你之前已经手工放到同一路径，
  pacman 会以 `exists in filesystem` 拒绝安装（磁盘上存在但不属于任何包的文件）。
  完整的 `--overwrite` 命令在 **[SYSTEM-CONFIG.md](SYSTEM-CONFIG.md)** 第 8 节；
  装完再用 `maintainer/cleanup-stale-system-files.sh` 清掉会盖住包内文件的手工副本。
  如果之前用 `tools/install-bluetooth-bdaddr.sh` 往 `/etc/systemd/system`、
  `/etc/udev/rules.d` 放过**另一份**，也请删掉，避免与本包并存。
* **`iio-sensor-proxy-ssc` 会替换发行版的 `iio-sensor-proxy`**（`provides` +
  `conflicts`）：安装时 pacman 会询问是否移除原包，选是。卸载本包后记得
  `sudo pacman -S iio-sensor-proxy` 装回来（mutter 依赖它）。
* **`ra9530-dkms` 会自己清理旧模块副本**：包里的 `.install` 会先删掉
  `/lib/modules/<ver>` 下除 `updates/dkms/` 之外的 `ra9530-charger.ko`
  （`updates/` 的优先级高于 `extra/`，残留会让 `modprobe` 一直加载旧版）。
* **`panel-himax-hx83121a-dkms` 是唯一「覆盖内核内建模块」的包**：DKMS 装到
  `updates/dkms/`，内核包装到 `kernel/drivers/gpu/drm/panel/`，路径不同、不冲突，前者优先。
  它要求内核里对应选项是 `=m`（`linux-mibook` 已是），`ra9530-dkms` 那种纯粹的
  外挂驱动没有这个前提 —— 写别的 DKMS 包时别照抄错这一点。
* **GPL 与源码**：分发内核二进制时必须能提供对应源码。内核源码已公开在
  **<https://github.com/CerteKim/linux-a51>** 的 `xiaomi-mainline-panel2` 分支上
  （就是 `packages/linux-mibook/PKGBUILD` 里 `_ref_ksource` 锁定的那个 commit），
  GPL 义务因此已经满足。`_ksource` 保留指向本机镜像只是为了构建速度 ——
  完整克隆这个内核仓库有 3+ GB，真要改也能改（PKGBUILD 注释里写了怎么改）。
* **固件是厂商专有 blob**（从本机 Windows 分区提取）：仓库不把它们放进 git，
  是否把打好的二进制包公开到 Release 由你决定。
* **驱动与内核版本**：`ra9530-dkms` 与 `panel-himax-hx83121a-dkms` 都是 DKMS 包，
  会跟随已安装内核重建 —— `dkms` 的 `70-` hook 在内核头文件包更新时自动重建，
  随后 `mkinitcpio` 的 `90-` hook 重建 initramfs，所以内核升级后无需手动干预
  （前提是新内核提供 `/lib/modules/<ver>/build`）。面板那份还必须让内核选项保持 `=m`。
