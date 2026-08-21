#!/bin/zsh
set -euo pipefail

UID_NUM="$(id -u)"
LABEL="com.doubao.audio-duck"
OLD_LABEL="com.wesleyli.doubao-audio-duck"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
OLD_PLIST="${HOME}/Library/LaunchAgents/${OLD_LABEL}.plist"
BIN="${HOME}/.local/bin/doubao-audio-duck"

for name in "${LABEL}" "${OLD_LABEL}"; do
  if launchctl print "gui/${UID_NUM}/${name}" >/dev/null 2>&1; then
    launchctl bootout "gui/${UID_NUM}/${name}" >/dev/null 2>&1 || true
  fi
done

rm -f "${PLIST}" "${OLD_PLIST}" "${BIN}"
rm -f /tmp/doubao-audio-duck.status /tmp/doubao-audio-duck.lock

# If we muted and then crashed, don't leave the Mac silent.
osascript -e 'set volume without output muted' >/dev/null 2>&1 || true

echo "已停止服务并删除 ${BIN} 与 LaunchAgent。"
echo "源码目录未删除：$(cd "$(dirname "$0")" && pwd)"
echo "日志仍在：${HOME}/Library/Logs/doubao-audio-duck.log"
echo "若要连源码一起删：rm -rf \"$(cd "$(dirname "$0")" && pwd)\""
