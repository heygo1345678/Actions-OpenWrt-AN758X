#!/usr/bin/env bash
# =============================================================
# prepare-rust.sh —— 用 runner 的 rustup 替代 rustc 源码自举
#
#   参照 VIKINGYFY/OpenWRT-CI。
#   省掉 rustc 从源码 bootstrap 的 30~60 分钟。
#
#   关键点：target triple 必须【向 feed 要】，不能自己拼。
#     feeds/packages/lang/rust/rust-values.mk 里的 RUSTC_TARGET_ARCH
#     就是 OpenWrt 用的映射，用它才能保证 CI 装的 target 与
#     OpenWrt 期望的一致。
#
#   ★ 全部软失败：rustup 缺失 / feed 结构不同 / 目标装不上，
#     都只 warning 并退回源码自举，不阻断构建。
#
#   用法: bash prepare-rust.sh <openwrt_dir>
# =============================================================

set -uo pipefail

OW="${1:-$PWD}"
cd "$OW" || { echo "::error::无法进入 $OW"; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPORT_DIR="${GITHUB_WORKSPACE:-$OW}/build-reports"
mkdir -p "$REPORT_DIR"
REPORT="$REPORT_DIR/rust-toolchain.txt"

log() { echo "$1" | tee -a "$REPORT"; }
warn() { echo "::warning::$1"; echo "跳过: $1" >> "$REPORT"; }

: > "$REPORT"
log "===== Rust 预编译工具链 ====="

# ---------------------------------------------------------------
# 0. 前置检查
# ---------------------------------------------------------------
RUST_FEED="$PWD/feeds/packages/lang/rust"
if [ ! -f "$RUST_FEED/Makefile" ]; then
  warn "Rust: 树里没有 feeds/packages/lang/rust，跳过"
  exit 0
fi

if [ ! -f "$RUST_FEED/rust-values.mk" ]; then
  warn "Rust: 缺 rust-values.mk（拿不到 RUSTC_TARGET_ARCH），退回源码自举"
  exit 0
fi

# ---------------------------------------------------------------
# 1. 向 feed 要 target triple
# ---------------------------------------------------------------
RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" ci-rust-target <<'MAKE' 2>/dev/null
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)
if [ -z "$RUST_TARGET" ]; then
  warn "Rust: RUSTC_TARGET_ARCH 为空，退回源码自举"
  exit 0
fi
log "Rust target: $RUST_TARGET"

# ---------------------------------------------------------------
# 2. 找 rustup（runner 预装，但 PATH 未必包含 ~/.cargo/bin）
# ---------------------------------------------------------------
RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ]; then
  for c in "$HOME/.cargo/bin/rustup" /usr/bin/rustup /usr/local/bin/rustup; do
    [ -x "$c" ] && { RUSTUP_BIN=$c; break; }
  done
fi
if [ -z "$RUSTUP_BIN" ]; then
  warn "Rust: runner 没有 rustup（需 apt 安装 rustup），退回源码自举"
  exit 0
fi
PATH="$(dirname "$RUSTUP_BIN"):$PATH"; export PATH

RUST_TOOLCHAIN=$(rustup show active-toolchain 2>/dev/null | awk '{print $1}')
[ -n "$RUST_TOOLCHAIN" ] || RUST_TOOLCHAIN=stable
log "Rust toolchain: $RUST_TOOLCHAIN"

# ---------------------------------------------------------------
# 3. 装对应的 target
# ---------------------------------------------------------------
if ! rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET" 2>&1 | tee -a "$REPORT"; then
  warn "Rust: rustup target add $RUST_TARGET 失败，退回源码自举"
  exit 0
fi

RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot 2>/dev/null)
if [ -z "$RUST_ROOT" ] || [ ! -d "$RUST_ROOT" ]; then
  warn "Rust: rustc --print sysroot 失败，退回源码自举"
  exit 0
fi

# ---------------------------------------------------------------
# 4. 校验：target 的 std 与三个工具必须真的在
#    否则后面编译会因为缺 std 而失败，不如现在就退回
# ---------------------------------------------------------------
if [ ! -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib" ]; then
  warn "Rust: 缺 $RUST_TARGET 的 std（$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib），退回源码自举"
  exit 0
fi
for t in cargo rustc rustdoc; do
  if [ ! -x "$RUST_ROOT/bin/$t" ]; then
    warn "Rust: 缺 $RUST_ROOT/bin/$t，退回源码自举"
    exit 0
  fi
done

# ---------------------------------------------------------------
# 5. 注入 ci-prebuilt.mk，替换源码自举
#
#    必须在 OpenWrt 展开 HostBuild 规则【之前】插入，
#    所以 sed 插到 $(eval $(call HostBuild)) 之前。
# ---------------------------------------------------------------
{
  printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
  cat "$SCRIPT_DIR/rust-prebuilt.mk"
} > "$RUST_FEED/ci-prebuilt.mk"

RUST_MAKEFILE="$RUST_FEED/Makefile"
# perl 需要从环境里拿这两个字面量（避免 shell 转义把 $ 吃掉）
export CI_MARKER='include ./ci-prebuilt.mk'
export CI_HOSTBUILD='$(eval $(call HostBuild))'

# ⚠ 必须用 perl，不能用 sed -i：
#   GNU sed 处理含 `$` 的模式（$(eval $(call HostBuild))）时，
#   -i 原地模式下 i\ 命令会静默失效 —— 实测插入不进去且不报错。
#   perl 的 \Q...\E 把整串当字面量，可靠得多。
MARKER='include ./ci-prebuilt.mk'
HOSTBUILD='$(eval $(call HostBuild))'

perl -i -pe '
  BEGIN { $m = quotemeta($ENV{"CI_MARKER"}); $h = quotemeta($ENV{"CI_HOSTBUILD"}); }
  if ($_ =~ /^$m$/) { $_ = ""; }                 # 先删掉旧的（幂等）
  elsif ($_ =~ /^$h$/) { $_ = "$ENV{CI_MARKER}\n" . $_; }   # 再插到 HostBuild 之前
' "$RUST_MAKEFILE"

if ! grep -Fxq "$MARKER" "$RUST_MAKEFILE"; then
  warn "Rust: 注入 ci-prebuilt.mk 失败，退回源码自举"
  exit 0
fi
log "注入: $MARKER（在 $(eval \$(call HostBuild)) 之前）"

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT"
log "✅ 使用 runner 的 Rust（$RUST_TOOLCHAIN），跳过源码自举（省 30~60 分钟）"
sha256sum "$RUST_MAKEFILE" >> "$REPORT"
exit 0
