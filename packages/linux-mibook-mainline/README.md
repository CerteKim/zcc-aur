# linux-mibook-mainline

Xiaomi Book S 12.4（SC8180X / TM2133）的主线内核包：**上游 Linux 7.2 官方
tarball + 一套自带的补丁集**。

和 `packages/linux-mibook` 的区别：

| | `linux-mibook` | `linux-mibook-mainline` |
| --- | --- | --- |
| 源 | 本地内核镜像的 `xiaomi-mainline-panel2` 分支（6.18.2，含 linux-surface 栈） | `cdn.kernel.org` 的 `linux-7.2.tar.xz`（160 MB）+ 29 个补丁文件 |
| 与上游的差 | 一个 3+ GB 的 clone，差分不可读 | 29 个补丁文件，`git format-patch` 的产物 |
| 视频（IRIS/VPU） | 带 parked 的 bring-up 代码 | 不带（驱动不移植，DT 节点保持 disabled） |

## 状态（2026-10-08 晚）：7.2 的 GPU/GMU 静默停摆已修复

进 GNOME 几十秒后 GPU 卡死、GMU 不再响应 HFI 的问题，病根是上游 7.2 的
`60a4e18e0e8a`（"drm/msm/adreno: Do CX GBIF config before GMU start"）：它把
`GBIF_QSB_SIDE0..3 = 0x00071620` 从 `hw_init()` 的 `a640_family` 分支搬进 catalog 的
`a640_gbif` reglist 时，**漏给 A640 / A680（`ADRENO_6XX_GEN2`）挂上这个 list**，而
`hw_init()` 里剩下的那份只覆盖 `a610_family` → GEN2 的 GBIF QoS 侧配置整批丢失
（6.18 是给整个 a640 family 写的）。GBIF 在 CX 域、`a6xx_recover()` 复位的是 GX 域，
所以复位也救不回来。补丁 0028（commit `c1bf1df572f4`）给两个 GEN2 条目各补一行
`.gbif_cx = a640_gbif,` 后实测通过。

完整排查过程与现场状态见
`/home/certe/aarch64-packages/linux-surface/linux-7.2-gpu-wedge.md`。

同一晚把三个纯调试补丁从序列里摘掉了（见下面的 `drop-commits.sh`）：
`msm.no_gpu_recovery` 调试开关及其 revert（净零）、`report UBWC as unsupported`
（已验证无效，且留着只会让 GPU 退回线性缓冲）。

## 维护补丁集

权威副本是内核镜像里的开发分支；包目录里平铺的 `00??-*.patch` 是它的导出产物
（makepkg 只按 basename 在当前目录找本地源，所以补丁不能放子目录）：

* 开发树：`/home/certe/aarch64-packages/linux-surface/src/kernel-7.2`
  （`linux-surface/kernel` 这个 mirror 的一个 worktree）
* 分支：`xiaomi-mainline-7.2`，基线：`upstream-v7.2`（`8d3ae59288f1`）

改完代码 → 整理提交 → 重新导出：

```bash
cd ~/zcc-aur/packages/linux-mibook-mainline
./regen-patches.sh            # 清掉旧补丁并用 git format-patch 重新导出
makepkg -s                    # 构建（约 1~2 小时）
```

从序列里**摘掉**某个提交（别用 `git revert`，那会在序列里留下垃圾提交）：

```bash
./drop-commits.sh -n <hash> <hash>    # 先 dry-run，看会摘谁（hash 或 subject 片段）
./drop-commits.sh    <hash> <hash>    # 真摘，并自动跑 regen-patches.sh
# 例：2026-10-08 晚摘掉 no_gpu_recovery 那对和 UBWC 调试补丁
#   ./drop-commits.sh 37368a6ba212 4f4428b828f4 3f8e2efe10f8
```

`drop-commits.sh` 用 `GIT_SEQUENCE_EDITOR` 非交互地删 `rebase -i` 的 todo 行，接受
hash 或 subject 片段；改写前把旧 tip 记到 `refs/backup/drop-commits-<时间戳>`，
rebase 冲突会自动 abort（仓库保持原样）。摘完补丁会**重新编号**。

⚠️ `makepkg -e`（`--noextract`）**不会**刷新 `src/` 里的补丁符号链接，也不会重新
应用补丁：增量流程 `makepkg -e --noprepare -f` 要求先把改动同步进
`src/linux-7.2`（补丁增删后要么手工同步，要么全量 `makepkg -s` 重建）。

上游基线要跟进时（例如 7.3）：

```bash
git -C /home/certe/aarch64-packages/linux-surface/kernel fetch --no-tags \
    https://github.com/torvalds/linux.git refs/tags/v7.3:refs/tags/upstream-v7.3
# 在开发树里 rebase 到新基线，解决冲突，然后
./regen-patches.sh xiaomi-mainline-7.3 upstream-v7.3
# PKGBUILD: 改 pkgver/pkgrel、tarball URL 与第一项 sha256sums
```

## 补丁内容（29 个）

设备树 / binding（0001–0003、0015、0016、0029）：

* `dt-bindings: mmc: qcom,sdhci-msm: add qcom,sc8180x-sdhci`
* `dt-bindings: media: qcom,sm8250-venus: add qcom,sc8180x-iris`
* `dt-bindings: display: panel: himax,hx83121a: add csot,pnc357db1-4`
* `arm64: dts: qcom: sc8180x: describe the SLPI, SDHC2, DSI and IRIS blocks`
* `arm64: dts: qcom: add the Xiaomi Book S 12.4 (a51)`
* `arm64: dts: qcom: sc8180x-xiaomi-book-12.4: drop the duplicate PCIe2 PERST#`

显示（0004–0006、0018–0020）：

* `drm/panel: himax-hx83121a: CSOT PNC357DB1-4`（单 DSI0 + 单 DSC slice）
* `drm/msm/dpu: 单接口单 slice 用一个 DSC block`
* `drm/msm/dsi: 视频模式禁用 wide bus`
* `drm/msm/dsi/phy: 先给 digital top 上电再起 7nm PLL` —— 上游 cherry-pick（Dmitry
  Baryshkov, 2026-09-24），基线到 7.3 后可删
* `drm/msm/dpu: DSC active width 用 DIV_ROUND_UP`
* `drm/msm/dpu: 不宣告 UBWC scanout` —— **待定**：原来怀疑的 UBWC 病根其实是 GBIF，
  恢复压缩 scanout 需要单独一轮上机验证

音频 / SoundWire / SLIMbus（0010–0013、0017）：

* `ASoC: qcom: sdm845: Xiaomi Book 12.4 声卡`
* `ASoC: wsa881x: PA 增益跨 DAPM 保持`
* `ASoC: wcd934x: 预置 SLIM RX 端口 + 错误处理`
* `slimbus: qcom-ngd: 后续 capability 消息里解析地址`
* `soundwire: qcom: AHB/FIFO/IRQ 加固`

GPU / GMU（0007、0021–0028）：

* `drm/msm/adreno: a680 固件名`
* `drm/msm/a6xx: 检查 pm_runtime_resume_and_get()` —— 上游 cherry-pick（Roman
  Demidov, 2026-09-04），7.3 后可删
* `arm64: dts: 本板用高 bin 的 670MHz GPU DVFS profile`
* `drm/msm/a6xx: 不在 GPU PM 路径里门控 GMU 时钟`
* `drm/msm/a6xx: Debug HFI queue 只在存在的平台上注册`
* `soc: qcom: ubwc: 本板用 LPDDR4X 的 highest bank bit（15）` —— 摘掉 UBWC 调试补丁后
  它是**必须**的
* `drm/msm/a6xx: Fix stale rpmh votes after suspend` —— 上游 cherry-pick（2026-06
  系列），7.3 后可删
* `drm/msm: Recover HW before retire hung submit` —— 同系列，7.3 后可删
* **`drm/msm/adreno: restore the CX GBIF config on A640 and A680`** —— 本次病根的修复
  （commit `c1bf1df572f4`），通用缺陷、值得发上游，建议带
  `Fixes: 60a4e18e0e8a` 与 `Signed-off-by`

其它（0008、0009、0014）：

* `clk: qcom: videocc-sm8150: qcom,sc8180x-videocc`
* `remoteproc: qcom_q6v5_pas: sc8180x SLPI PAS`
* `tools/lib/bpf: strstr/strchr 结果强转`

> 2026-10-08 晚摘掉的三个（不在上面 29 个里）：`msm.no_gpu_recovery` 调试开关及其
> revert（净零）、`drm/msm/adreno: report UBWC as unsupported on the Xiaomi Book S 12.4`。

## 明确不在补丁集里的

* **IRIS/VPU 视频**：`xiaomi-mainline-panel2` 上的 bring-up 代码（iris 13 文件、
  `qcom_scm` 调试调用、`mdt_loader` 的 `skip_pas_mem_setup`）。上游 7.2 把
  iris 平台文件重构掉了，而硬件本身卡在 TZ/VTL1；DT 里 `venus` 节点保持
  `disabled`，等驱动可用了再单独加一组补丁。
* **7.2 已经上游的部分**：Himax HX83121A 驱动与 binding、WCN3998 ROM 版本、
  sdhci-msm HS400 倍频、a6xx IFPC NULL 保护与 preempt 顺序、phy 的
  sc8180x 条目、gcc-sc8180x PCIe GDSC retention（`ccb92c78b42e`）。
* **`drivers/base/dd.c` 的 fw_devlink hack**：7.2 已有
  `CONFIG_DRIVER_DEFERRED_PROBE_TIMEOUT`，需要时用 config/cmdline 表达。
* **`drivers/firmware/efi/efi.c` 的 ResetSystem hack**：本机 cmdline 已经有
  `efi=noruntime`，那段（还缺大括号）没有实际作用。

## 配置

`base.config` 是这台机器 bring-up 用的 ALARM 配置，`xiaomi-only.config` 是
在此之上的精简片段；`prepare()` 用 `merge_config.sh` 合并后跑 `olddefconfig`，
7.2 新增/删除的符号由它处理。已经从片段里删掉的死符号：
`DRM_DP_AUX_BUS`、`SPI_HID`（7.2 移除/改名）、`RTC_DRV_SURFACE`、`UCSI_GLINK`
（linux-surface 栈才有，本包不带；USB-C 走 mainline 的 `UCSI_PMIC_GLINK`，
在 `base.config` 里）。

## 安装注意

包名不同，`/boot` 下的路径都是自己的：

```
/boot/vmlinuz-linux-mibook-mainline
/boot/initramfs-linux-mibook-mainline.img
/boot/dtb/linux-mibook-mainline/qcom/sc8180x-xiaomi-book-12.4.dtb
```

GRUB 条目现在两条都在（`linux-mibook` 6.18 与 `linux-mibook-mainline` 7.2），
`pacman -U` 装完包会自动重生成 initramfs；建议保留 6.18 条目可回退。
