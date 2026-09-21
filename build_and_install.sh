#!/bin/bash
# ==============================================================================
# Antigravity Tools - macOS 一键编译、打包与自动安装脚本
# 支持 Cursor 纯净流与点号清洗补丁
# ==============================================================================

set -eo pipefail

# 颜色与输出格式
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

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

# 脚本所在目录定位为项目根目录
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

echo -e "${CYAN}${BOLD}"
echo "=========================================================="
echo "    🚀 Antigravity Tools 一键编译打包与安装脚本"
echo "=========================================================="
echo -e "${NC}"

# 1. 自动注入环境变量 (Node / pnpm / Rust / Cargo)
export PATH="$HOME/.cargo/bin:$HOME/.local/share/pnpm:/usr/local/bin:/opt/homebrew/bin:$PATH"

if [ -d "$HOME/.nvm" ]; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" --no-use 2>/dev/null || true
    # 将最新安装的 Node 目录加入 PATH
    LATEST_NVM_NODE=$(ls "$NVM_DIR/versions/node" 2>/dev/null | tail -n 1 || true)
    if [ -n "$LATEST_NVM_NODE" ]; then
        export PATH="$NVM_DIR/versions/node/$LATEST_NVM_NODE/bin:$PATH"
    fi
fi

# 2. 检查必须的编译工具链
log_info "检查构建环境..."

if ! command -v node &>/dev/null; then
    log_error "未找到 Node.js，请先安装 Node.js 或配置 NVM。"
    exit 1
fi

if ! command -v cargo &>/dev/null; then
    log_error "未找到 Rust/Cargo，请检查 ~/.cargo/bin 是否已安装。"
    exit 1
fi

PM="npm"
if command -v pnpm &>/dev/null; then
    PM="pnpm"
fi

NODE_VER=$(node -v)
CARGO_VER=$(cargo --version | awk '{print $1" "$2}')
log_success "构建环境正常: Node ${NODE_VER}, ${CARGO_VER}, 包管理器: ${PM}"

# 读取当前版本号
APP_VERSION=$(grep '"version":' package.json | head -n 1 | awk -F: '{ print $2 }' | sed 's/[", ]//g')
log_info "当前项目版本: ${BOLD}v${APP_VERSION}${NC}"

# 3. 依赖检查
if [ ! -d "node_modules" ]; then
    log_warn "未检测到 node_modules，正在安装前端依赖..."
    $PM install
fi

# 4. 编译前端生产静态资源
log_info "步骤 1/4: 编译前端页面 (Vite build)..."
$PM run build

# 5. 编译并打包 Tauri macOS 应用
log_info "步骤 2/4: 编译 Rust 后端并打包 macOS App (Release 模式)..."
$PM exec tauri build --bundles app --ignore-version-mismatches --no-sign

APP_BUNDLE_PATH="$REPO_DIR/src-tauri/target/release/bundle/macos/Antigravity Tools.app"

if [ ! -d "$APP_BUNDLE_PATH" ]; then
    log_error "打包失败，未找到目标文件: $APP_BUNDLE_PATH"
    exit 1
fi

log_success "打包成功: $APP_BUNDLE_PATH"

# 6. 覆盖安装至 /Applications
log_info "步骤 3/4: 安装至 /Applications..."

# 优雅退出正在运行的旧版本
if pgrep -f "Antigravity Tools" >/dev/null 2>&1; then
    log_warn "检测到旧版 Antigravity Tools 正在运行，正在退出..."
    pkill -f "Antigravity Tools" 2>/dev/null || true
    sleep 1
    # 强制清理未退出的残留进程
    pkill -9 -f "Antigravity Tools" 2>/dev/null || true
fi

TARGET_APP="/Applications/Antigravity Tools.app"

# 采用 ditto 完整覆盖替换（保留 macOS 资源分支与权限）
ditto "$APP_BUNDLE_PATH" "$TARGET_APP"

# 7. 移除 macOS Gatekeeper 隔离属性（防止提示“已损坏”）
log_info "步骤 4/4: 清除安全隔离属性 (移除 Gatekeeper Quarantine)..."
xattr -cr "$TARGET_APP" 2>/dev/null || true

# 8. 启动应用
log_info "正在启动新版本 Antigravity Tools..."
open "$TARGET_APP"

echo -e "\n${GREEN}${BOLD}=========================================================="
echo "    🎉 Antigravity Tools v${APP_VERSION} 编译并安装成功！"
echo "    ✨ Cursor 纯净流与点号清洗补丁已成功内置！"
echo "==========================================================${NC}\n"
