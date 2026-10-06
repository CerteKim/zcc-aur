# 这台机器上手工加进系统的配置 —— 以及它们现在归谁

这份文档记录的是**不属于任何包**、靠手工脚本/手抄文件加进系统的那些改动：它们
曾经是什么、现在由哪个包接手、哪些已经可以删掉。之前这些只存在于 `~/qcom-slpi/`
和几个 `/etc` 文件里，重装系统就散。

盘点方法（随时可以重跑）：

```sh
cd /tmp
pacman -Qlq | sort -u > owned.txt
{ find /etc /usr/local /usr/bin /usr/lib/systemd /usr/lib/udev /usr/share/qcom -xdev \
        \( -type f -o -type l \); } | sort -u > onfs.txt
comm -23 onfs.txt owned.txt        # 差集 = 无主文件
```

---

## 1. SLPI 传感器栈（原来是 `~/qcom-slpi/install.sh`）

这块最脆：SLPI 的传感器（icm4x6xx 加速度计/陀螺、stk3a5x 光线/接近）挂在 SSC 后面，
只能走 FastRPC；而 SSC 必须拿到厂商的**传感器注册表**才会报告任何数据。

| 原来手工放在 | 现在 | 包 |
|---|---|---|
| `/usr/bin/hexagonrpcd` | 上游 `linux-msm/hexagonrpc` v0.5.0 **从源码编译** | `xiaomi-book-12.4-sensors` |
| `/usr/lib/libhexagonrpc.so.0.5` + `.so` | 同上 | 同上 |
| `/usr/lib/hexagonrpc/chrecd` | 同上（原来漏装了） | 同上 |
| `/usr/share/qcom/sc8180x/XIAOMI/BOOK124/sensors/{config,registry}/`（68 个文件） | 本机生成的 registry tarball（厂商数据，不进 git） | 同上 |
| `/usr/lib/systemd/system/hexagonrpcd-sdsp.{service,path}` | 单元由包提供；`.service` 里**直接写死 `-R <registry root>`** | 同上 |
| `/etc/systemd/system/hexagonrpcd-sdsp.service.d/root.conf`（就是加 `-R` 的 drop-in） | **不再需要** → 可删 | — |
| `/etc/systemd/system/hexagonrpcd-sdsp.path`（手抄的那份会盖住包里的） | **可删** | — |
| `/etc/udev/rules.d/9{0,1,2}-fastrpc*.rules` | 包安装到 `/usr/lib/udev/rules.d/` | 同上 |
| `fastrpc` 用户/组（手工 `useradd`） | `/usr/lib/sysusers.d/fastrpc.conf` | 同上 |

三条 udev 规则各自的作用（别删错）：

* `90-fastrpc.rules`：`/dev/fastrpc-*` → group `fastrpc`, 0660（hexagonrpcd 以该用户跑）；
* `91-fastrpc-sensors.rules`：补**上游的缺口** —— `80-iio-sensor-proxy.rules` 只给
  FastRPC 设备打了 `ssc-light ssc-compass`，于是 iio-sensor-proxy 永远不会启动
  `drv-ssc-accel.c` / `drv-ssc-proximity.c`（它们各自要求精确的字符串）；
* `92-fastrpc-accel-matrix.rules`：加速度计安装矩阵 `-1,0,0;0,-1,0;0,0,1`，
  **只有打补丁的 iio-sensor-proxy 才认**（见下一节）。

## 2. 打过补丁的 iio-sensor-proxy（原来是 `/usr/local` + drop-in）

| 原来手工放在 | 现在 | 包 |
|---|---|---|
| `/usr/local/lib/iio-sensor-proxy/iio-sensor-proxy` | 直接**取代**发行版那份，装到 `/usr/lib/iio-sensor-proxy` | `iio-sensor-proxy-ssc` |
| `/etc/systemd/system/iio-sensor-proxy.service.d/exec.conf` | **不再需要** → 可删 | — |
| `/etc/systemd/system/iio-sensor-proxy.service.d/debug.conf`（`G_MESSAGES_DEBUG=all`） | 调试残留 → **可删** | — |
| `/usr/local/share/iio-sensor-proxy/0001-*.patch` | 补丁随包安装到 `/usr/share/doc/iio-sensor-proxy-ssc/` | 同上 |

补丁两件事（上游 3.9 + 本地 patch，**暂不上游**）：

1. **启动期抢占**：D-Bus 名字在 SSC 传感器还在枚举时就被拿到，gnome-shell 可能在
   proxy 打开传感器之前 claim 加速度计；那次 claim 会被应答但从不开始轮询，并且
   挡住之后所有 claim —— 整场会话都拿不到传感器；
2. **`ACCEL_MOUNT_MATRIX`**：`drv-ssc-accel.c` 像 IIO 驱动那样认这个 udev 属性。
   libssc 已经把厂商矩阵烘进每个采样里，所以"竖屏面板 + 横屏桌面"的旋转只能在
   这一层修正。

> `iio-sensor-proxy-ssc` 用 `provides`/`conflicts` 替换发行版包：`pacman -S` 时会问
> 你要不要移除 `iio-sensor-proxy`，选是即可（mutter 的依赖由 provides 满足）。
> 卸载本包后要装回发行版：`sudo pacman -S iio-sensor-proxy`。

## 3. 输入：打字时禁用触控板

| 原来 | 现在 |
|---|---|
| `xiaomi-book-12.4-tools` 里的 `install-dwt-fix.sh` 手工运行 | `xiaomi-book-12.4-config` **直接安装** `/etc/libinput/local-overrides.quirks` |

文件内容不变（键盘盖 `2717:5032` 是键盘+触控板同一个 USB 复合设备，udev 只给触控板
打了 `internal`，键盘那半边没有 → libinput 的 `tp_want_dwt()` 不配对 → GNOME 那个
开关无效）。tools 包里的安装脚本仍保留，作为修复/核对工具。

## 4. 启动：固件进 initramfs

| 原来 | 现在 |
|---|---|
| `/etc/initcpio/install/xiaomi-book124-firmware` + `/etc/mkinitcpio.conf` 的 `HOOKS` 手工加一项 | hook 由 `xiaomi-book-12.4-firmware` 安装到 `/usr/lib/initcpio/install/`；**`HOOKS` 仍然要自己写**（那是用户的配置，包不能改） |

装完包后 `/etc/initcpio/install/xiaomi-book124-firmware` 这份手抄的可以删（它会盖住
包里的同名 hook——内容相同，但留着容易搞不清哪份在生效）。包的 `.install` 会检查
`HOOKS` 里有没有 `xiaomi-book124-firmware` 并给出提示。

## 5. 高通用户态：rmtfs 的 EFS 目录

| 原来 | 现在 |
|---|---|
| `/etc/systemd/system/rmtfs.service` 覆盖（`rmtfs -r -s -o /var/lib/rmtfs`，包里原本是 `-r -P -s`） | **折进包本身**：`rmtfs` pkgrel 2 的单元就是 `-r -s -o /var/lib/rmtfs`，加 `/usr/lib/tmpfiles.d/rmtfs.conf` 建目录 |

这正是当初 `rmtfs-dummy` 那个补丁想做的事（把 EFS 查找重定向到目录），只是用包内
单元实现，干净得多。`/etc` 那份覆盖可删。

## 6. 用户会话级（仍然是手工，没打包）

这些不改系统、只属于当前用户，包没有理由接管：

| 位置 | 作用 |
|---|---|
| `~/.local/bin/mutter-accelerometer-claim.sh` + `~/.config/autostart/mutter-accelerometer-claim.desktop` | 绕过 **mutter#4931**：登录后 poke 一次让 mutter 认领加速度计（inhibit 计数 `-1→0→1→0`），否则 `HasAccelerometer=true` 但屏幕永不旋转。**不要删** |
| `/etc/environment` 的 `GSK_RENDERER=gl` | 强制 GTK4 用 GL 渲染（默认 ngl 在这台有问题）。按你的意思先不动 |
| `~/.config/environment.d/im.conf` | fcitx + `QT_QPA_PLATFORM=wayland` 等输入法环境变量 |
| GNOME 扩展：`~/.local/share/gnome-shell/extensions/{gjsosk,globalmenu,kimpanel}` + 启用的 `adaptive-brightness`/`adaptivetone`/`soft-brightness-plus`/`light-style` | 后面三个吃 SSC 光感，是第 1、2 节的下游 |
| dconf：`sleep-inactive-ac/battery-type='nothing'`、`ambient-enabled=true`、`peripherals/touchscreen/orientation-lock=false`、`peripherals/tablets/4858:121a` | 禁自动挂起、自动亮度、自动旋转、数位笔映射 |
| `~/.config/monitors.xml`（DSI-1 rotation=right, scale=2） | 竖屏面板 / 横屏桌面 |
| `/etc/sysctl.d/99-zram-tuning.conf` + `/etc/systemd/zram-generator.conf` | zram 调优（swappiness=100、page-cluster=0、vfs_cache_pressure=50）。按你的意思先不动 |

## 7. 已经删掉 / 可以删掉的东西

`maintainer/cleanup-stale-system-files.sh` 会列出（加 `--apply` 才真删）：

| 文件 | 为什么 |
|---|---|
| `/etc/systemd/system/btmgmt.service` | 蓝牙地址已经写进设备树（`local-bd-address = [60 ad ce 9e 16 14]`），而且这个单元早就 `disabled`+`inactive` |
| `/etc/systemd/system/hexagonrpcd-sdsp.path` | 手抄的会盖住包里的 |
| `/etc/systemd/system/hexagonrpcd-sdsp.service.d/root.conf` | `-R` 已经写进包里的单元 |
| `/etc/systemd/system/iio-sensor-proxy.service.d/{exec,debug}.conf` | 补丁版直接顶替发行版二进制；debug.conf 是调试残留 |
| `/usr/local/lib/iio-sensor-proxy/`、`/usr/local/share/iio-sensor-proxy/` | 同一件事的第二份拷贝 |
| `/etc/systemd/system/rmtfs.service` | 已折进 `rmtfs` 包 |
| `/etc/initcpio/install/xiaomi-book124-firmware` | 已由 firmware 包提供 |
| `/etc/modprobe.d/vdec-probe.conf` | VPU 探针调试留的 `blacklist qcom-iris` |
| `/etc/mkinitcpio.d/linux-surface.preset.{bak,pacsave}` | 旧内核包的残留 |
| `/boot/dtb/linux-mibook/qcom/sc8180x-xiaomi-book-12.4-{oc,parked,vdec-probe}.dtb{,.bak,.orig-ra9530}` | 合并 `.dts`、删掉 `-oc` 变体之后的残留（pacman 不管非包文件） |
| `~/.config/monitors.xml~` | 编辑器备份 |

## 8. 安装顺序（重要）

这些包会**接管**已经存在的同路径文件，pacman 会以 `exists in filesystem` 拒绝，所以
第一次装要放行（见 README 的「注意事项」）：

```sh
sudo pacman -U --overwrite '/usr/bin/hexagonrpcd' \
               --overwrite '/usr/lib/hexagonrpc/*' \
               --overwrite '/usr/lib/libhexagonrpc.so*' \
               --overwrite '/usr/share/qcom/*' \
               --overwrite '/usr/lib/systemd/system/hexagonrpcd-*' \
               --overwrite '/usr/lib/udev/rules.d/9?-fastrpc*.rules' \
               --overwrite '/etc/libinput/local-overrides.quirks' \
               --overwrite '/usr/lib/initcpio/install/xiaomi-book124-firmware' \
               --overwrite '/usr/lib/systemd/system/rmtfs.service' \
               --overwrite '/usr/lib/iio-sensor-proxy' \
               ~/zcc-aur/repo/xiaomi-book-12.4-sensors-*.pkg.tar.* \
               ~/zcc-aur/repo/iio-sensor-proxy-ssc-*.pkg.tar.* \
               ~/zcc-aur/repo/xiaomi-book-12.4-config-*.pkg.tar.* \
               ~/zcc-aur/repo/xiaomi-book-12.4-firmware-*.pkg.tar.* \
               ~/zcc-aur/repo/rmtfs-*.pkg.tar.*

sudo mkinitcpio -P                       # 固件 hook / iio 单元变化后重建一次
~/zcc-aur/maintainer/cleanup-stale-system-files.sh --apply
sudo reboot
```

装完的验证：

```sh
modinfo -n iio-sensor-proxy          # 不存在也没关系：它现在是 /usr/lib/iio-sensor-proxy
systemctl status hexagonrpcd-sdsp.service
monitor-sensor                       # 转动设备，orientation 应跟着变
libinput list-devices | grep -A3 -i touchpad   # 打字时禁用触控板开关应生效
```
