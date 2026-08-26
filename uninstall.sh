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

# Restore output through the same Core Audio path as the daemon before the
# executable is removed. The old AppleScript form is not reliable on newer
# macOS locales and silently hid failures.
if [[ -x "${BIN}" ]]; then
  "${BIN}" --force-unmute >/dev/null 2>&1 || true
fi

rm -f "${PLIST}" "${OLD_PLIST}" "${BIN}"
rm -f /tmp/doubao-audio-duck.status /tmp/doubao-audio-duck.lock

echo "已停止服务并删除 ${BIN} 与 LaunchAgent。"
echo "源码目录未删除：$(cd "$(dirname "$0")" && pwd)"
echo "日志仍在：${HOME}/Library/Logs/doubao-audio-duck.log"
echo "若要连源码一起删：rm -rf \"$(cd "$(dirname "$0")" && pwd)\""
