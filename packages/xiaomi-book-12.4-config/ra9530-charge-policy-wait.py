#!/usr/bin/env python3
"""每收到一次 sysfs 通知就打一行到 stdout —— 给 ra9530-charge-policy.sh 当阻塞等待器。

内核的契约写在 kernfs_generic_poll() 上面那段注释里（fs/kernfs/file.c）：

  * 先把内容读一次（快照），然后 poll/select 等变化；
  * 驱动侧调 sysfs_notify() 时，poll 会额外置上 EPOLLERR|EPOLLPRI；
  * **只能请求 POLLPRI** —— sysfs 属性永远返回 DEFAULT_POLLMASK（可读），
    请求 POLLIN 会让 poll 立刻返回，等于空转；
  * 唤醒之后必须 close+reopen，或者 seek 回 0 再读一次，否则不会再次通知。

所以这里：os.read() 快照 → poll(POLLPRI) 阻塞 → lseek+read 重新武装 → 打一行。
路径不存在时（驱动还没加载）不退出，等着重试；属性被移除（模块重载）才退出，
交给调用方重新解析路径再起一个。
"""

import os
import select
import sys
import time


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: ra9530-charge-policy-wait.py <sysfs 属性> [重试间隔秒]", file=sys.stderr)
        return 2

    path = sys.argv[1]
    retry = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0

    fd = None
    while fd is None:
        try:
            fd = os.open(path, os.O_RDONLY)
        except OSError:
            # 驱动可能还没加载 / 设备不在；等一会儿再看
            time.sleep(retry)

    poller = select.poll()
    poller.register(fd, select.POLLPRI)

    while True:
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            value = os.read(fd, 4096)          # 快照（同时也是重新武装）
        except OSError:
            return 1                           # 属性没了：让调用方重来

        try:
            poller.poll()                      # 阻塞到 sysfs_notify()
        except OSError:
            return 1

        print(value.strip().decode(errors="replace"), flush=True)


if __name__ == "__main__":
    sys.exit(main())
