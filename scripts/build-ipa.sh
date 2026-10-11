#!/bin/bash
# 构建 SysProbe 的未签名 .ipa。
#
#   bash scripts/build-ipa.sh
#
# 未签名包不含任何签名身份、描述文件或 team ID，安装时由你自己签（巨魔 / AltStore /
# SideStore / Sideloadly / Xcode 均可）。
#
# 注意：仓库里保存的可执行位可能丢失（例如通过 API 推送），所以 CI 与文档一律用
# `bash scripts/build-ipa.sh` 调用，不要依赖 `./`。
#
# 另：**本文件必须是 LF 行尾。** Windows 上用 Python 脚本改文件时，
# `Path.write_text(text)` 不指定 `newline` 会把每个 `\n` 写成 `\r\n`；
# 到了 macOS 上就是 `set -euo pipefail` 被劈成两行：
#
#     scripts/build-ipa.sh: line 11: set: pipefail
#     : invalid option name
#
# 报错完全指不到行尾，极易误判成语法问题。`.gitattributes` 里的 `eol=lf` 只约束
# **git 自己**（add / checkout），管不到走 Git Data API 的推送脚本 —— 那个直接读
# 工作区原始字节。所以推送前那道 LF 规范化是必要的，别去掉。
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="SysProbe"
PROJECT="SysProbe.xcodeproj"
BUILD_DIR="build"
DERIVED="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/export"
APP="$DERIVED/Build/Products/Release-iphoneos/$SCHEME.app"

# 版本号：优先取触发构建的 tag，其次取最近的 tag，最后回退到工程里的默认值。
if [ -z "${MARKETING_VERSION:-}" ]; then
  tag=$(git tag --points-at HEAD --list 'v*' 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$tag" ] || tag=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  [ -z "$tag" ] || MARKETING_VERSION="${tag#v}"
fi
if [ -z "${CURRENT_PROJECT_VERSION:-}" ]; then
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD 2>/dev/null || true)
fi

overrides=()
[ -z "${MARKETING_VERSION:-}" ] || overrides+=("MARKETING_VERSION=$MARKETING_VERSION")
[ -z "${CURRENT_PROJECT_VERSION:-}" ] || overrides+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION")
echo "==> Version ${MARKETING_VERSION:-(project file)} build ${CURRENT_PROJECT_VERSION:-(project file)}"

# 充电守护进程。
#
# **刻意不放在 Sources/ 里当普通资源** —— 那样 Xcode 会去猜一个没有扩展名的
# Mach-O 是什么类型，而且本地没下载过时 XcodeGen 会因为路径不存在直接失败。
# 它由这个脚本在打包阶段直接拷进 .app，见下面的 Packaging 一段。
#
# 先取再构建：下载失败（网络、上游删了 release、校验值对不上）应该在这里就炸，
# 而不是等 xcodebuild 跑完十分钟之后才报。
bash scripts/fetch-daemon.sh

# 生成 .xcodeproj。仓库里不提交工程文件，避免手写 pbxproj 出错；
# 每次构建都由 project.yml 重新生成，保证与目录结构一致。
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> xcodegen not found, installing"
  brew install xcodegen
fi
echo "==> Generating $PROJECT"
xcodegen generate --spec project.yml

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Swift 会把源码与中间产物的绝对路径烘进二进制（debug info、#file 元数据），
# 未签名包里也会带上构建者的家目录。把仓库根映射成一个固定占位路径。
REMAP=(
  "OTHER_SWIFT_FLAGS=-file-prefix-map $PWD=/SysProbe"
  "OTHER_CFLAGS=-ffile-prefix-map=$PWD=/SysProbe"
)

echo "==> Building unsigned"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  "${REMAP[@]}" \
  ${overrides[@]+"${overrides[@]}"}

[ -d "$APP" ] || { echo "no .app at $APP" >&2; exit 1; }

echo "==> Packaging"
rm -rf "$BUILD_DIR/Payload"
mkdir -p "$BUILD_DIR/Payload" "$EXPORT_DIR"
cp -R "$APP" "$BUILD_DIR/Payload/"
rm -rf "$BUILD_DIR/Payload/$SCHEME.app/_CodeSignature"

# 充电守护进程放进包根目录。
#
# 位置不是随便定的：它对**裸可执行文件**调 `NSBundle.mainBundle.bundlePath`，
# 而裸可执行的 mainBundle 就是它所在的那个目录。放在 PlugIns/ 或 Resources/
# 底下都会让它的 web root 指错地方 —— 而它不会报错，只是所有静态请求 404。
# 放在包根目录，它和 `www/` 才在同一层。
cp Sources/ChargeControl/Resources/ChargeLimiterDaemon "$BUILD_DIR/Payload/$SCHEME.app/ChargeLimiterDaemon"
# zip 保留执行位，装到设备上才起得来。上游已经 strip 过，这里不再动它 ——
# 二次 strip 没有好处，反而会改掉校验值。
chmod 755 "$BUILD_DIR/Payload/$SCHEME.app/ChargeLimiterDaemon"

# ── 维护工具（重启设备 / 注销）──────────────────────────────────────────────
#
# 源码在 `Tools/` 而不是 `Sources/`：它有**自己的 `main()`**，一旦被 XcodeGen 当成
# target 的源文件编进去，就会和 App 的 `main` 撞符号、链接直接失败。放在 Sources/
# 之外是**结构性**保证，不靠 project.yml 里一条随时可能被删掉的 `excludes`。
#
# 用 clang 直编，**不新开 Xcode target**：iOS 的「命令行工具」在 Xcode 里没有模板，
# 要靠手写 PRODUCT_TYPE 才编得出来；而这里要的只是一个静态链接的裸可执行文件，
# 一个 clang 调用就够了，也更容易看出它到底编了些什么。
TOOL_SRC="Tools/RootTool.c"
TOOL="$BUILD_DIR/Payload/$SCHEME.app/SysProbeRootTool"
[ -f "$TOOL_SRC" ] || { echo "::error::$TOOL_SRC is missing" >&2; exit 1; }

echo "==> Building SysProbeRootTool"
# `-framework CoreFoundation` 是给「关温控」那一组用的：它要按原格式读、改、写回
# launchd 的 disabled.plist（二进制 plist），用 CFPropertyList 是唯一稳的做法。
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=16.2 \
  -O2 -Wall \
  -framework CoreFoundation \
  -o "$TOOL" "$TOOL_SRC"
# 同上：zip 保留执行位，装到设备上才起得来。
chmod 755 "$TOOL"

# 链接器会把每个目标文件的绝对路径记进符号表（N_OSO），-file-prefix-map 覆盖不到，
# 剥掉调试与本地符号即可去掉。dSYM 仍留在 DerivedData 里备用。
xcrun strip -S -x "$BUILD_DIR/Payload/$SCHEME.app/$SCHEME"
# 扩展是 PlugIns 里的独立 bundle，有自己的可执行文件与调试映射，要单独处理。
while IFS= read -r -d '' appex; do
  rm -rf "$appex/_CodeSignature"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  xcrun strip -S -x "$appex/$executable"
done < <(find "$BUILD_DIR/Payload/$SCHEME.app" -name '*.appex' -type d -print0)

# ── 签名 ────────────────────────────────────────────────────────────────────
#
# 这个包**必须**带 entitlements 才能工作，所以构建时就要签一次 —— 尽管它是个
# 「未签名 ipa」。
#
# 原因：TrollStore 安装时会**保留** IPA 里已经存在的 entitlements。而充电控制
# 要 `posix_spawn` 一个 root 子进程，靠的正是 Support/SysProbe.entitlements 里的
# `platform-application` / `persona-mgmt` / `no-sandbox` / `no-container`。
# 少了它们，包照样能装、界面照样能开、开关照样能点，但**充电一点都停不下来**，
# 而且不会有任何报错 —— 这是整个集成里最难从代码侧看出来的失败模式。
#
# 用 `ldid -S`（ad-hoc 签名 + 指定 entitlements）而不是 `codesign`：
# `codesign` 要一个可用的签名身份，而这里本来就不该有身份 —— 侧载包的最终签名
# 由用户在设备上做（巨魔 / AltStore / SideStore / Sideloadly）。
#
# 顺序是 strip 之后才签，反过来会被 strip 作废。
#
# 扩展（负一屏）也要签一份**最小** entitlements。它默认被沙箱挡住，读不到 HUD
# 写在 /var/tmp 与 Caches 里的共享指标文件（两个路径都在它容器之外），于是退化成
# **自己采样** —— 结果就是负一屏的占用/频率和主 App、Statusbar 不是同一个数，
# 而且静默、无任何报错。这里只授「读文件」这一件事，别把主 App 那套
# posix_spawn / 电源权限也塞进去。
ENTITLEMENTS="Support/SysProbe.entitlements"
EXTENSION_ENTITLEMENTS="Support/TodayExtension.entitlements"
# 维护工具用**自己那份**：它要的权限（platform-application / no-container /
# no-sandbox）与主 App 那份完全是两回事，别合并 —— 见那个文件的注释。
TOOL_ENTITLEMENTS="Support/SysProbeRootTool.entitlements"
if ! command -v ldid >/dev/null 2>&1; then
  echo "==> ldid not found, installing"
  brew install ldid
fi
for binary in "$BUILD_DIR/Payload/$SCHEME.app/$SCHEME" \
              "$BUILD_DIR/Payload/$SCHEME.app/ChargeLimiterDaemon"; do
  ldid -S"$ENTITLEMENTS" "$binary"
done
ldid -S"$TOOL_ENTITLEMENTS" "$TOOL"
# 每个 .appex 单独签它的可执行文件。
for appex in "$BUILD_DIR/Payload/$SCHEME.app"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  ext_binary="$appex/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  ldid -S"$EXTENSION_ENTITLEMENTS" "$ext_binary"
done
echo "==> Signed SysProbe + ChargeLimiterDaemon with $ENTITLEMENTS, SysProbeRootTool with $TOOL_ENTITLEMENTS, extension(s) with $EXTENSION_ENTITLEMENTS"

# 包名带上版本号：`SysProbe-0.0.6.ipa`。取不到版本号时退回 `unsigned` ——
# 宁可叫 `SysProbe-unsigned.ipa`，也不要出现 `SysProbe-.ipa` 这种残名。
IPA_NAME="$SCHEME-${MARKETING_VERSION:-unsigned}.ipa"
(cd "$BUILD_DIR" && zip -qry "export/$IPA_NAME" Payload)
rm -rf "$BUILD_DIR/Payload"

IPA="$EXPORT_DIR/$IPA_NAME"

echo "==> Checking the ipa"
work=$(mktemp -d)
unzip -q "$IPA" -d "$work"
app_dir="$(ls -d "$work"/Payload/*.app)"
echo "  app        : $(basename "$app_dir")"
echo "  version    : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_dir/Info.plist"))"
echo "  minimum OS : $(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app_dir/Info.plist" 2>/dev/null || echo '-')"
for appex in "$app_dir"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  echo "  extension  : $(basename "$appex") -> $(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$appex/Info.plist")"
done
# 图标：Info.plist 里的 CFBundleIconName 必须指到 AppIcon，并且 bundle 根目录要真的
# 躺着 actool 渲染出来的 PNG。只有 Assets.car 是不够的 —— 主屏读的是那几个 PNG。
echo "  icon name  : $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$app_dir/Info.plist" 2>/dev/null || echo '-')"
icon_files=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles' "$app_dir/Info.plist" 2>/dev/null | tr -d ' ' | tr '\n' ',' || true)
echo "  icon files : ${icon_files:--}"
echo "  icon PNGs  : $(cd "$app_dir" && ls AppIcon*.png 2>/dev/null | tr '\n' ' ' || true)"

# 网络唤醒要的本地网络权限说明。
#
# 这一条同样是**静默**失败：Info.plist 里没有 `NSLocalNetworkUsageDescription`，
# iOS 14 起那个「允许访问本地网络」的弹窗根本弹不出来，`sendto` 直接失败。
# 而排查时会发现代码、entitlements、魔术包本身全都是对的 —— 症状只是「唤醒没反应」。
local_network="$(/usr/libexec/PlistBuddy -c 'Print :NSLocalNetworkUsageDescription' "$app_dir/Info.plist" 2>/dev/null || true)"
if [ -z "$local_network" ]; then
  echo "::error::NSLocalNetworkUsageDescription is missing from Info.plist. Without it the local-network prompt never appears and every Wake-on-LAN send fails with no visible cause." >&2
  exit 1
fi
echo "  local net  : NSLocalNetworkUsageDescription present"
# 未签名包不该带上构建机的任何路径。`-I` 会跳过二进制文件，而路径恰恰藏在二进制里，
# 所以这里用 `-a` 把二进制当文本扫。
if grep -ral "$HOME" "$work" >/dev/null 2>&1; then
  echo "::warning::the ipa still references the build machine's home directory"
  grep -ral "$HOME" "$work" | sed 's/^/  /'
fi

# ── 充电控制 ────────────────────────────────────────────────────────────────
#
# 下面这几条守的全部是**静默失败**：包能装、界面能开、开关能点，
# 但充电一点都停不下来，而且哪里都不会报错。所以逐条在这里卡死。
daemon="$app_dir/ChargeLimiterDaemon"
if [ ! -f "$daemon" ]; then
  echo "::error::ChargeLimiterDaemon is missing from the app bundle. The charge control page would open and its switches would move, but nothing would ever stop charging."
  exit 1
fi
if [ ! -x "$daemon" ]; then
  echo "::error::ChargeLimiterDaemon is in the bundle but not executable. posix_spawn would fail, the daemon would never start, and the page would just sit there."
  exit 1
fi
echo "  daemon     : ChargeLimiterDaemon ($(wc -c < "$daemon" | tr -d ' ') bytes, executable)"

# 守护进程的 web root。它读的是 `NSBundle.mainBundle.bundlePath + "/www"` ——
# 对一个裸可执行文件来说 mainBundle 就是它所在的目录。所以 `www/` 必须与它同级，
# 且**目录名本身**是契约。被展平到包根目录的话，所有静态请求 404，且无任何报错。
if [ ! -f "$app_dir/www/index.html" ]; then
  echo "::error::www/index.html is missing from the app bundle. The daemon serves its web interface from bundlePath + \"/www\"; if the folder got flattened, every static request 404s and nothing says so."
  exit 1
fi
echo "  web root   : www/ ($(ls "$app_dir/www" | tr '\n' ' '))"

# entitlements。`ldid -e` 打出来的就是签名里那份 plist。
#
# 主 App 与守护进程**都要有**：App 侧靠 persona-mgmt / no-sandbox / no-container
# 才 spawn 得动一个 root 子进程；守护进程侧靠 powersource-write 才写得进 IOPMPS。
main_binary="$app_dir/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_dir/Info.plist")"
for target in "$main_binary" "$daemon"; do
  entitlements="$(ldid -e "$target" 2>/dev/null || true)"
  if [ -z "$entitlements" ]; then
    echo "::error::$(basename "$target") carries no entitlements at all. TrollStore preserves whatever the ipa carries, so this would install and run but never be able to control charging."
    exit 1
  fi
  for key in platform-application \
             com.apple.private.persona-mgmt \
             com.apple.private.security.no-sandbox \
             com.apple.private.security.no-container \
             com.apple.private.powersource-write; do
    if ! printf '%s' "$entitlements" | grep -q "$key"; then
      echo "::error::$(basename "$target") is missing the '$key' entitlement. Without it charging silently never stops — the UI looks fine the whole time."
      exit 1
    fi
  done
  echo "  entitlements: $(basename "$target") ok"
done

# 扩展（负一屏）也必须有 entitlements —— 否则它读不到共享指标文件、自己采样，
# 负一屏就会和主 App / Statusbar 显示不一样的数。同样是静默失败：界面照常显示，
# 只是对不上，不会有任何报错。所以这里卡死。
for appex in "$app_dir"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  ext_binary="$appex/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  ext_entitlements="$(ldid -e "$ext_binary" 2>/dev/null || true)"
  if [ -z "$ext_entitlements" ]; then
    echo "::error::$(basename "$appex") carries no entitlements. It would be sandboxed, could not read the shared CPU metrics file, and would fall back to sampling on its own — so the Today widget would silently disagree with the app." >&2
    exit 1
  fi
  for key in com.apple.private.security.no-sandbox com.apple.security.exception.files.absolute-path.read-write; do
    if ! printf '%s' "$ext_entitlements" | grep -q "$key"; then
      echo "::error::$(basename "$appex") is missing the '$key' entitlement; it would not be able to read the shared CPU metrics file." >&2
      exit 1
    fi
  done
  echo "  entitlements: $(basename "$appex") ok"
done

# 频段设置要的权限。**只有主 App 需要** —— 守护进程不碰蜂窝网络，所以它不在上面
# 那个循环的名单里。
#
# 同样是一类静默失败：没有这条权限时 CommCenter 拒绝建立连接，读和写都返回 nil，
# 不抛异常也不打日志。界面上表现为「频段设置」页显示「不可用」，而用户看到的只是
# 一句没有原因的话。所以这里在构建期就卡住。
if ! ldid -e "$main_binary" 2>/dev/null | grep -q "com.apple.CommCenter.fine-grained"; then
  echo "::error::the app is missing 'com.apple.CommCenter.fine-grained'. Without it CommCenter refuses the band read/write connection, and the failure is silent — the band page would just say 'Unavailable'." >&2
  exit 1
fi
echo "  entitlements: CommCenter ok"

# ── 维护工具（重启设备 / 注销）──────────────────────────────────────────────
#
# 守的还是同一类**静默失败**：工具在包里、进程也起得来，但**拿不到 root** ——
# 于是 `reboot(2)` 和 `kill(SpringBoard)` 双双返回 EPERM，界面不会有任何报错，
# 用户看到的就是「点了没反应」。所以下面逐条卡死。
tool="$app_dir/SysProbeRootTool"
if [ ! -f "$tool" ]; then
  echo "::error::SysProbeRootTool is missing from the app bundle. The maintenance buttons would still be drawn, but pressing them would do nothing at all." >&2
  exit 1
fi
if [ ! -x "$tool" ]; then
  echo "::error::SysProbeRootTool is in the bundle but not executable. posix_spawn would fail and both buttons would silently do nothing." >&2
  exit 1
fi
echo "  root tool  : SysProbeRootTool ($(wc -c < "$tool" | tr -d ' ') bytes, executable)"

tool_entitlements="$(ldid -e "$tool" 2>/dev/null || true)"
if [ -z "$tool_entitlements" ]; then
  echo "::error::SysProbeRootTool carries no entitlements at all. TrollStore preserves whatever the ipa carries, so it would install and run but never be able to reboot or signal SpringBoard." >&2
  exit 1
fi
for key in platform-application \
           com.apple.private.security.no-container \
           com.apple.private.security.no-sandbox; do
  if ! printf '%s' "$tool_entitlements" | grep -q "$key"; then
    echo "::error::SysProbeRootTool is missing the '$key' entitlement. Without it the tool still starts, but rebooting and respringing both fail silently — neither the app nor the tool reports anything." >&2
    exit 1
  fi
done
echo "  entitlements: SysProbeRootTool ok"

# 子命令真的编进去了吗。
#
# 这一条挡的是「改了 Tools/RootTool.c 但构建缓存没重编」—— 那种情况下包里的工具
# 还是旧的，子命令会走到 `unknown command` 分支并返回非 0，
# 而界面只会说「失败」，看不出是版本不对。
#
# `thermal-disable` 尤其要卡死：它写的是**系统文件**，静默失败的表现是
# 「开关拨了、重启了、什么都没变」，而用户会以为是这个方法没用。
# `clean-*` 同理：存储清理页的工具状态由自检兜底，但子命令缺失时界面只会说
# 「没有返回结果」，与工具版本不对分不清。
for subcommand in restart-commcenter thermal-status thermal-disable thermal-enable clean-scan clean-run; do
  if ! grep -a -q "$subcommand" "$tool"; then
    echo "::error::SysProbeRootTool does not contain the '$subcommand' subcommand. The feature would be there in the UI but would do nothing." >&2
    exit 1
  fi
done
echo "  root tool  : restart-commcenter, thermal-{status,disable,enable}, clean-{scan,run} present"

# 「系统更新包」那一类（2026-10-11 加）真的编进去了吗。
#
# 断言的是**路径字面量**而不是 `update` 这个词：后者在二进制里到处都是
# （符号名、别的路径），挡不住旧版本。这一类的收益最大（几百 MB 到数 GB），
# 而它失效的表现只是「扫描显示 0 B」—— 与「这台设备没下载过更新」一模一样，
# 界面上分不出来。
#
# 这里用 `python3` 做子串查找而不是 `grep -a`：后者把二进制当文本、按 `\n` 分行，
# 字符串池里的字面量未必恰好落在两个换行之间，会**漏报**（工作流里同一件事的
# 注释记着上一轮就因此误报过）。断言漏报等于没有断言，而它误报会让构建红。
if ! python3 -c 'import sys; sys.exit(0 if sys.argv[2].encode() in open(sys.argv[1], "rb").read() else 1)' \
        "$tool" "com_apple_MobileAsset_SoftwareUpdate"; then
  echo "::error::SysProbeRootTool does not carry the software-update path. The update category would always measure 0 B, which is indistinguishable from 'this device has never downloaded an update'." >&2
  exit 1
fi
echo "  root tool  : software-update path present"

rm -rf "$work"

echo
echo "Done:"
ls -lh "$IPA"
