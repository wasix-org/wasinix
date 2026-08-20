//! The one gate untrusted text passes before it reaches GitHub markdown.
//! Build logs and junit messages are PR-controlled: a line that closes a
//! fence would let the rest render as markup, including forged markers.
//!
//! [`Markdown`] is the gate's structural form: its string-accepting
//! constructors sanitize for the context they open, and the only way to
//! insert unsanitized text is [`Markdown::constant`], which takes `'static`
//! so nothing computed at runtime can pass. A comment body is assembled from
//! these values, never from `format!`.

/// Escape for HTML contexts (`<summary>`, table cells rendered as HTML). Line
/// breaks collapse to spaces: a blank line ends an HTML block in GFM, so an
/// untrusted string could otherwise break out and render as markdown.
pub fn escape_html(text: &str) -> String {
    let mut escaped = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&#39;"),
            '\r' => {}
            '\n' => escaped.push(' '),
            _ => escaped.push(character),
        }
    }
    escaped
}

/// A fenced code block whose fence is longer than any backtick run in the
/// payload, so no payload line can close it.
pub fn fence(text: &str, language: &str) -> String {
    let longest_run = text
        .split(|character| character != '`')
        .map(str::len)
        .max()
        .unwrap_or(0);
    let fence = "`".repeat((longest_run + 1).max(3));
    let body = text.trim_end_matches('\n');
    format!("{fence}{language}\n{body}\n{fence}\n")
}

/// One table cell: pipes, newlines, and backticks must not restructure the
/// table or open spans that swallow the following cells. Backslash is escaped
/// first, or an input `\|` would arrive as `\\|` and the escaped backslash
/// would consume the escape, leaving the pipe live.
pub fn table_cell(text: &str) -> String {
    let mut cell = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '\\' => cell.push_str("\\\\"),
            '|' => cell.push_str("\\|"),
            '`' => cell.push_str("\\`"),
            '\r' => {}
            '\n' => cell.push(' '),
            _ => cell.push(character),
        }
    }
    cell
}

/// An inline code span sized past the payload's backtick runs, for job names
/// and error snippets inside prose or table cells. Line breaks collapse to
/// spaces: a newline would close the span and start block markdown at column
/// zero.
pub fn code_span(text: &str) -> String {
    let text: String = text
        .chars()
        .map(|character| match character {
            '\r' => ' ',
            '\n' => ' ',
            other => other,
        })
        .collect();
    if !text.contains('`') {
        return format!("`{text}`");
    }
    let longest_run = text
        .split(|character| character != '`')
        .map(str::len)
        .max()
        .unwrap_or(0);
    let ticks = "`".repeat(longest_run + 1);
    format!("{ticks} {text} {ticks}")
}

/// A piece of GitHub markdown whose content went through the context-correct
/// sanitizer at construction. Concatenation and joining are the only ways to
/// combine pieces, so sanitization cannot be skipped between them.
#[derive(Clone, Default)]
pub struct Markdown(String);

impl Markdown {
    pub fn new() -> Markdown {
        Markdown(String::new())
    }

    /// A compile-time constant: markup skeleton, glyphs, punctuation. The
    /// `'static` bound is what keeps this safe; a runtime-built string
    /// cannot reach it.
    pub fn constant(text: &'static str) -> Markdown {
        Markdown(text.to_string())
    }

    /// Prose or heading text: HTML-escaped, line breaks collapsed, so it can
    /// neither open markup nor break out of its block.
    pub fn text(text: &str) -> Markdown {
        Markdown(escape_html(text))
    }

    /// One table cell.
    pub fn cell(text: &str) -> Markdown {
        Markdown(table_cell(text))
    }

    /// An inline code span.
    pub fn code(text: &str) -> Markdown {
        Markdown(code_span(text))
    }

    /// A code span inside a table cell: the span neutralizes backticks, the
    /// cell still needs pipes and newlines flattened around it.
    pub fn cell_code(text: &str) -> Markdown {
        Markdown(code_span(&text.replace(['\r', '\n'], " ")).replace('|', "\\|"))
    }

    /// A fenced block sized past the payload.
    pub fn fenced(text: &str, language: &'static str) -> Markdown {
        Markdown(fence(text, language))
    }

    /// A link. A destination that could restructure the surrounding markdown
    /// (a paren, whitespace, a non-http scheme) renders as label + code span
    /// instead, visibly rather than brokenly.
    pub fn link(label: &'static str, url: &str) -> Markdown {
        if url_is_plain(url) {
            Markdown(format!("[{label}]({url})"))
        } else {
            Markdown(format!("{label} {}", code_span(url)))
        }
    }

    /// A link labelled with runtime text, such as a version move. A bracket
    /// in the label would close the link early and spill the url as prose, so
    /// the label escapes brackets on top of [`Markdown::text`].
    pub fn text_link(label: &str, url: &str) -> Markdown {
        let label = escape_html(label).replace('[', "\\[").replace(']', "\\]");
        if url_is_plain(url) {
            Markdown(format!("[{label}]({url})"))
        } else {
            Markdown(format!("{label} {}", code_span(url)))
        }
    }

    /// A link inside a table cell: the degraded form must also keep the
    /// cell's pipes flattened, since a pipe breaks the row even inside a
    /// code span.
    pub fn cell_link(label: &'static str, url: &str) -> Markdown {
        if url_is_plain(url) {
            Markdown(format!("[{label}]({url})"))
        } else {
            Markdown(format!("{label} "))
                .push(Markdown::cell_code(url))
        }
    }

    /// An `<a href>` for HTML contexts, degrading like [`Markdown::link`].
    pub fn html_link(label: &'static str, url: &str) -> Markdown {
        if url_is_plain(url) {
            Markdown(format!("<a href=\"{}\">{label}</a>", escape_html(url)))
        } else {
            Markdown(format!("{label} {}", code_span(url)))
        }
    }


    pub fn push(mut self, other: Markdown) -> Markdown {
        self.0.push_str(&other.0);
        self
    }

    pub fn join(parts: impl IntoIterator<Item = Markdown>, separator: &'static str) -> Markdown {
        let joined: Vec<String> = parts.into_iter().map(|part| part.0).collect();
        Markdown(joined.join(separator))
    }

    pub fn concat(parts: impl IntoIterator<Item = Markdown>) -> Markdown {
        Markdown::join(parts, "")
    }

    /// The assembled bytes. Leaves the typed world; only the budgeting and
    /// upsert layers consume it.
    pub fn into_string(self) -> String {
        self.0
    }
}

/// A destination that renders inside `[..](..)` or `href=".."` without
/// restructuring it.
fn url_is_plain(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("http://"))
        && !url.contains([')', '(', '<', '>', '"', '\'', '|', '`'])
        && !url.chars().any(char::is_whitespace)
}
