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
sudo pacman -S linux-mibook ra9530-dkms xiaomi-book-12.4-config xiaomi-book-12.4-tools
```

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

### ⚠️ 不要直接跑 `grub-install`（这台固件的 NVRAM 不可靠）

在这台机器上，**无参数执行 `grub-install` 会导致开机连 GRUB 菜单都进不去** ✗。
原因是它除了写文件，还会新建一个 `Boot####` 启动项并把它插到最前面；本机固件对
启动项的处理有厂商扩展，新建的项一旦指向不存在的路径，固件就卡在那里不再往下走 ✗。

**只刷新 fallback 路径、完全不碰 NVRAM** 的做法：

```sh
sudo grub-install --target=arm64-efi --efi-directory=/boot --removable --no-nvram
```

（`--removable` 本身即跳过 NVRAM 写入，`--no-nvram` 是双保险 ✓。）

本机现状（2026-10 实测，供对照）：

| 项目 | 值 |
|---|---|
| `BootOrder` | `0000,0003`（Windows、arch） |
| 厂商私有 `BootOrderTemp` | `0000,0001,0002,0003`，其中 `BootTemp0001` 指向 `\EFI\Boot\bootaa64.efi` |
| `BootCurrent` | `0003`（`arch` → `\EFI\arch\grubaa64.efi`） |
| fallback 路径 | `/boot/EFI/Boot/bootaa64.efi` 与 `EFI/arch/grubaa64.efi` 是同一个 GRUB ✓ |
| ESP | 只有一个（256 MB，剩余 55 MB）—— 排除"写错分区"，更像新建项指向了不存在的路径 |

**两套启动顺序变量内容不一致** ✗：只写标准 `BootOrder` 的工具未必改得到固件实际
使用的那套，所以不要把启动项交给工具去打理 —— 让 fallback 路径上始终有能用的
GRUB，机器就总能起来 ✓。

出问题时的自救：开机按固件的 boot menu 键选 `arch`，或直接浏览到
`\EFI\Boot\bootaa64.efi` ✓；进系统后 `efibootmgr -v` 查看、
`efibootmgr -b <号> -B` 删坏项、`efibootmgr -o 3,0` 调顺序 ✓。

---

## 包清单

| 包 | 内容 |
|---|---|
| **`linux-mibook`** | 内核（含 `linux-mibook-headers`）：mainline + 面板/音频/GPU 等本地补丁。**编译需 1~2 小时**，通常单独构建后用 `--collect` 收进仓库。 |
| **`ra9530-dkms`** | RA9530 磁吸笔充电器驱动（DKMS，`arch=any`）。装完由 DKMS 为当前内核构建；只装驱动源码，**不改动 `/boot`** —— 设备树节点由 `linux-mibook` 的内核源码提供。 |
| **`xiaomi-book-12.4-firmware`** | 厂商固件：ADSP / CDSP / SLPI / MPSS(no-modem) / GPU-zap / WLAN / venus，外加 `*.jsn` 加载器元数据。这些**不在 `linux-firmware` 里**，是从本机 Windows 分区提取的。 |
| **`xiaomi-book-12.4-config`** | ALSA UCM 配置、WCN3998 蓝牙地址修复（systemd 单元 + udev 规则 + `/etc/conf.d/bluetooth-bdaddr`）。 |
| **`xiaomi-book-12.4-tools`** | 日常/调试脚本：音频修复与测试、GPU OC 检查、面板/DTB 切换、固件重打包、挂起测试、libinput DWT quirk 安装等。 |

`maintainer/` 目录里是**不打包**的开发脚本（写死了维护者的检出路径），仅供仓库维护使用。

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
./scripts/build.sh --collect ~/aarch64-packages/linux-surface   # 收编已构建好的内核包
./scripts/build.sh --list                # 看看 repo/ 里有什么

sudo pacman -S github-cli && gh auth login
./scripts/publish.sh                     # 把 db + 全部包发成一个 Release
```

要点：

* `repo/` 里同名包只保留最新版本，每次重建 `zcc-aur.db`；
* **每次发布必须上传 db + 全部包**（`latest/download` 只指向最新 Release，
  而客户端是按文件名去取的，所以每个 Release 都是完整快照）；
* 内核包约 70 MB，Release 单个资源上限 2 GB，没问题。

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
  里的 `/usr/local/bin/bluetooth-bdaddr.sh` 等，如果你之前已经手工放到同一路径，
  pacman 会以 `exists in filesystem` 拒绝安装（磁盘上存在但不属于任何包的文件）。
  用 `--overwrite` 放行即可：
  ```sh
  sudo pacman -U --overwrite '/usr/lib/firmware/qcom/*' \
                 --overwrite '/usr/local/bin/bluetooth-bdaddr.sh' \
                 xiaomi-book-12.4-firmware-*.pkg.tar.* xiaomi-book-12.4-config-*.pkg.tar.*
  ```
  如果之前用 `tools/install-bluetooth-bdaddr.sh` 往 `/etc/systemd/system`、
  `/etc/udev/rules.d` 放过**另一份**，请删掉那些手工副本，避免与本包并存。
* **`ra9530-dkms` 会自己清理旧模块副本**：包里的 `.install` 会先删掉
  `/lib/modules/<ver>` 下除 `updates/dkms/` 之外的 `ra9530-charger.ko`
  （`updates/` 的优先级高于 `extra/`，残留会让 `modprobe` 一直加载旧版）。
* **GPL 与源码**：分发内核二进制时必须能提供对应源码。内核源码已公开在
  **<https://github.com/CerteKim/linux-a51>** 的 `xiaomi-mainline-panel2` 分支上
  （就是 `packages/linux-mibook/PKGBUILD` 里 `_ref_ksource` 锁定的那个 commit），
  GPL 义务因此已经满足。`_ksource` 保留指向本机镜像只是为了构建速度 ——
  完整克隆这个内核仓库有 3+ GB，真要改也能改（PKGBUILD 注释里写了怎么改）。
* **固件是厂商专有 blob**（从本机 Windows 分区提取）：仓库不把它们放进 git，
  是否把打好的二进制包公开到 Release 由你决定。
* **驱动与内核版本**：`ra9530-dkms` 是 DKMS 包，会跟随已安装内核重建；
  内核升级后无需手动干预（前提是新内核提供 `/lib/modules/<ver>/build`）。
