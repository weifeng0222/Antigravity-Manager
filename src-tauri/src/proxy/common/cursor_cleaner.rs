use regex::Regex;
use std::sync::OnceLock;

// 1. 正则安全规则组（绝对不误伤单词间空格、换行、单句号）

/// 纯瀑布心跳点号：必须包含至少2个点号或省略号，绝对不误伤单个正常句号 "." 以及纯空格换行
pub fn pure_dots() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[\s\r\n]*(\.{2,}|…+)[\.\s…\r\n]*$").unwrap())
}

/// 开头多余点号/瀑布省略号（如 "...Creating" -> "Creating"），必须有2个及以上点号
pub fn leading_dots() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\s*(\.{2,}|…+)\s*").unwrap())
}

/// 结尾多余瀑布点号（如 "backup......." -> "backup"），必须有2个及以上点号
pub fn trailing_dots() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s*(\.{2,}|…+)\s*$").unwrap())
}

/// 文本内部连续4个以上的瀑布点号，折叠为常规省略号
pub fn cascade_dots() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\.{4,}").unwrap())
}

/// 动作/工具调用前推理特征识别（用于将正文中的行动陈述智能收纳进 Cursor Thinking）
pub fn action_planning_prefix() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^\s*(An?\b|A Python script\b|Executing\b|Running\b|Checking\b|Searching\b|Creating\b|Looking\b|Examining\b|Investigating\b|Applying\b|Updating\b|Reading\b|Writing\b|Inspecting\b|Managing\b|Modifying\b|Testing\b|Verifying\b|Exploring\b|Finding\b|Analyzing\b|Fixing\b|Reviewing\b|Replacing\b|Generating\b|Building\b|Compiling\b|Directly\b|The\b|In the\b|In\b|For the\b|For\b|This\b|Let me\b|Let's\b|I will\b|I'll\b|I need to\b|I should\b|I can\b|I am\b|I'm\b|We need to\b|We should\b|We will\b|We can\b|First\b|Next\b|Now\b|Then\b|Finally\b|Since\b|Because\b|However\b|Unfortunately\b|To fix\b|To resolve\b|To address\b|To verify\b|To check\b|To investigate\b|To proceed\b|Based on\b|According to\b|Thought\b|Thinking\b|Plan\b|Action\b|Step\b)").unwrap()
    })
}

/// 中文字符检测：若包含中文，说明是正式正文回复，切回正常正文通道
pub fn chinese_char() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[\u{4e00}-\u{9fa5}]").unwrap())
}

/// 点号/省略号检测
pub fn contains_dots() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[\.…]").unwrap())
}

/// 检测并剥离 Gemini / Claude 等模型在长上下文下偶发泄漏的 `call:default_api:*` 伪代码语法
pub fn clean_default_api_leakage(text: &str) -> String {
    if !text.contains("default_api:") {
        return text.to_string();
    }
    // 1. 若行首或段首带有孤立点号（例如 ".\n.call:default_api:" 或以 ".call:default_api:" 开头），剥离前导多余点号
    static RE_LEAD_DOT: OnceLock<Regex> = OnceLock::new();
    let re_lead_dot =
        RE_LEAD_DOT.get_or_init(|| Regex::new(r"(?m)(^|\n)\s*\.\s*call:default_api:").unwrap());
    let s = re_lead_dot.replace_all(text, "${1}call:default_api:");

    // 2. 剥离无论是闭合 `{...}` 还是流式未闭合到结尾 `{...` 的伪工具调用，完整保留句末句号与正常内容
    static RE_LEAK: OnceLock<Regex> = OnceLock::new();
    let re_leak = RE_LEAK.get_or_init(|| {
        Regex::new(r"(?s)call:default_api:[A-Za-z0-9_-]+(?:\s*\{[^\}]*\}|\s*\([^\)]*\)|\s*\{.*$|\s*\(.*$)?").unwrap()
    });
    let s = re_leak.replace_all(&s, "");
    s.to_string()
}

/// 有状态的 Cursor 流式清洗器（支持 Anthropic 和 OpenAI 协议）
#[derive(Debug, Default)]
pub struct CursorStreamCleaner {
    buffer: String,
}

impl CursorStreamCleaner {
    pub fn new() -> Self {
        Self::default()
    }

    /// 接收流式 chunk，按完整 SSE 事件块 (\n\n) 进行清洗并返回清洗后的文本
    pub fn clean_chunk(&mut self, chunk_str: &str) -> String {
        self.buffer.push_str(chunk_str);
        let mut out = String::new();

        while let Some((boundary_idx, delim_len)) = self.find_block_boundary() {
            let raw_block: String = self.buffer[..boundary_idx].to_string();
            self.buffer.drain(..boundary_idx + delim_len);

            if raw_block.trim().is_empty() {
                out.push_str("\n\n");
                continue;
            }

            let cleaned = self.clean_sse_block(&raw_block);
            out.push_str(&cleaned);
        }

        out
    }

    /// 在流结束时冲刷可能残留在 buffer 中的最后一块数据
    pub fn flush(&mut self) -> Option<String> {
        if self.buffer.trim().is_empty() {
            self.buffer.clear();
            None
        } else {
            let raw = std::mem::take(&mut self.buffer);
            Some(self.clean_sse_block(&raw))
        }
    }

    fn find_block_boundary(&self) -> Option<(usize, usize)> {
        let n1 = self.buffer.find("\r\n\r\n");
        let n2 = self.buffer.find("\n\n");
        match (n1, n2) {
            (Some(i1), Some(i2)) => {
                if i1 <= i2 {
                    Some((i1, 4))
                } else {
                    Some((i2, 2))
                }
            }
            (Some(i1), None) => Some((i1, 4)),
            (None, Some(i2)) => Some((i2, 2)),
            (None, None) => None,
        }
    }

    fn clean_sse_block(&mut self, raw_block: &str) -> String {
        let mut event_name: Option<String> = None;
        let mut data_str: Option<String> = None;
        let mut other_lines = Vec::new();

        for line in raw_block.lines() {
            if let Some(rest) = line.strip_prefix("event:") {
                event_name = Some(rest.trim().to_string());
            } else if let Some(rest) = line.strip_prefix("data:") {
                let val = rest.trim();
                data_str = match data_str {
                    None => Some(val.to_string()),
                    Some(prev) => Some(format!("{}\n{}", prev, val)),
                };
            } else {
                other_lines.push(line);
            }
        }

        // 1. 无 data 字段原样透传
        let data_raw = match data_str {
            Some(d) => d,
            None => {
                return format!("{}\n\n", raw_block);
            }
        };

        // 2. [DONE] 原样输出
        if data_raw == "[DONE]" {
            return format!("{}\n\n", raw_block);
        }

        // 3. 尝试解析 JSON
        let mut val: serde_json::Value = match serde_json::from_str(&data_raw) {
            Ok(v) => v,
            Err(_) => {
                return format!("{}\n\n", raw_block);
            }
        };

        // ====================================================================
        // A. 处理 Anthropic Messages 协议 (/v1/messages)
        // ====================================================================
        if let Some(typ) = val.get("type").and_then(|v| v.as_str()) {
            if typ.starts_with("content_block_") {
                if typ == "content_block_start" {
                    return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
                }

                if typ == "content_block_delta" {
                    let delta_type = val
                        .pointer("/delta/type")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();

                    if delta_type == "text_delta" {
                        let text = val
                            .pointer("/delta/text")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();

                        // 纯点号心跳过滤（过滤为 : ping）
                        if pure_dots().is_match(&text) {
                            return ": ping\n\n".to_string();
                        }

                        // 清洗多余点号与伪工具泄漏
                        // 注意：严禁将已声明为 text 的 content_block 中的 text_delta 篡改为 thinking_delta，
                        // 否则违反 Anthropic Messages SSE 协议契约，导致 Claude Code / Anthropic SDK 抛出
                        // "API Error: Content block is not a thinking block"。
                        let text = leading_dots().replace(&text, "");
                        let text = trailing_dots().replace(&text, "");
                        let text = cascade_dots().replace_all(&text, "...");
                        let text = clean_default_api_leakage(&text);

                        if text.is_empty() {
                            return ": ping\n\n".to_string();
                        }

                        if let Some(delta) = val.get_mut("delta") {
                            delta["text"] = serde_json::Value::String(text);
                        }

                        return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
                    } else if delta_type == "thinking_delta" {
                        let text = val
                            .pointer("/delta/thinking")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();

                        if pure_dots().is_match(&text) {
                            return ": ping\n\n".to_string();
                        }

                        let text = leading_dots().replace(&text, "");
                        let text = trailing_dots().replace(&text, "");
                        let text = cascade_dots().replace_all(&text, "...");

                        if let Some(delta) = val.get_mut("delta") {
                            delta["thinking"] = serde_json::Value::String(text.into_owned());
                        }

                        return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
                    }

                    return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
                }

                if typ == "content_block_stop" {
                    return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
                }
            }
        }

        // ====================================================================
        // B. 处理 OpenAI Responses 协议: response.reasoning_summary_text.delta
        // ====================================================================
        if val.get("type").and_then(|v| v.as_str()) == Some("response.reasoning_summary_text.delta")
        {
            let reasoning = val
                .get("delta")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            if pure_dots().is_match(&reasoning) {
                return ": ping\n\n".to_string();
            }

            let reasoning = leading_dots().replace(&reasoning, "");
            let reasoning = trailing_dots().replace(&reasoning, "");
            let reasoning = cascade_dots().replace_all(&reasoning, "...");
            let reasoning = clean_default_api_leakage(&reasoning);

            val["delta"] = serde_json::Value::String(reasoning);
            return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
        }

        // ====================================================================
        // B2. 处理 OpenAI Responses 协议: response.output_text.delta
        // ====================================================================
        if val.get("type").and_then(|v| v.as_str()) == Some("response.output_text.delta") {
            let text = val
                .get("delta")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();

            if pure_dots().is_match(&text) {
                return ": ping\n\n".to_string();
            }

            let text = leading_dots().replace(&text, "");
            let text = trailing_dots().replace(&text, "");
            let text = cascade_dots().replace_all(&text, "...");
            let text = clean_default_api_leakage(&text);

            if text.is_empty() {
                return ": ping\n\n".to_string();
            }

            val["delta"] = serde_json::Value::String(text);
            return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
        }

        if val.get("type").and_then(|v| v.as_str()) == Some("response.output_text.done") {
            if let Some(text) = val.get("text").and_then(|v| v.as_str()) {
                let cleaned = clean_default_api_leakage(text);
                val["text"] = serde_json::Value::String(cleaned);
            }
            return self.rebuild_block(event_name.as_deref(), &other_lines, &val);
        }

        // ====================================================================
        // C. 处理 OpenAI Chat & Legacy Completions 协议
        // ====================================================================
        let choice = val.pointer("/choices/0");
        let delta = choice.and_then(|c| c.get("delta"));

        let mut content: Option<String> = None;
        let mut content_type: Option<&str> = None;

        if let Some(d) = val.get("delta").and_then(|v| v.as_str()) {
            content = Some(d.to_string());
            content_type = Some("responses_delta");
        } else if let Some(c) = delta
            .and_then(|d| d.get("content"))
            .and_then(|v| v.as_str())
        {
            content = Some(c.to_string());
            content_type = Some("chat_delta");
        } else if let Some(t) = choice.and_then(|c| c.get("text")).and_then(|v| v.as_str()) {
            content = Some(t.to_string());
            content_type = Some("choice_text");
        } else if let Some(c) = val.get("content").and_then(|v| v.as_str()) {
            content = Some(c.to_string());
            content_type = Some("top_content");
        } else if let Some(t) = val.get("text").and_then(|v| v.as_str()) {
            content = Some(t.to_string());
            content_type = Some("top_text");
        }

        let has_payload = delta.map_or(false, |d| {
            d.get("tool_calls").is_some() || d.get("reasoning_content").is_some()
        }) || val.get("tool_calls").is_some()
            || val.get("thinking").is_some()
            || val.get("function_call").is_some()
            || choice.map_or(false, |c| {
                c.get("tool_calls").is_some() || c.get("finish_reason").is_some()
            })
            || val
                .get("type")
                .and_then(|v| v.as_str())
                .map_or(false, |t| t.contains("function_call"));

        if let (Some(text), Some(ctype)) = (content, content_type) {
            if !has_payload && pure_dots().is_match(&text) {
                return ": ping\n\n".to_string();
            }

            let cleaned = leading_dots().replace(&text, "");
            let cleaned = trailing_dots().replace(&cleaned, "");
            let mut cleaned = cascade_dots().replace_all(&cleaned, "...").into_owned();
            cleaned = clean_default_api_leakage(&cleaned);

            if cleaned.trim().is_empty() {
                if contains_dots().is_match(&text) {
                    if !has_payload {
                        return ": ping\n\n".to_string();
                    } else {
                        cleaned.clear();
                    }
                }
            }

            if cleaned != text {
                match ctype {
                    "responses_delta" => {
                        val["delta"] = serde_json::Value::String(cleaned);
                    }
                    "chat_delta" => {
                        if let Some(d) = val.pointer_mut("/choices/0/delta") {
                            d["content"] = serde_json::Value::String(cleaned);
                        }
                    }
                    "choice_text" => {
                        if let Some(c) = val.pointer_mut("/choices/0") {
                            c["text"] = serde_json::Value::String(cleaned);
                        }
                    }
                    "top_content" => {
                        val["content"] = serde_json::Value::String(cleaned);
                    }
                    "top_text" => {
                        val["text"] = serde_json::Value::String(cleaned);
                    }
                    _ => {}
                }
            }
        }

        self.rebuild_block(event_name.as_deref(), &other_lines, &val)
    }

    fn rebuild_block(
        &self,
        event_name: Option<&str>,
        other_lines: &[&str],
        val: &serde_json::Value,
    ) -> String {
        let mut out = String::new();
        if let Some(ev) = event_name {
            out.push_str("event: ");
            out.push_str(ev);
            out.push('\n');
        }
        for o in other_lines {
            out.push_str(o);
            out.push('\n');
        }
        out.push_str("data: ");
        out.push_str(&val.to_string());
        out.push_str("\n\n");
        out
    }
}

/// 快捷单块清洗接口（向下兼容）
pub fn clean_cursor_sse_chunk(chunk_str: &str) -> String {
    let mut cleaner = CursorStreamCleaner::new();
    let mut out = cleaner.clean_chunk(chunk_str);
    if let Some(rem) = cleaner.flush() {
        out.push_str(&rem);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pure_dots_filtering() {
        let mut cleaner = CursorStreamCleaner::new();
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\".....\"}}]}\n\n";
        let out = cleaner.clean_chunk(sse);
        assert_eq!(out, ": ping\n\n");

        let normal = "data: {\"choices\":[{\"delta\":{\"content\":\".\"}}]}\n\n";
        let out_normal = cleaner.clean_chunk(normal);
        assert!(out_normal.contains("\".\""));
    }

    #[test]
    fn test_cascade_dots_collapsing() {
        let mut cleaner = CursorStreamCleaner::new();
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"Searching.......done\"}}]}\n\n";
        let out = cleaner.clean_chunk(sse);
        assert!(out.contains("Searching...done"));
    }

    #[test]
    fn test_anthropic_text_delta_preserves_block_type_contract() {
        let mut cleaner = CursorStreamCleaner::new();

        // 1. content_block_start declares a "text" block at index 0
        let start = "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n";
        let out_start = cleaner.clean_chunk(start);
        assert!(out_start.contains("content_block_start"));

        // 2. content_block_delta with English prefix and trailing dots must stay text_delta
        //    (converting to thinking_delta on a text block triggers "Content block is not a thinking block")
        let delta = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"The user observes that cold accounts are not being automatically activated...\"}}\n\n";
        let out_delta = cleaner.clean_chunk(delta);
        assert!(out_delta.contains("\"type\":\"text_delta\""));
        assert!(!out_delta.contains("\"type\":\"thinking_delta\""));
        assert!(out_delta.contains(
            "\"text\":\"The user observes that cold accounts are not being automatically activated\""
        ));

        // 3. Subsequent English sentence also remains text_delta
        let delta2 = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"In `@anthropic-ai/sdk`, content_block_start initializes a text block.\"}}\n\n";
        let out_delta2 = cleaner.clean_chunk(delta2);
        assert!(out_delta2.contains("\"type\":\"text_delta\""));
        assert!(!out_delta2.contains("\"type\":\"thinking_delta\""));

        // 4. Chinese text also remains text_delta
        let delta_cn = "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"好的，我现在为您修复这个问题。\"}}\n\n";
        let out_delta_cn = cleaner.clean_chunk(delta_cn);
        assert!(out_delta_cn.contains("\"type\":\"text_delta\""));
        assert!(out_delta_cn.contains("\"text\":\"好的，我现在为您修复这个问题。\""));
    }

    #[test]
    fn test_action_planning_prefix_patterns() {
        assert!(action_planning_prefix().is_match(
            "The system indicates that the modification has been applied to account_pool.py"
        ));
        assert!(action_planning_prefix().is_match("The patch failed with an `invalid format` error, likely due to a minor syntax mismatch in the unified diff format required by `ApplyPatch`"));
        assert!(action_planning_prefix().is_match("The"));
        assert!(action_planning_prefix().is_match("  \n The patch failed"));
        assert!(
            action_planning_prefix().is_match("Executing cargo check to verify code compilation")
        );
        assert!(action_planning_prefix().is_match("Let me check the logs first"));
        assert!(action_planning_prefix().is_match("To fix this issue, I will read the file"));
        assert!(action_planning_prefix().is_match("Unfortunately the command failed"));
        assert!(!chinese_char().is_match(
            "The system indicates that the modification has been applied to account_pool.py"
        ));
        assert!(chinese_char().is_match("好的，我已经为您应用了修改"));
    }

    #[test]
    fn test_clean_default_api_leakage() {
        // 1. Image #36 real-world sample
        let s1 = "The hypothesis is that a single request to the responses endpoint will initiate the 5-hour rolling window.call:default_api:Shell{description:Check auth file of 1wkpzhugbo6t1t_dr.com}";
        let cleaned1 = clean_default_api_leakage(s1);
        assert_eq!(
            cleaned1,
            "The hypothesis is that a single request to the responses endpoint will initiate the 5-hour rolling window."
        );

        // 2. Database real-world sample 2
        let s2 = "continue.off is present.call:default_api:Shell{description:Run: ls -la /weifeng/.codex-acc}";
        let cleaned2 = clean_default_api_leakage(s2);
        assert_eq!(cleaned2, "continue.off is present.");

        // 3. Unclosed streaming fragment
        let s3 = "ay for the updated logic.call:default_api:Shell{description:Kill current stuck warmup daemo";
        let cleaned3 = clean_default_api_leakage(s3);
        assert_eq!(cleaned3, "ay for the updated logic.");

        // 4. Standalone with leading dot
        let s4 = ".call:default_api:Shell{description:Check auth file}";
        let cleaned4 = clean_default_api_leakage(s4);
        assert_eq!(cleaned4.trim(), "");

        // 5. Normal text with periods should NOT be harmed
        let s5 = "This is a normal sentence. Version 1.2.3 is released.";
        assert_eq!(clean_default_api_leakage(s5), s5);
    }

    #[test]
    fn test_codex_output_text_delta_cleaning() {
        let mut cleaner = CursorStreamCleaner::new();

        // Codex response.output_text.delta containing call:default_api leakage
        let sse = "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"content_index\":0,\"delta\":\"The rolling window.call:default_api:Shell{description:Check auth file}\"}\n\n";
        let out = cleaner.clean_chunk(sse);
        assert!(out.contains("The rolling window."));
        assert!(!out.contains("call:default_api"));
    }
}
