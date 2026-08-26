#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${HOME}/.local/bin"
BIN="${BIN_DIR}/doubao-audio-duck"
LAUNCH_DIR="${HOME}/Library/LaunchAgents"
LABEL="com.doubao.audio-duck"
PLIST="${LAUNCH_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs"
UID_NUM="$(id -u)"

old_plist="${HOME}/Library/LaunchAgents/com.wesleyli.doubao-audio-duck.plist"
if launchctl print "gui/${UID_NUM}/com.wesleyli.doubao-audio-duck" >/dev/null 2>&1; then
  launchctl bootout "gui/${UID_NUM}/com.wesleyli.doubao-audio-duck" >/dev/null 2>&1 || true
fi
if [[ -f "${old_plist}" ]]; then
  rm -f "${old_plist}"
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "需要 Command Line Tools（swiftc）。请先运行：xcode-select --install" >&2
  exit 1
fi

mkdir -p "${BIN_DIR}" "${LAUNCH_DIR}" "${LOG_DIR}"

echo "编译 ${BIN} …"
swiftc -O -o "${BIN}" "${ROOT}/main.swift" \
  -framework CoreAudio -framework CoreGraphics -framework Carbon \
  -framework Foundation -framework AppKit

chmod +x "${BIN}"

cat > "${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BIN}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>DUCK_FN_HOLD_MS</key>
        <string>${DUCK_FN_HOLD_MS:-300}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/doubao-audio-duck.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/doubao-audio-duck.log</string>
</dict>
</plist>
EOF

if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
  launchctl bootout "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
  sleep 0.2
fi
launchctl bootstrap "gui/${UID_NUM}" "${PLIST}"
launchctl kickstart -k "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1 || true
sleep 0.4

if launchctl print "gui/${UID_NUM}/${LABEL}" 2>/dev/null | grep -q 'state = running'; then
  echo "已安装并启动：${LABEL}"
  echo "源码目录：${ROOT}"
  echo "可执行文件：${BIN}"
  echo "开机启动：${PLIST}"
  echo "日志：${LOG_DIR}/doubao-audio-duck.log"
  echo
  echo "自检：${BIN} --dump"
else
  echo "LaunchAgent 已写入，但进程未在运行。看日志：${LOG_DIR}/doubao-audio-duck.log" >&2
  exit 1
fi
