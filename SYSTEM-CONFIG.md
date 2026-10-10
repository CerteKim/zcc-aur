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

## 3. 输入：打字时禁用触控板 / 笔停靠时别搬光标

### 3.1 打字时禁用触控板（DWT）

| 原来 | 现在 |
|---|---|
| 旧的 `tools/install-dwt-fix.sh` 手工运行（装一个 libinput quirk） | `xiaomi-book-12.4-config` **直接安装** `/usr/lib/udev/rules.d/99-xiaomi-book-cover-internal.rules`（udev 规则） |

**根因（2026-10-07 定位）**：cover（`2717:5032`，键盘 / 触控板 / Mouse 是同一个 USB 复合
设备）的 `removable=unknown`，udev 的 `65-integration.rules` 因此把它的**所有**输入节点
标成 `ID_INTEGRATION=external`。而 libinput 的 `tp_init_dwt()`
（`src/evdev-mt-touchpad.c:3450`）对外部触控板**直接返回，连 DWT 配置都不注册**：

    if (device->tags & EVDEV_TAG_EXTERNAL_TOUCHPAD &&
        !tp_is_tpkb_combo_below(device))
            return;
    ...
    tp->dwt.dwt_enabled = tp_dwt_default_enabled(tp);
    device->base.config.dwt = &tp->dwt.config;

后果链条：`device->config.dwt == NULL` → `libinput_device_config_dwt_is_available()==0`
→ mutter 里 `if (dwt_is_available()) dwt_set_enabled(...)` 成了空操作（GNOME 那个开关
失效）→ 同时 `dwt_enabled` 保持 `false`，`tp_keyboard_event()` 在
`if (!tp->dwt.dwt_enabled) return;` 就退出，`keyboard_active` 永远是 false，
`tp_post_events()` 里那句早退不生效 → **打字时触控板照常驱动指针**。
而 `tp_want_dwt()` 走的是"外部触控板只要与键盘同 vid:pid 就算一对"那条分支，所以日志里
照样出现 `palm: dwt activated with …`，看起来像"配对成功却没效果"，极具误导性。

**修法**：udev 规则把 cover 的所有输入节点标回 `internal` —— 触控板 internal 才会注册
DWT 配置，键盘 internal 才会配上对，两者缺一不可。

**不能改用 libinput quirk**：它的 `MatchBus/MatchVendor/MatchProduct` 只从 udev 属性
`PRODUCT` 取值（`src/quirks.c: match_fill_bus_vid_pid()`），而本机 input **事件节点上没有
`PRODUCT`** —— 它只在父 `inputN` 设备的 uevent 里（`/sys/class/input/input9/uevent` 有
`PRODUCT=3/2717/5032/111`，`event4` 没有；`/run/udev/data` 下也没有任何设备带它）。
所以 config 包以前装的那条 `AttrKeyboardIntegration=internal` quirk **从未生效过**，
现已从包里移除。

**注意**：libinput 不理会 udev 的 `change` 事件（`src/udev-seat.c:211` 只处理
`add`/`remove`），所以装完必须**注销重登**才生效。

**核对**：
`udevadm info /sys/class/input/event4 | grep INTEGRATION` 应显示 `internal`；
运行时可以用 linux-surface 检出里的 `tools/dwt/dwt-probe`（`sudo` 跑）确认
`event4` 变成 `dwt: available=1`、判定为「DWT 正常工作」。

### 3.2 笔吸在磁吸位上时屏蔽笔输入

| 原来 | 现在 |
|---|---|
| 上游 `ra9530-mainline` 的 `install.sh` 手工装 `/usr/local/bin/ra9530-{charge-policy,pen-battery}.sh` + `/etc/systemd/system/ra9530-charge-policy.service`（只做充电阈值） | `xiaomi-book-12.4-config` 装**同一路径**的脚本 + `/usr/lib/systemd/system/ra9530-charge-policy.service`；同一个守护进程现在多管一件事：**停靠闸门**。上游那三个文件已删除（`ra9530-mainline` 现在只装驱动与设备树），所以这里就是唯一一份 |

**现象**：磁吸位落在屏幕左侧偏上的感应区内，吸附中的笔被 HID-over-I2C 数字化仪的
Stylus 集合（`0018:4858:121A` @ `i2c-0/0x4f`，即 `/dev/input/event10`）当成"悬停"
反复上报；udev 把它标成 `ID_INPUT_TABLET`，而 GNOME/mutter 对 tablet tool 是**绝对
定位并直接 warp 光标** —— 于是光标一次次被拽到磁吸位那个点（换算到 2560x1600 桌面
约 `(103, 515)`，左边缘、距顶 32%）。

**实测取证**（停靠时）：`event10` 30 秒内有多次 `BTN_TOOL_PEN` 1→0 的进出，坐标恒定
在原生 `(≈10850, 1030)`；同一时间窗里触摸屏 `event9` 与触控板 `event4` **全程 0 事件**
—— 触摸在 Wayland 下不搬光标，所以这个现象只能是笔。数字化仪 235 秒里只有 20 秒有
活动（12~49 次/秒的突发），与"偶尔闪过去"的观感一致。

**做法**：`/sys/bus/i2c/devices/1-003b/pen_present`（驱动自己的吸附检测）为 1 时写
`/sys/class/input/inputN/inhibited=1`，取下时写 0。用内核这个属性而不是 EVIOCGRAB 的
原因：`input_get_disposition()` 里中心化过滤，不会关掉 gnome-shell 已打开的 evdev fd；
抑制时会正经把 `BTN_TOOL_PEN` 放开，而 grab 会让 libinput 一直以为笔在 proximity，
连 stylus-touch 仲裁一起挂着。`inputN` 编号每次开机可能变，所以按设备名找节点。

**事件驱动（驱动 >= 1.0.3 + 可选 python3）**：守护进程不再每秒读一次属性，而是**阻塞等
通知**。驱动把那两个霍尔脚各申请了一个双边沿中断，跳变时先回写 `pen_present` 再
`sysfs_notify()`；kernfs 的通知既唤醒 `poll()` 也 kick fsnotify，所以等的一方可以只请求
`POLLPRI`（**不能带 POLLIN** —— sysfs 属性永远返回 `DEFAULT_POLLMASK`，带了就立刻返回，
见 `kernfs_generic_poll()` 上面那段内核注释；唤醒后要 seek+read 重新武装）。
`ra9530-charge-policy-wait.py` 就是干这个的（bash 没有 `poll()`），它的输出经一个 fifo
喂给守护进程的 `read -t`：**有事件就是毫秒级，没事件每 TICK 秒兜底对账一次**。

实测端到端（journal 微秒时间戳对齐驱动跳变与守护动作）：取下/吸回各两次都是
**3.4 / 5.4 / 4.8 / 5.8 ms**；同一个守护的旧版（1 Hz 轮询）是 505~1008 ms。

CPU：旧版 1 Hz 轮询时**闸门自己**就约 1.35% 一个核（每拍一次 `sleep` fork + 两次
`$(cat)` fork）。事件驱动后闸门约 **0.2%**（实测 2 ms/s）：等待器阻塞在 `poll()` 里
是 0，剩下的是兜底那一拍的两条 bash 内建 `read`（实测各 303 µs/次 —— sysfs 的
open+read 在 bash 里就这么贵）加一次 `kill -0`（26 µs）。另有每 120 秒一次的蓝牙
电量读取（`bluetoothctl` / `busctl`）约 0.4 s，折合平均 ~0.35%，那是旧版就有的开销，
与闸门无关。想再压就把 `TICK` 调大（代价是旧驱动/丢边沿时的兜底上限变长）。

驱动里还有一个 1 秒的 `detect_poll` 兜底：边沿是边沿触发的，挂起期间会丢；笔停在
磁吸场临界位置时霍尔也会在两个电平之间来回。5 秒的 monitor 对"停靠时屏蔽笔输入"
太粗，所以驱动自己每秒读那两个 GPIO（两次寄存器读，且只在状态真变时才 notify）。

**没有驱动 >= 1.0.3、或没有 python3 时**：守护自动退回每 TICK 秒（默认 1 秒）对账一次，
也就是旧行为，不会失效。

`/etc/systemd/system/ra9530-charge-policy.service` 这份手工单元**必须删掉**：`/etc`
会盖住包内的 `/usr/lib/systemd/system/` 那份，于是新装的停靠闸门逻辑根本不生效。

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
| `/etc/systemd/system/ra9530-charge-policy.service` | 手工时代那份；会盖住 `xiaomi-book-12.4-config` 装到 `/usr/lib/systemd/system/` 的同名单元（新版的停靠闸门就不生效了）。删之前先 `systemctl disable --now` |
| `/etc/udev/rules.d/9{0,1,2}-fastrpc*.rules` | 会盖住包里的 `/usr/lib/udev/rules.d/` 同名文件（内容相同，留着容易搞不清哪份生效） |
| `/etc/udev/rules.d/99-xiaomi-book-cover-internal.rules` | 会盖住 `xiaomi-book-12.4-config` 装到 `/usr/lib/udev/rules.d/` 的同名规则 |
| `/etc/libinput/local-overrides.quirks` | 旧的 libinput quirk（`MatchVendor` 在本机永远匹配不上，从未生效）；config 包已不再提供，可删 |
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
               --overwrite '/usr/lib/firmware/qcom/*' \
               --overwrite '/usr/lib/initcpio/install/xiaomi-book124-firmware' \
               --overwrite '/usr/lib/systemd/system/rmtfs.service' \
               --overwrite '/usr/local/bin/ra9530-*.sh' \
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
systemctl status ra9530-charge-policy.service   # 笔策略守护（充电阈值 + 停靠闸门）
cat /sys/class/input/input*/inhibited           # 笔吸着时 Stylus 那个应为 1、触摸屏为 0
```
