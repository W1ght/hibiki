# Windows-orchestrated cross-host integration test on the remote Mac.
# Pushes committed history to the Mac, fast-forwards its checkout, then runs a
# Hibiki integration test against the REAL macOS app under FUSHI_TEST_HIDDEN
# (the runner parks itself off-screen + .accessory + non-key, so it never
# appears or steals foreground — see fushi/macos/Runner/MainFlutterWindow.swift).
# Phase 3 of the test-flow refactor (Windows is the conductor; the Mac runs).
#
# The test TARGET must be committed first (the Mac builds from committed
# history, not the working tree). Lives next to sync_to_mac.ps1 at the repo root.
#
# Usage (from the repo root):
#   .\tool\run_mac_itest.ps1
#   .\tool\run_mac_itest.ps1 integration_test/desktop_reader_css_dom_test.dart
#   .\tool\run_mac_itest.ps1 integration_test/x_itest.dart -DartDefine FUSHI_PROBE_EPUB=/Users/wight/dev/probe-books/book.epub
#
# 2026-09-12 起的 Mac 形态（旧 Mac 已不在）：主机走本机 ~/.ssh/config 的 `Host mac`
# 别名（wight@192.168.1.155，密钥登录）；Mac 上的检出是 `~/dev/hibiki`，从 GitHub
# fork（origin=W1ght/hibiki）浅克隆而来，flutter 用 `~/fvm/versions/3.41.6`。本机是
# blob:none 的 partial clone，推不动完整对象到 Mac，所以同步改成「本机 push 到
# origin 的 $Branch → Mac `git pull --ff-only origin $Branch`」。测试一律带
# `--dart-define=FUSHI_TEST_ROOT=~/dev/fushi-test-root`：Mac 的真库是更新的
# schema（v102），裸跑会撞 FushiDatabaseDowngradeException。
#
# `-Ios`：同一份测试改跑在 Mac 上的 iOS 模拟器（2026-09-12 装好 iOS 26.5 运行时，
# 设备 FushiProbe = iPhone 17 Pro，udid 见 $IosDevice；关机状态会先 boot）。iOS
# 沙盒里 FUSHI_TEST_ROOT 那种绝对路径没意义也不需要——模拟器容器本就是干净库，
# 所以不带隔离根。iOS 构建要 Rust 的 aarch64-apple-ios-sim 目标（已装）与
# `~/.cargo/bin` 在 PATH。想看真屏用 `xcrun simctl io <udid> screenshot x.png`
# （Flutter 侧 captureFlutterFrame 在 iOS 上抓不到像素，WebView 截图可用）。
param(
  [string]$Target = "integration_test/desktop_settings_smoke_test.dart",
  [string]$Branch = "mac-probe",
  [string[]]$DartDefine = @(),
  [switch]$Ios,
  [string]$IosDevice = "969CB3A4-036B-4494-824E-087A427F3C10"
)

$mac = "mac"

Write-Host "[mac-itest] pushing HEAD to origin/$Branch..." -ForegroundColor Cyan
git push origin "HEAD:refs/heads/$Branch"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Build the remote bash script with explicit LF joins, then ship it base64-
# encoded. base64 dodges two Windows-side traps that silently broke earlier
# attempts: (1) PowerShell re-quoting a command full of ;/&&/$ as a native-exe
# argument, and (2) PowerShell piping to stdin with CRLF line endings (the \r
# corrupts each bash command). The decoded script sets the pinned toolchain
# env, fast-forwards the checkout, and runs the test hidden on -d macos.
$defines = @()
if (-not $Ios) { $defines += "--dart-define=FUSHI_TEST_ROOT=`$HOME/dev/fushi-test-root" }
foreach ($d in $DartDefine) { $defines += "--dart-define=$d" }
$defineArgs = $defines -join ' '
$device = if ($Ios) { $IosDevice } else { "macos" }
$rootEnv = if ($Ios) { "" } else { "FUSHI_TEST_ROOT=`$HOME/dev/fushi-test-root " }
$lines = @(
  'export LANG=en_US.UTF-8',
  'export PATH=$HOME/fvm/versions/3.41.6/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH',
  'export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890',
  "cd ~/dev/hibiki && git pull --ff-only origin $Branch && cd fushi"
)
if ($Ios) {
  $lines += "xcrun simctl boot $IosDevice 2>/dev/null || true"
}
$lines += "FUSHI_TEST_HIDDEN=1 ${rootEnv}flutter test $Target -d $device --no-pub $defineArgs"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))

$where = if ($Ios) { "iOS simulator $IosDevice" } else { "macOS (hidden runner)" }
Write-Host "[mac-itest] running $Target on $where..." -ForegroundColor Cyan
ssh $mac "echo $b64 | base64 --decode | bash"
exit $LASTEXITCODE
