#!/bin/bash
# 目标只读 root 所有的授权副本;用户可写 env.json 不能改变 root 巡检行为。
TARGET_FILE="/Library/Application Support/claude-switcher/tz-target"
LOG="__LOG_DIR__/tz-watchdog.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" >>"$LOG"
}

if [ ! -f "$TARGET_FILE" ] || [ -L "$TARGET_FILE" ]; then
    log "时区巡检目标缺失或不是普通文件($TARGET_FILE),本轮不修改系统时区"
    exit 0
fi
IFS= read -r TARGET < "$TARGET_FILE" || true
if ! [[ "$TARGET" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)+$ ]] || \
   [ ! -f "/usr/share/zoneinfo/$TARGET" ]; then
    log "时区巡检目标无效($TARGET_FILE),本轮不修改系统时区"
    exit 0
fi

current=$(readlink /etc/localtime 2>/dev/null)
if [ "$current" != "/var/db/timezone/zoneinfo/$TARGET" ]; then
    if /usr/sbin/systemsetup -settimezone "$TARGET" >>"$LOG" 2>&1; then
        log "时区异常: [$current] 已自动恢复为 $TARGET"
    else
        log "时区异常: [$current] 恢复为 $TARGET 失败"
    fi
fi
