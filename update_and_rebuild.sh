#!/bin/bash
# ==============================================================================
# Antigravity Tools - 上游更新与 Cursor 适配一键重构脚本
# 功能：拉取官方最新代码 -> 自主选择稳定版/开发版 -> 自动合并 Cursor 适配补丁 -> 一键编译安装
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

show_help() {
    echo -e "${CYAN}${BOLD}用法:${NC} ./update_and_rebuild.sh [选项 | 目标分支/Tag]"
    echo ""
    echo "选项:"
    echo "  (无参数)                启动交互式菜单，自主选择【稳定版】、【开发版】或【自定义】"
    echo "  1, stable, --stable, -s 直接更新到最新稳定版 (正式版 Release Tag)"
    echo "  2, dev, beta, --dev, -b 直接更新到最新开发版 (upstream/beta 预览分支)"
    echo "  <Tag 或 Branch>         直接更新到指定的 Tag 或分支 (例如 v4.8.4 或 upstream/main)"
    echo "  -h, --help              显示此帮助信息"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

# 自动检测本地代理并启用（支持 Clash Verge: 7897, Clash: 7890 等）
if [ -z "${http_proxy:-}" ] && [ -z "${https_proxy:-}" ] && [ -z "${all_proxy:-}" ]; then
    for port in 7897 7890 10808 10809 1080; do
        if nc -z 127.0.0.1 $port 2>/dev/null; then
            export http_proxy="http://127.0.0.1:$port"
            export https_proxy="http://127.0.0.1:$port"
            export all_proxy="socks5://127.0.0.1:$port"
            log_info "已自动检测并启用本地代理端口: $port"
            break
        fi
    done
fi

PATCH_FILE="$REPO_DIR/patches/cursor-cleaner.patch"
BETA_PATCH_FILE="$REPO_DIR/patches/cursor-cleaner-beta.patch"

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

# 2. 从官方仓库拉取最新提交、全部分支与标签
UPSTREAM_REMOTE="origin"
if git remote | grep -q "^upstream$"; then
    UPSTREAM_REMOTE="upstream"
fi
log_info "正在连接 GitHub 拉取官方最新版本与分支 (从 ${UPSTREAM_REMOTE})..."
git fetch "$UPSTREAM_REMOTE" '+refs/heads/*:refs/remotes/'"$UPSTREAM_REMOTE"'/*' --tags --prune

# 3. 解析各版本通道信息（稳定版 vs 开发版）
LATEST_STABLE_TAG=$(git tag -l "v*" --sort=-v:refname | grep -E '^v[0-9]+(\.[0-9]+)+$' | head -n 1 || true)
CURRENT_VER=$(grep '"version":' package.json | head -n 1 | awk -F: '{ print $2 }' | sed 's/[", ]//g')
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

if [ -n "$LATEST_STABLE_TAG" ]; then
    STABLE_TARGET="$LATEST_STABLE_TAG"
    STABLE_DISPLAY="${LATEST_STABLE_TAG}"
else
    STABLE_TARGET="${UPSTREAM_REMOTE}/main"
    STABLE_DISPLAY="${UPSTREAM_REMOTE}/main"
fi

if git rev-parse --verify "${UPSTREAM_REMOTE}/beta" >/dev/null 2>&1; then
    DEV_TARGET="${UPSTREAM_REMOTE}/beta"
    LATEST_BETA_TAG=$(git describe --tags --abbrev=0 "${DEV_TARGET}" 2>/dev/null || true)
    DEV_VER=$(git show "${DEV_TARGET}:package.json" 2>/dev/null | grep '"version":' | head -n 1 | awk -F: '{ print $2 }' | sed 's/[", ]//g' || true)
    DEV_COMMIT=$(git rev-parse --short "${DEV_TARGET}" 2>/dev/null || true)
    DEV_DISPLAY="${DEV_TARGET} (版本: ${LATEST_BETA_TAG:-v${DEV_VER}}, 提交: ${DEV_COMMIT})"
else
    LATEST_BETA_TAG=$(git tag -l "v*" --sort=-v:refname | grep -iE 'beta|alpha|rc' | head -n 1 || true)
    DEV_TARGET="${LATEST_BETA_TAG:-${UPSTREAM_REMOTE}/main}"
    DEV_DISPLAY="${DEV_TARGET}"
fi

log_info "当前本地版本: ${BOLD}v${CURRENT_VER}${NC} (分支: ${CURRENT_BRANCH})"

# 选择版本通道：支持命令行参数或交互式菜单
ARG_CHANNEL="${1:-}"
CHANNEL_TYPE="stable"

case "$ARG_CHANNEL" in
    1|stable|release|--stable|-s)
        TARGET="$STABLE_TARGET"
        CHANNEL_NAME="稳定版 (Stable / 正式版)"
        CHANNEL_TYPE="stable"
        ;;
    2|dev|beta|preview|--dev|--beta|-b)
        TARGET="$DEV_TARGET"
        CHANNEL_NAME="开发版 (Beta / 预览版)"
        CHANNEL_TYPE="beta"
        ;;
    "")
        echo ""
        echo -e "${CYAN}${BOLD}请选择要更新并构建的版本通道:${NC}"
        echo -e "  ${GREEN}${BOLD}1)${NC} 稳定版 (Stable / 正式版)   -> ${BOLD}${STABLE_DISPLAY}${NC}"
        echo -e "  ${YELLOW}${BOLD}2)${NC} 开发版 (Beta / 预览版)     -> ${BOLD}${DEV_DISPLAY}${NC}"
        echo -e "  ${BLUE}${BOLD}3)${NC} 自定义 (Custom Target)     -> 手动输入指定分支或 Tag"
        echo ""
        read -r -p "请输入选项 [1-3, 默认 1 (稳定版)]: " USER_CHOICE
        case "${USER_CHOICE:-1}" in
            1|stable|s|S)
                TARGET="$STABLE_TARGET"
                CHANNEL_NAME="稳定版 (Stable / 正式版)"
                CHANNEL_TYPE="stable"
                ;;
            2|dev|beta|b|B|d|D)
                TARGET="$DEV_TARGET"
                CHANNEL_NAME="开发版 (Beta / 预览版)"
                CHANNEL_TYPE="beta"
                ;;
            3|custom|c|C)
                read -r -p "请输入目标 Tag 或分支名 (例如 ${STABLE_TARGET} 或 ${DEV_TARGET}): " CUSTOM_TARGET
                if [ -z "${CUSTOM_TARGET:-}" ]; then
                    log_error "未输入有效的目标版本，操作已取消。"
                    exit 1
                fi
                TARGET="$CUSTOM_TARGET"
                CHANNEL_NAME="自定义 ($TARGET)"
                if [[ "$TARGET" == *"beta"* || "$TARGET" == *"dev"* ]]; then
                    CHANNEL_TYPE="beta"
                fi
                ;;
            *)
                log_warn "未识别的选项 '${USER_CHOICE}'，默认使用稳定版。"
                TARGET="$STABLE_TARGET"
                CHANNEL_NAME="稳定版 (Stable / 正式版)"
                CHANNEL_TYPE="stable"
                ;;
        esac
        echo ""
        ;;
    *)
        TARGET="$ARG_CHANNEL"
        CHANNEL_NAME="自定义 ($TARGET)"
        if [[ "$TARGET" == *"beta"* || "$TARGET" == *"dev"* ]]; then
            CHANNEL_TYPE="beta"
        fi
        ;;
esac

if ! git rev-parse --verify "$TARGET" >/dev/null 2>&1; then
    log_error "目标版本或分支 '$TARGET' 不存在，请检查名称是否正确！"
    exit 1
fi

log_info "已选择通道: ${BOLD}${CHANNEL_NAME}${NC}"
log_info "目标更新版本: ${BOLD}${TARGET}${NC}"

# 4. 安全备份补丁与构建脚本（防止 git checkout 切换分支时被删除）
TEMP_DIR=$(mktemp -d /tmp/antigravity-update-XXXXXX)
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TEMP_DIR/patches"
if [ -d "$REPO_DIR/patches" ]; then
    cp -R "$REPO_DIR/patches/." "$TEMP_DIR/patches/" 2>/dev/null || true
fi
for script_file in build_and_install.sh update_and_rebuild.sh pnpm-workspace.yaml; do
    if [ -f "$REPO_DIR/$script_file" ]; then
        cp "$REPO_DIR/$script_file" "$TEMP_DIR/$script_file"
    fi
done

# 5. 准备更新分支
SAFE_TARGET_NAME="${TARGET//\//-}"
NEW_BRANCH="update-${SAFE_TARGET_NAME}-cursor-cleaner"
log_info "准备创建干净的更新分支: ${NEW_BRANCH}..."

# 清理可能存在的历史合并残留（如 .rej / .orig 文件及未决索引）
find "$REPO_DIR" -name "*.rej" -o -name "*.orig" 2>/dev/null | xargs rm -f 2>/dev/null || true
git reset --merge 2>/dev/null || true

# 暂存可能存在的已跟踪修改
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
    log_warn "检测到当前工作区有未提交的代码，正在暂存..."
    git stash push -m "Auto-stash before update to $TARGET"
fi

# 切换到干净的目标版本并清理补丁将新建的残留文件（防止 git apply 报 already exists）
git checkout -f -B "$NEW_BRANCH" "$TARGET"
git reset --hard "$TARGET"
rm -f "$REPO_DIR/pnpm-workspace.yaml" "$REPO_DIR/src-tauri/src/proxy/common/cursor_cleaner.rs"

# 恢复补丁与脚本文件到工作区（注意：pnpm-workspace.yaml 在补丁应用后再按需恢复，避免阻塞 git apply）
mkdir -p "$REPO_DIR/patches"
if [ -d "$TEMP_DIR/patches" ]; then
    cp -R "$TEMP_DIR/patches/." "$REPO_DIR/patches/" 2>/dev/null || true
fi
for script_file in build_and_install.sh update_and_rebuild.sh; do
    if [ -f "$TEMP_DIR/$script_file" ]; then
        cp "$TEMP_DIR/$script_file" "$REPO_DIR/$script_file"
        chmod +x "$REPO_DIR/$script_file"
    fi
done

log_info "已切换到目标版本 $TARGET，正在自动注入 Cursor 纯净流与点号清洗补丁..."

# 6. 应用 Cursor 纯净流补丁 (智能优选最匹配的补丁文件)
ACTIVE_PATCH=""
if [ "$CHANNEL_TYPE" = "beta" ]; then
    CANDIDATES=("$BETA_PATCH_FILE" "$PATCH_FILE")
else
    CANDIDATES=("$PATCH_FILE" "$BETA_PATCH_FILE")
fi

for candidate in "${CANDIDATES[@]}"; do
    if [ -f "$candidate" ] && [ -s "$candidate" ]; then
        if git apply --check "$candidate" 2>/dev/null; then
            ACTIVE_PATCH="$candidate"
            break
        fi
    fi
done

if [ -z "$ACTIVE_PATCH" ]; then
    if [ "$CHANNEL_TYPE" = "beta" ] && [ -f "$BETA_PATCH_FILE" ]; then
        ACTIVE_PATCH="$BETA_PATCH_FILE"
    else
        ACTIVE_PATCH="$PATCH_FILE"
    fi
fi

if [ ! -f "$ACTIVE_PATCH" ] || [ ! -s "$ACTIVE_PATCH" ]; then
    log_error "未找到有效的补丁文件: $ACTIVE_PATCH"
    exit 1
fi

log_info "使用适配补丁: $(basename "$ACTIVE_PATCH")"

if git apply --check "$ACTIVE_PATCH" 2>/dev/null; then
    git apply "$ACTIVE_PATCH"
    log_success "Cursor 适配补丁直接应用成功！"
elif git apply --3way "$ACTIVE_PATCH" 2>/dev/null && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    log_success "Cursor 适配补丁通过三向合并 (3-Way Merge) 自动合入成功！"
else
    # 若三向合并留下冲突标记，先重置再尝试备用补丁或 patch 容错
    git checkout -- . 2>/dev/null || true
    git clean -fd -- ':!patches' ':!build_and_install.sh' ':!update_and_rebuild.sh' 2>/dev/null || true

    FALLBACK_PATCH=""
    if [ "$ACTIVE_PATCH" = "$PATCH_FILE" ] && [ -f "$BETA_PATCH_FILE" ]; then
        FALLBACK_PATCH="$BETA_PATCH_FILE"
    elif [ "$ACTIVE_PATCH" = "$BETA_PATCH_FILE" ] && [ -f "$PATCH_FILE" ]; then
        FALLBACK_PATCH="$PATCH_FILE"
    fi

    if [ -n "$FALLBACK_PATCH" ] && git apply --3way "$FALLBACK_PATCH" 2>/dev/null && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
        log_success "已通过备用补丁 ($(basename "$FALLBACK_PATCH")) 三向合并成功！"
    else
        git checkout -- . 2>/dev/null || true
        log_warn "标准 patch 匹配发生偏移，尝试容错合并..."
        if patch -p1 -N < "$ACTIVE_PATCH"; then
            log_success "Cursor 适配补丁通过模糊匹配应用成功！"
        else
            log_error "补丁合并遇到冲突！可能官方在新版本大幅重构了相关文件。"
            log_error "请检查冲突文件或更新 patches/ 目录下的补丁。"
            exit 1
        fi
    fi
fi

# 补丁应用完成后，若工作区仍无 pnpm-workspace.yaml 则从备份恢复
if [ ! -f "$REPO_DIR/pnpm-workspace.yaml" ] && [ -f "$TEMP_DIR/pnpm-workspace.yaml" ]; then
    cp "$TEMP_DIR/pnpm-workspace.yaml" "$REPO_DIR/pnpm-workspace.yaml"
fi

# 7. 一键编译与安装
log_info "代码更新与适配就绪，开始执行编译打包与安装..."
"$REPO_DIR/build_and_install.sh"
