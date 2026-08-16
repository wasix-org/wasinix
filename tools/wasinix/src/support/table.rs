/// The one terminal table: left-aligned columns, a two-space gutter, width
/// from the data. Pass a header row only when the columns need naming.
pub fn render(header: Option<&[&str]>, rows: &[Vec<String>]) -> String {
    let mut all: Vec<Vec<String>> = Vec::new();
    if let Some(header) = header {
        all.push(header.iter().map(|h| h.to_string()).collect());
    }
    all.extend(rows.iter().cloned());
    let columns = all.iter().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![0usize; columns];
    for row in &all {
        for (index, cell) in row.iter().enumerate() {
            widths[index] = widths[index].max(cell.chars().count());
        }
    }
    let mut out = String::new();
    for row in &all {
        let mut line = String::new();
        for (index, cell) in row.iter().enumerate() {
            if index > 0 {
                line.push_str("  ");
            }
            line.push_str(cell);
            let pad = widths[index].saturating_sub(cell.chars().count());
            if index + 1 < row.len() {
                line.extend(std::iter::repeat_n(' ', pad));
            }
        }
        out.push_str(line.trim_end());
        out.push('\n');
    }
    out
}
