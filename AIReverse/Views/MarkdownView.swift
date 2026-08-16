import SwiftUI
import UIKit

/// Markdown 块类型
enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case code(language: String, code: String)
    case listItem(level: Int, text: String)
    case quote(String)
    case rule
}

/// 轻量 Markdown 解析器：支持标题、段落、代码块、列表、引用、分隔线
enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)

        var codeBuffer: [String] = []
        var codeLanguage = ""
        var inCode = false
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            blocks.append(.paragraph(paragraphBuffer.joined(separator: " ")))
            paragraphBuffer.removeAll()
        }

        func flushCode() {
            guard !codeBuffer.isEmpty || inCode else { return }
            blocks.append(.code(language: codeLanguage, code: codeBuffer.joined(separator: "\n")))
            codeBuffer.removeAll()
            codeLanguage = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 代码块
            if trimmed.hasPrefix("```") {
                if inCode {
                    inCode = false
                    flushCode()
                } else {
                    flushParagraph()
                    flushCode()
                    inCode = true
                    codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            if inCode {
                codeBuffer.append(line)
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            // 标题
            if trimmed.hasPrefix("### ") {
                flushParagraph()
                flushCode()
                blocks.append(.heading(3, String(trimmed.dropFirst(4))))
                continue
            }
            if trimmed.hasPrefix("## ") {
                flushParagraph()
                flushCode()
                blocks.append(.heading(2, String(trimmed.dropFirst(3))))
                continue
            }
            if trimmed.hasPrefix("# ") {
                flushParagraph()
                flushCode()
                blocks.append(.heading(1, String(trimmed.dropFirst(2))))
                continue
            }
            // 分隔线
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                flushCode()
                blocks.append(.rule)
                continue
            }
            // 引用
            if trimmed.hasPrefix("> ") {
                flushParagraph()
                flushCode()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
                continue
            }
            // 列表
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                flushCode()
                blocks.append(.listItem(level: 0, text: String(trimmed.dropFirst(2))))
                continue
            }
            if trimmed.hasPrefix("  - ") || trimmed.hasPrefix("\t- ") {
                flushParagraph()
                flushCode()
                blocks.append(.listItem(level: 1, text: String(trimmed.dropFirst(4))))
                continue
            }
            // 有序列表
            if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy({ $0.isNumber }) {
                flushParagraph()
                flushCode()
                let after = trimmed[dot...].dropFirst()
                blocks.append(.listItem(level: 0, text: String(after).trimmingCharacters(in: .whitespaces)))
                continue
            }
            // 段落
            paragraphBuffer.append(trimmed)
        }
        flushParagraph()
        flushCode()
        return blocks
    }
}

/// 渲染单段文本的行内 Markdown（粗体/斜体/行内代码绿色高亮）
struct InlineText: View {
    let text: String

    var body: some View {
        Text(attributedText(text))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var codeAccent: Color {
        Color(red: 0.60, green: 0.60, blue: 0.65)
    }

    private func attributedText(_ content: String) -> AttributedString {
        var result = AttributedString()
        var buffer = ""
        var inCode = false

        func appendBuffer(asCode: Bool) {
            guard !buffer.isEmpty else { return }
            var segment = parseMarkdown(buffer)
            if asCode {
                segment.font = .system(size: 14, design: .monospaced)
                segment.foregroundColor = codeAccent
            }
            result.append(segment)
            buffer = ""
        }

        for ch in content {
            if ch == "`" {
                if inCode {
                    appendBuffer(asCode: true)
                    inCode = false
                } else {
                    appendBuffer(asCode: false)
                    inCode = true
                }
            } else {
                buffer.append(ch)
            }
        }
        appendBuffer(asCode: inCode)
        return result
    }

    private func parseMarkdown(_ content: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(content)
    }
}

/// 代码块视图：等宽字体 + 深色背景 + 复制按钮 + 语言标签
struct CodeBlockView: View {
    let language: String
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "代码" : language)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.3))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
            }
        }
        .background(Color(red: 0.11, green: 0.12, blue: 0.16))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            Button {
                UIPasteboard.general.string = code
            } label: {
                Label("复制代码", systemImage: "doc.on.doc")
            }
        }
    }
}

/// 完整 Markdown 渲染视图
struct MarkdownView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownParser.parse(content).enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            InlineText(text: text)
                .font(.system(size: 14))
                .lineSpacing(4)
        case .heading(let level, let text):
            InlineText(text: text)
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .bold))
                .lineSpacing(2)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code)
        case .listItem(let level, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(level == 0 ? "•" : "◦")
                    .font(.system(size: 14))
                InlineText(text: text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
            }
            .padding(.leading, CGFloat(level) * 12)
        case .quote(let text):
            InlineText(text: text)
                .font(Font.system(size: 13).italic())
                .lineSpacing(3)
                .padding(.leading, 8)
                .overlay(
                    Rectangle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                        .padding(.leading, 0),
                    alignment: .leading
                )
        case .rule:
            Divider()
        }
    }
}

/// 工具调用卡片视图（MonkeyCode 绿色卡片风格）
struct ToolCallCardView: View {
    let card: ToolCallCard

    @State private var expanded = false

    private let accent = Color(red: 0.10, green: 0.62, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 13))
                    .foregroundColor(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(card.argumentsText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(expanded ? nil : 1)
                }
                Spacer()
                Button {
                    withAnimation { expanded.toggle() }
                } label: {
                    Text(expanded ? "收起" : "展开")
                        .font(.system(size: 12))
                        .foregroundColor(accent)
                }
                .buttonStyle(.plain)
                statusIcon
            }

            if expanded, let preview = card.resultPreview {
                Divider()
                Text(preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(card.status == .failed ? .red : .primary)
            }
        }
        .padding(12)
        .background(accent.opacity(0.06))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch card.status {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(accent)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(accent)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        }
    }
}
