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
# 链接器会把每个目标文件的绝对路径记进符号表（N_OSO），-file-prefix-map 覆盖不到，
# 剥掉调试与本地符号即可去掉。dSYM 仍留在 DerivedData 里备用。
xcrun strip -S -x "$BUILD_DIR/Payload/$SCHEME.app/$SCHEME"
# 扩展是 PlugIns 里的独立 bundle，有自己的可执行文件与调试映射，要单独处理。
while IFS= read -r -d '' appex; do
  rm -rf "$appex/_CodeSignature"
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist")"
  xcrun strip -S -x "$appex/$executable"
done < <(find "$BUILD_DIR/Payload/$SCHEME.app" -name '*.appex' -type d -print0)
(cd "$BUILD_DIR" && zip -qry "export/$SCHEME-unsigned.ipa" Payload)
rm -rf "$BUILD_DIR/Payload"

IPA="$EXPORT_DIR/$SCHEME-unsigned.ipa"

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
# 未签名包不该带上构建机的任何路径。`-I` 会跳过二进制文件，而路径恰恰藏在二进制里，
# 所以这里用 `-a` 把二进制当文本扫。
if grep -ral "$HOME" "$work" >/dev/null 2>&1; then
  echo "::warning::the ipa still references the build machine's home directory"
  grep -ral "$HOME" "$work" | sed 's/^/  /'
fi
rm -rf "$work"

echo
echo "Done:"
ls -lh "$IPA"
