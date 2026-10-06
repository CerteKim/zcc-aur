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

### 装完还需两步（各包 `.install` 里也会提示）

1. **设备树节点**（RA9530 驱动靠它才能 probe）：
   ```sh
   sudo ra9530-install-dt      # 自动备份 DTB 后加 charger@3b 节点
   sudo reboot
   ```
2. **笔的 BLE 配对**（充电策略需要读取笔的电量）：
   ```sh
   bluetoothctl -> agent on; default-agent; scan on; pair <笔地址>; trust <笔地址>
   ```

---

## 包清单

| 包 | 内容 |
|---|---|
| **`linux-mibook`** | 内核（含 `linux-mibook-headers`）：mainline + 面板/音频/GPU 等本地补丁。**编译需 1~2 小时**，通常单独构建后用 `--collect` 收进仓库。 |
| **`ra9530-dkms`** | RA9530 磁吸笔充电器驱动（DKMS，`arch=any`）。装完由 DKMS 为当前内核构建；同时提供 `ra9530-install-dt` 用于给已安装的 DTB 加节点。 |
| **`xiaomi-book-12.4-firmware`** | 厂商固件：ADSP / CDSP / SLPI / MPSS(no-modem) / GPU-zap / WLAN / venus，外加 `*.jsn` 加载器元数据。这些**不在 `linux-firmware` 里**，是从本机 Windows 分区提取的。 |
| **`xiaomi-book-12.4-config`** | ALSA UCM 配置、WCN3998 蓝牙地址修复（systemd 单元 + udev 规则 + `/etc/conf.d/bluetooth-bdaddr`）、备选面板 DTB。 |
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

* **GPL 与源码**：分发内核二进制时必须能提供对应源码。`packages/linux-mibook/PKGBUILD`
  里的 `_ksource` 目前指向维护者本机的 git 镜像；把它推到 GitHub 后改成
  `_ksource="https://github.com/CerteKim/linux-a51"` 再分发才符合 GPL。
* **别和手工安装的副本混用**：`xiaomi-book-12.4-config` 会安装
  `/usr/lib/systemd/system/bluetooth-bdaddr.service`、`/usr/lib/udev/rules.d/60-bluetooth-bdaddr.rules`
  等；如果你之前用 `tools/install-bluetooth-bdaddr.sh` 手工放到 `/etc/...`，
  请先删掉那些手工副本，避免两份并存。
* **驱动与内核版本**：`ra9530-dkms` 是 DKMS 包，会跟随已安装内核重建；
  内核升级后无需手动干预（前提是新内核提供 `/lib/modules/<ver>/build`）。
