# 这台机器上唯一能引导的 GRUB 核 —— 备份说明

`grubaa64.efi` 是从 linux-surface 的 **Surface Pro X 试验镜像**里手工拷出来的
GRUB 核，245760 字节：

```
sha256  204b6d8913d249c331ac13d689644f9342d8df7491fed0a9435b263d10a827ca
```

内部 ESP 上有两份**完全相同**的拷贝，都是这一份：

| 路径 | 作用 |
|---|---|
| `/boot/EFI/arch/grubaa64.efi` | UEFI 启动项 `arch`（`BootOrder` 里的 `0003`）指向它 |
| `/boot/EFI/Boot/bootaa64.efi` | 可移动设备/fallback 路径，固件 boot menu 也能选它 |

## 为什么不能换成 grub 包自己构建的核

Arch Linux ARM 的 `grub` 包（`2:2.14-1.1`）构建出来的核 **在本机起不来**（实测：
在 Windows 里把 UEFI 启动项指过去，进不了菜单）。对照：

| | 这一份（SPX 镜像） | ALARM `grub-install` 生成的 |
|---|---|---|
| 大小 / 唯一字符串 | 245760 / 1626 | 159744 / 672 |
| 内嵌设备树 | **有**（`xiaomi,book-12.4`、BOOK124 固件路径…） | 无 |
| 本机能否引导 | 能 | **不能** |
| PE 头 / 烘焙 prefix | PE32+ EFI application / ARM64 / `(,gpt1)/grub` | **完全相同** |
| 模块查找 | 共用 `/boot/grub/arm64-efi/` | 同上 |

ALARM 核里独有的非 DT 字符串是 0，说明两者是**同一个 GRUB 构建**，SPX 那份多出来的
正是内嵌的板级 DTB；既然 PE 头与 prefix 一致，起不来只能归因于代码级补丁差异。
结论：**永远不要在这台机器上跑 `grub-install`**（连 `--removable` 也不要 —— 它会覆盖
`/boot/EFI/Boot/bootaa64.efi`），也**不要**用 grub 包里的 `grubaa64.efi` 替换这两份。

## 恢复方法

只要还能进任何一个 EFI shell / 启动项，或从 U 盘启动（U 盘上的
`/EFI/BOOT/BOOTAA64.EFI` 就是同一份核），就能把文件拷回去：

```sh
# 挂上内部 ESP 后
install -Dm755 grubaa64.efi /mnt/EFI/arch/grubaa64.efi
install -Dm755 grubaa64.efi /mnt/EFI/Boot/bootaa64.efi
sha256sum /mnt/EFI/arch/grubaa64.efi /mnt/EFI/Boot/bootaa64.efi   # 应与 SHA256SUMS 一致
```

模块（`/boot/grub/arm64-efi/`，含提供 `devicetree` 命令的 `fdt.mod`）来自 grub 包，
可以随时用 `pacman -S grub` 重新装出来，不需要单独备份。

`/boot/grub/grub.cfg` 由 `grub-mkconfig` 生成（见 `xiaomi-book-12.4-config` 里的
`/etc/grub.d/09_xiaomi_book_dtb`），也不需要备份 —— 但**必须**保证生成的条目里有
`devicetree` 行。
