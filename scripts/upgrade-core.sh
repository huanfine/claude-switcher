#!/bin/bash
# 把本机核心脚本升级到本仓库 main，专门修「新界面 + 旧脚本」这种版本错配。
#
# 背景:v1.7.1 一带的核心脚本不认识 node-scan / slot-node，界面调它们时旧脚本
# 回退出码 2 加一行 usage，界面就显示「扫描失败：脚本执行失败（退出码 2）」。
# 而旧脚本的 self_update 写死指向原上游 YOURSJEYO/claude-switcher，直接跑
# `claude-switch.sh update` 只会把旧版再拉一遍，永远升不上来。
#
# 所以这条命令不复用旧脚本的 update，而是：下载 → 校验 SHA256 → 语法检查 →
# 备份 → 迁移旧环境配置 → 落盘 → 自检 → 任一失败自动回滚。
# 不碰账号数据、不碰 Claude 进程、不碰看门狗、不删用户文件。
#
# 用法（可以直接远程执行）:
#   bash <(curl -fsSL https://raw.githubusercontent.com/huanfine/claude-switcher/main/scripts/upgrade-core.sh)
set -euo pipefail

REPO="${CLAUDE_SWITCHER_UPDATE_REPO:-huanfine/claude-switcher}"
BIN="$HOME/.local/bin/claude-switch.sh"
SUMS_URL="https://raw.githubusercontent.com/$REPO/main/SHA256SUMS"
CORE_URL="https://raw.githubusercontent.com/$REPO/main/core/claude-switch.sh"

die() { printf 'FAIL:%s\n' "$1" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "找不到 curl"
command -v shasum >/dev/null 2>&1 || die "找不到 shasum（本脚本面向 macOS）"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-switcher-upgrade.XXXXXX")"
# 只清自己创建的临时目录，绝不碰用户目录。
# 用「是否成功」标记兜底:任何一步非零退出（含 die 的 exit 1）都回滚 ——
# 不能只靠 ERR trap，die 走的是 exit，ERR 不会触发。
DONE=0
BACKUP=""
on_exit() {
    local rc=$?
    rm -rf "$WORK"
    if [ "$DONE" -ne 1 ] && [ "$rc" -ne 0 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        cp -p "$BACKUP" "$BIN" 2>/dev/null && chmod +x "$BIN" 2>/dev/null
        printf '    已回滚到升级前的脚本\n' >&2
    fi
}
trap on_exit EXIT

printf '==> 下载核心脚本与校验清单 (%s)\n' "$REPO"
curl -fsSL --max-time 30 "$CORE_URL" -o "$WORK/claude-switch.sh" \
    || die "下载 core/claude-switch.sh 失败（网络问题，稍后再试）"
curl -fsSL --max-time 20 "$SUMS_URL" -o "$WORK/SHA256SUMS" \
    || die "下载 SHA256SUMS 失败（网络问题，稍后再试）"
[ -s "$WORK/claude-switch.sh" ] && [ -s "$WORK/SHA256SUMS" ] \
    || die "下载内容为空，已中止"

WANT=$(awk '$2=="core/claude-switch.sh" {print $1; exit}' "$WORK/SHA256SUMS")
[ -n "$WANT" ] || die "校验清单里没有 core/claude-switch.sh，已中止"
GOT=$(shasum -a 256 "$WORK/claude-switch.sh" | awk '{print $1}')
[ "$WANT" = "$GOT" ] || die "SHA256 不符（期望 $WANT，实得 $GOT），已中止，不写入任何文件"
printf '    SHA256 一致: %s…\n' "${GOT:0:12}"

bash -n "$WORK/claude-switch.sh" || die "新脚本语法检查没过，已中止"
grep -q 'slot-node)' "$WORK/claude-switch.sh" \
    || die "新脚本里找不到 slot-node 命令，可能拉到了旧分支，已中止"

[ -d "$(dirname "$BIN")" ] || mkdir -p "$(dirname "$BIN")"
if [ -f "$BIN" ]; then
    BACKUP="$BIN.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$BIN" "$BACKUP" || die "备份旧脚本失败，已中止"
    printf '==> 已备份旧脚本: %s\n' "$BACKUP"
fi

# 落盘前先把旧脚本头部的 5 个环境值迁进 ~/.claude-switcher/env.json。
# 新版核心已经不用脚本头部存配置，直接覆盖会让代理组/地区目标丢掉。
if [ -n "$BACKUP" ]; then
    printf '==> 迁移旧环境配置\n'
    bash "$WORK/claude-switch.sh" _support env-migrate "$BACKUP" >/dev/null 2>&1 \
        || printf '    旧配置无需迁移或迁移跳过（新版会从运行中的内核重新探测）\n'
fi

printf '==> 安装新核心脚本\n'
cp "$WORK/claude-switch.sh" "$BIN" || die "写入失败"
chmod +x "$BIN"

printf '==> 自检\n'
bash -n "$BIN" || die "安装后语法检查失败"
HELP_OUT=$("$BIN" help 2>&1) || die "新脚本无法执行 help"
printf '%s' "$HELP_OUT" | grep -q 'node-scan' || die "新脚本不认识 node-scan"
printf '%s' "$HELP_OUT" | grep -q 'slot-node' || die "新脚本不认识 slot-node"
STATUS_OUT=$("$BIN" status 2>&1) || die "新脚本无法读取 status"
printf '%s' "$STATUS_OUT" | grep -q 'current=' || die "status 输出异常: $STATUS_OUT"

DONE=1
printf '\nOK:核心脚本已升级。回到界面点「重新检查」，或执行:\n'
printf '   %s node-scan\n' "$BIN"
if [ -n "$BACKUP" ]; then
    printf '\n回滚（如需）: cp -p "%s" "%s"\n' "$BACKUP" "$BIN"
fi
exit 0
