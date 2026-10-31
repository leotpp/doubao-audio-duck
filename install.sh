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


if ! command -v swiftc >/dev/null 2>&1; then
  echo "需要 Command Line Tools（swiftc）。请先运行：xcode-select --install" >&2
  exit 1
fi

mkdir -p "${BIN_DIR}" "${LAUNCH_DIR}" "${LOG_DIR}"

STAGE_DIR="$(mktemp -d "${PI_SCRATCH_DIR:-${TMPDIR:-/tmp}}/doubao-audio-duck.XXXXXX")"
trap 'rm -rf "${STAGE_DIR}"' EXIT
STAGED_BIN="${STAGE_DIR}/doubao-audio-duck"
echo "编译临时版本（通过自检后才替换 ${BIN}）…"
swiftc -O -o "${STAGED_BIN}" "${ROOT}/main.swift" \
  -framework CoreAudio -framework CoreGraphics -framework Carbon \
  -framework IOKit -framework Foundation -framework AppKit
"${STAGED_BIN}" --self-test

# SIGTERM must finish restoration before replacing the running executable.
for service in com.wesleyli.doubao-audio-duck "${LABEL}"; do
  if launchctl print "gui/${UID_NUM}/${service}" >/dev/null 2>&1; then
    old_pid="$(launchctl print "gui/${UID_NUM}/${service}" | awk '/^[[:space:]]*pid = / {print $3; exit}')"
    before_lines=0
    if [[ -f "${LOG_DIR}/doubao-audio-duck.log" ]]; then
      before_lines="$(wc -l < "${LOG_DIR}/doubao-audio-duck.log" | tr -d ' ')"
    fi
    launchctl bootout "gui/${UID_NUM}/${service}"
    if [[ -n "${old_pid}" ]]; then
      for attempt in {1..40}; do
        if ! kill -0 "${old_pid}" 2>/dev/null; then break; fi
        sleep 0.05
      done
      if kill -0 "${old_pid}" 2>/dev/null; then
        echo "旧进程未退出；中止替换。" >&2
        exit 1
      fi
      if ! tail -n "+$((before_lines + 1))" "${LOG_DIR}/doubao-audio-duck.log" | grep -q 'emergency restore signal=.*confirmed=true'; then
        echo "旧服务未确认静音恢复；中止替换，请检查日志与系统静音状态。原二进制保留。" >&2
        exit 1
      fi
      echo "旧服务已退出并确认恢复静音责任：pid=${old_pid}"
    fi
  fi
done
old_plist="${HOME}/Library/LaunchAgents/com.wesleyli.doubao-audio-duck.plist"
if [[ -f "${old_plist}" ]]; then rm -f "${old_plist}"; fi
install -m 755 "${STAGED_BIN}" "${BIN}"

# Only forward the tuning knobs the caller actually set. Hard-coding
# DUCK_FN_HOLD_MS here used to silently pin the daemon to the legacy
# wait-then-mute path, which is the behaviour that leaks playback into Doubao.
ENV_BLOCK=""
if [[ -n "${DUCK_FN_HOLD_MS:-}" || -n "${DUCK_FN_CONFIRM_MS:-}" ]]; then
  ENV_BLOCK="    <key>EnvironmentVariables</key>
    <dict>"
  if [[ -n "${DUCK_FN_HOLD_MS:-}" ]]; then
    ENV_BLOCK="${ENV_BLOCK}
        <key>DUCK_FN_HOLD_MS</key>
        <string>${DUCK_FN_HOLD_MS}</string>"
  fi
  if [[ -n "${DUCK_FN_CONFIRM_MS:-}" ]]; then
    ENV_BLOCK="${ENV_BLOCK}
        <key>DUCK_FN_CONFIRM_MS</key>
        <string>${DUCK_FN_CONFIRM_MS}</string>"
  fi
  ENV_BLOCK="${ENV_BLOCK}
    </dict>"
fi

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
${ENV_BLOCK}
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

launchctl bootstrap "gui/${UID_NUM}" "${PLIST}"
# Wait for this daemon's status, never mistake a previous process's file for success.
for attempt in {1..60}; do
  daemon_pid="$(launchctl print "gui/${UID_NUM}/${LABEL}" 2>/dev/null | awk '/^[[:space:]]*pid = / {print $3; exit}')"
  if [[ -n "${daemon_pid}" ]] && grep -q "pid=${daemon_pid} " /tmp/doubao-audio-duck.status 2>/dev/null; then break; fi
  sleep 0.1
done

if launchctl print "gui/${UID_NUM}/${LABEL}" 2>/dev/null | grep -q 'state = running'; then
  echo "已安装并启动：${LABEL}"
  echo "源码目录：${ROOT}"
  echo "可执行文件：${BIN}"
  echo "开机启动：${PLIST}"
  echo "日志：${LOG_DIR}/doubao-audio-duck.log"
  echo "运行模式：${BIN} --dump | grep duckMode"
  echo
  echo "自检：${BIN} --dump"
  if [[ -z "${daemon_pid}" ]] || ! grep -q "pid=${daemon_pid} .*hidInput=granted hidStarted=true" /tmp/doubao-audio-duck.status 2>/dev/null; then
    echo "注意：精确按键通道未就绪，已启用采麦降级；后台预采麦也会静音。"
    echo "adhoc 签名不保证重编译后保留权限。系统设置 → 隐私与安全性 → 输入监控，用 + 添加并允许：${BIN}"
    echo "手动请求：${BIN} --grant"
    echo "授权后重启：launchctl kickstart -k gui/${UID_NUM}/${LABEL}"
    open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent' || true
  fi
  if [[ -n "${daemon_pid}" ]] && grep -q "pid=${daemon_pid} " /tmp/doubao-audio-duck.status 2>/dev/null; then
    cat /tmp/doubao-audio-duck.status
  else
    echo "ERROR：daemon 尚未发布状态，不能确认识别通道健康。" >&2
  fi
else
  echo "LaunchAgent 已写入，但进程未在运行。看日志：${LOG_DIR}/doubao-audio-duck.log" >&2
  exit 1
fi
