#!/bin/bash
# ==============================================================================
# Cursor Extension Fast Tokenizer Patch Script
# 消除 Cursor 在接收大尺寸/多张 Base64 图片时因 BPE 分词阻塞主线程导致的：
# 1. 90秒 Stall Detector 超时
# 2. 界面显示 "Reconnecting..."
# 3. 触发无限自动重试重新生图死循环
# ==============================================================================

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_FILES=(
  "/Applications/Cursor.app/Contents/Resources/app/extensions/cursor2plus/dist/extension.js"
  "$HOME/.cursor/extensions/cometix-space.cursor2plus-0.0.15/dist/extension.js"
)

PATCH_SCRIPT=$(cat << 'EOF'
const fs = require("fs");
const file = process.argv.slice(1).find(arg => arg && !arg.endsWith("node") && arg !== "-e" && !arg.includes("eval"));

if (!fs.existsSync(file)) {
  console.log(`[SKIP] 文件不存在: ${file}`);
  process.exit(0);
}

let content = fs.readFileSync(file, "utf8");

const oldCode = "var _Qe=require(\"./o200k_base.js\");function mzt(t){return t?(0,_Qe.encode)(t,{allowedSpecial:\"all\"}).length:0}";
const newCode = "var _Qe=require(\"./o200k_base.js\");function mzt(t){if(!t)return 0;if(typeof t!==\"string\")return 0;let s=t,imgTokens=0;if(s.includes(\"data:image/\")){s=s.replace(/data:image\\/[a-zA-Z0-9.+_-]+;base64,[A-Za-z0-9+/=\\s]+/g,()=>{imgTokens+=1000;return\" \"})}if(s.length>100000)return imgTokens+Math.ceil(s.length/3.5);return imgTokens+(s?(0,_Qe.encode)(s,{allowedSpecial:\"all\"}).length:0)}";

if (!content.includes(oldCode)) {
  if (content.includes("data:image/") && content.includes("function mzt(t)")) {
    console.log(`[OK] 已打过快速分词补丁: ${file}`);
  } else {
    console.log(`[WARN] 未找到目标分词函数签名，可能 Cursor 版本结构变更: ${file}`);
  }
} else {
  // 备份原文件
  fs.writeFileSync(`${file}.bak`, content, "utf8");
  // 写入补丁代码
  content = content.replace(oldCode, newCode);
  fs.writeFileSync(file, content, "utf8");
  console.log(`[SUCCESS] 成功注入快速分词补丁: ${file}`);
}
EOF
)

echo -e "${BLUE}${BOLD}[INFO] 开始检查并修补 Cursor 图片分词阻塞问题...${NC}"

for target in "${TARGET_FILES[@]}"; do
  node -e "$PATCH_SCRIPT" "$target"
done

echo -e "${GREEN}${BOLD}[DONE] Cursor 插件补丁检查完成！${NC}"
