#!/bin/bash
# ==============================================================================
# Antigravity Tools - 上游更新与 Cursor 适配一键重构脚本
# 功能：拉取官方最新代码 -> 自动合并 Cursor 适配补丁 -> 一键编译并安装到 Mac
# ==============================================================================

set -eo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}${BOLD}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}${BOLD}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}${BOLD}[ERROR]${NC} $1"
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

PATCH_FILE="$REPO_DIR/patches/cursor-cleaner.patch"

echo -e "${CYAN}${BOLD}"
echo "=========================================================="
echo "    🔄 Antigravity Tools 上游更新与 Cursor 适配脚本"
echo "=========================================================="
echo -e "${NC}"

# 1. 检查补丁文件是否存在，若不存在则尝试从当前分支与基准版本的差异生成
if [ ! -f "$PATCH_FILE" ] || [ ! -s "$PATCH_FILE" ]; then
    log_warn "未找到预存补丁，尝试从当前分支生成 patches/cursor-cleaner.patch..."
    mkdir -p "$REPO_DIR/patches"
    PREV_TAG=$(git tag -l "v*" --sort=-v:refname | grep -E '^v[0-9]+(\.[0-9]+)+$' | head -n 1 || true)
    if [ -n "$PREV_TAG" ]; then
        git diff "$PREV_TAG" HEAD -- ':!patches' > "$PATCH_FILE" 2>/dev/null || true
    fi
    if [ ! -s "$PATCH_FILE" ]; then
        git add -N src-tauri/src/proxy/common/cursor_cleaner.rs 2>/dev/null || true
        git diff HEAD -- ':!patches' > "$PATCH_FILE" 2>/dev/null || true
    fi
    if [ -s "$PATCH_FILE" ]; then
        log_success "已成功导出当前 Cursor 适配补丁: $PATCH_FILE"
    fi
fi

# 2. 从官方仓库拉取最新提交与标签
UPSTREAM_REMOTE="origin"
if git remote | grep -q "upstream"; then
    UPSTREAM_REMOTE="upstream"
fi
log_info "正在连接 GitHub 拉取官方最新版本 (从 ${UPSTREAM_REMOTE})..."
git fetch "$UPSTREAM_REMOTE" --tags --prune

# 3. 计算最新正式版本（排除 beta, alpha, rc, test 等预发布标签）
LATEST_TAG=$(git tag -l "v*" --sort=-v:refname | grep -E '^v[0-9]+(\.[0-9]+)+$' | head -n 1 || true)
CURRENT_VER=$(grep '"version":' package.json | head -n 1 | awk -F: '{ print $2 }' | sed 's/[", ]//g')
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
    if [ -n "$LATEST_TAG" ]; then
        TARGET="$LATEST_TAG"
    else
        TARGET="${UPSTREAM_REMOTE}/main"
    fi
fi

log_info "当前本地版本: ${BOLD}v${CURRENT_VER}${NC}"
log_info "目标更新版本: ${BOLD}${TARGET}${NC} (正式版)"

# 4. 安全备份补丁与构建脚本（防止 git checkout 切换分支时被删除）
TEMP_DIR=$(mktemp -d /tmp/antigravity-update-XXXXXX)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [ -f "$PATCH_FILE" ]; then
    cp "$PATCH_FILE" "$TEMP_DIR/cursor-cleaner.patch"
fi
if [ -f "$REPO_DIR/build_and_install.sh" ]; then
    cp "$REPO_DIR/build_and_install.sh" "$TEMP_DIR/build_and_install.sh"
fi
if [ -f "$REPO_DIR/update_and_rebuild.sh" ]; then
    cp "$REPO_DIR/update_and_rebuild.sh" "$TEMP_DIR/update_and_rebuild.sh"
fi

# 5. 准备更新分支
NEW_BRANCH="update-${TARGET//\//-}-cursor-cleaner"
log_info "准备创建干净的更新分支: ${NEW_BRANCH}..."

# 暂存可能存在的未跟踪修改
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    log_warn "检测到当前工作区有未提交的代码，正在暂存..."
    git stash push -m "Auto-stash before update to $TARGET"
fi

# 切换到干净的目标版本
git checkout -B "$NEW_BRANCH" "$TARGET"

# 恢复补丁与脚本文件到工作区
mkdir -p "$REPO_DIR/patches"
if [ -f "$TEMP_DIR/cursor-cleaner.patch" ]; then
    cp "$TEMP_DIR/cursor-cleaner.patch" "$PATCH_FILE"
fi
if [ -f "$TEMP_DIR/build_and_install.sh" ]; then
    cp "$TEMP_DIR/build_and_install.sh" "$REPO_DIR/build_and_install.sh"
    chmod +x "$REPO_DIR/build_and_install.sh"
fi
if [ -f "$TEMP_DIR/update_and_rebuild.sh" ]; then
    cp "$TEMP_DIR/update_and_rebuild.sh" "$REPO_DIR/update_and_rebuild.sh"
    chmod +x "$REPO_DIR/update_and_rebuild.sh"
fi

log_info "已切换到目标版本 $TARGET，正在自动注入 Cursor 纯净流与点号清洗补丁..."

# 6. 应用 Cursor 纯净流补丁 (优先标准应用，其次三向合并，最后容错 patch)
if [ ! -f "$PATCH_FILE" ] || [ ! -s "$PATCH_FILE" ]; then
    log_error "未找到有效的补丁文件: $PATCH_FILE"
    exit 1
fi

APPLIED=0
if git apply --check "$PATCH_FILE" 2>/dev/null; then
    git apply "$PATCH_FILE"
    log_success "Cursor 适配补丁应用成功！"
    APPLIED=1
elif git apply --3way "$PATCH_FILE" 2>/dev/null; then
    log_success "Cursor 适配补丁通过三向合并 (3-Way Merge) 自动合入成功！"
    APPLIED=1
else
    log_warn "标准 patch 匹配发生偏移，尝试容错合并..."
    if patch -p1 -N < "$PATCH_FILE"; then
        log_success "Cursor 适配补丁通过模糊匹配应用成功！"
        APPLIED=1
    else
        log_error "补丁合并遇到冲突！可能官方在新版本重构了相关文件。"
        log_error "请检查冲突文件或手动微调。"
        exit 1
    fi
fi

# 7. 一键编译与安装
log_info "代码更新与适配就绪，开始执行编译打包与安装..."
"$REPO_DIR/build_and_install.sh"
