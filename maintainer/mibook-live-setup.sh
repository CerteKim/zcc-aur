#!/bin/bash
#
# mibook-live-setup.sh — 在 live U 盘的根里以 chroot 执行（由
# maintainer/make-mibook-usb.sh 复制到 <live根>/root/ 后运行）。
#
# 之所以是独立文件而不是塞进 `bash -c '……'`：那种写法里任何一个单引号都会提前
# 把外层字符串闭掉。上一版就因此把 `--overwrite '/boot/*'` 里的 /boot/* 交给了
# shell 展开，pacman 于是把 /boot/dtb、/boot/vmlinuz-linux-mibook 当成包文件去装，
# 报出 "error: '/boot/dtb': cannot open package file"。
#
# 出错时可以照着手动重跑：arch-chroot <live根> /bin/bash /root/mibook-live-setup.sh

set -e

msg() { echo "==> $*"; }

msg "同步软件包数据库"
pacman -Sy --noconfirm

msg "安装 live 系统本身要用的包（内核 + 本仓库的运行时包）"
#
# --overwrite /boot/*：/boot 就是这颗 U 盘的 ESP（p1），上面已经有我们放好的
# vmlinuz-linux-mibook、initramfs 和 DTB，而它们不属于任何包 —— 不覆盖的话
# pacman 会以 "exists in filesystem" 拒绝安装整个内核包。
#
# DKMS 那两个（ra9530-dkms、panel-himax-hx83121a-dkms）故意不装：它们要内核头文件
# 和编译时间，留在 /var/cache/mibook 里给"装到内部磁盘"用就够了。
pacman -U --noconfirm --overwrite '/boot/*' \
    /var/cache/mibook/linux-mibook-*.pkg.tar.* \
    /var/cache/mibook/xiaomi-book-12.4-*.pkg.tar.* \
    /var/cache/mibook/iio-sensor-proxy-ssc-*.pkg.tar.* \
    /var/cache/mibook/qrtr-*.pkg.tar.* \
    /var/cache/mibook/qmic-*.pkg.tar.* \
    /var/cache/mibook/pd-mapper-*.pkg.tar.* \
    /var/cache/mibook/rmtfs-*.pkg.tar.* \
    /var/cache/mibook/tqftpserv-*.pkg.tar.*

msg "安装救援/安装要用的工具"
pacman -S --noconfirm --needed \
    nano vim less arch-install-scripts \
    gptfdisk parted dosfstools btrfs-progs rsync efibootmgr iwd

msg "写 mkinitcpio 配置"
# ext4 根：这台机器的 autodetect 看不到 ext4（根和 SD 卡都是 btrfs），显式带上，
# 否则 live 根挂不起来。
sed -i "s|^HOOKS=.*|HOOKS=(base systemd autodetect microcode modconf xiaomi-book124-firmware kms keyboard sd-vconsole block filesystems fsck)|" /etc/mkinitcpio.conf
sed -i "s|^MODULES=.*|MODULES=(ext4)|" /etc/mkinitcpio.conf

msg "live 系统的收尾设置"
passwd -d root
systemctl enable iwd.service systemd-networkd.service
systemctl set-default multi-user.target
[[ -f /usr/local/bin/mibook-install.sh ]] && chmod +x /usr/local/bin/mibook-install.sh

msg "生成 live initramfs（写到 U 盘的 ESP 上）"
mkinitcpio -P

msg "live 系统就绪"
