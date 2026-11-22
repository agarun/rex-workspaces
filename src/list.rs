use crate::spec;
use crate::theme::{bold, faint, muted, palette, text};
use crate::widgets::{
    button_row, button_rows, draw_button, line, Button, Hits, Target, Tone, BUTTON_HEIGHT,
};
use ratatui::layout::Rect;
use ratatui::style::Style;
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Paragraph};
use ratatui::Frame;
use serde_json::Value;

pub struct View<'a> {
    pub workspaces: &'a [Value],
    pub visible: &'a [usize],
    pub loaded: bool,
    pub filter: Option<&'a str>,
    pub selected: usize,
    pub home: &'a str,
    pub status: Option<Line<'static>>,
    pub button_focus: Option<usize>,
}

fn servers(ws: &Value) -> &[Value] {
    ws["servers"].as_array().map_or(&[], Vec::as_slice)
}

fn shown_worktree(server: &Value) -> Option<&str> {
    server["worktree"].as_str().filter(|w| *w != "main")
}

fn running(ws: &Value) -> bool {
    ws["running"].as_bool().unwrap_or(false)
}

fn paused(ws: &Value) -> bool {
    ws["paused"].as_bool().unwrap_or(false)
}

fn saved(ws: &Value) -> bool {
    ws["saved"].as_bool().unwrap_or(false)
}

fn state(ws: &Value) -> (Span<'static>, String) {
    let p = palette();
    let total = servers(ws).len();
    let up = ws["servers_up"].as_u64().unwrap_or(0) as usize;
    if saved(ws) {
        return (Span::styled("◌", muted()), "saved".into());
    }
    if !running(ws) {
        return (Span::styled("○", faint()), "stopped".into());
    }
    if paused(ws) {
        return (
            Span::styled("●", Style::new().fg(p.accent)),
            "paused".into(),
        );
    }
    if total == 0 {
        return (Span::styled("●", Style::new().fg(p.success)), "open".into());
    }
    let color = if up == total { p.success } else { p.warning };
    (
        Span::styled("●", Style::new().fg(color)),
        format!("{up} of {total} running"),
    )
}

pub fn matches(name: &str, query: &str) -> bool {
    let mut chars = name.chars().flat_map(char::to_lowercase);
    query
        .chars()
        .flat_map(char::to_lowercase)
        .filter(|c| !c.is_whitespace())
        .all(|q| chars.any(|c| c == q))
}

pub fn buttons(selected: Option<&Value>) -> Vec<(&'static str, Button)> {
    let Some(ws) = selected else {
        return Vec::new();
    };
    let open = Button::new("Open", "enter", Tone::Primary);
    let edit = Button::new("Edit", "e", Tone::Normal);
    if saved(ws) {
        let discard = Button::new("Forget saved", "c", Tone::Danger);
        return vec![("open", open), ("close", discard), ("edit", edit)];
    }
    if !running(ws) {
        if servers(ws).is_empty() {
            return vec![("open", open), ("edit", edit)];
        }
        let start = Button::new("Start", "s", Tone::Normal);
        return vec![("open", open), ("start", start), ("edit", edit)];
    }
    let close = Button::new("Close", "c", Tone::Danger);
    if paused(ws) {
        return vec![("open", open), ("close", close), ("edit", edit)];
    }
    let total = servers(ws).len() as u64;
    let up = ws["servers_up"].as_u64().unwrap_or(0);
    let stops_panes = ws["stops_panes"] == true;
    let mut out = vec![("open", open)];
    if up < total {
        out.push(("start", Button::new("Start", "s", Tone::Normal)));
    }
    if up > 0 || stops_panes {
        out.push(("stop", Button::new("Stop", "x", Tone::Normal)));
    }
    if up > 0 {
        out.push(("restart", Button::new("Restart", "r", Tone::Normal)));
    }
    out.push((
        "save_close",
        Button::new("Save & Close", "ctrl+s", Tone::Normal),
    ));
    out.push(("close", close));
    out.push(("edit", edit));
    out
}

pub fn extras(any: bool) -> Vec<(&'static str, &'static str, &'static str)> {
    let mut out = vec![("new", "New", "n"), ("capture", "Save new", "w")];
    if any {
        out.push(("filter", "Filter", "/"));
    }
    out
}

fn extras_line(f: &mut Frame, rect: Rect, any: bool, hits: &mut Hits, hover: Option<Target>) {
    let mut x = rect.x;
    for (i, (_, label, key)) in extras(any).into_iter().enumerate() {
        let width = (label.chars().count() + key.chars().count() + 1) as u16;
        if x + width > rect.x + rect.width {
            break;
        }
        let r = Rect::new(x, rect.y, width, 1);
        let style = if hover == Some(Target::Extra(i)) {
            text()
        } else {
            muted()
        };
        let spans = vec![
            Span::styled(label, style),
            Span::styled(format!(" {key}"), faint()),
        ];
        line(f, r, 0, Line::from(spans));
        hits.add(r, Target::Extra(i));
        x += width + 3;
    }
}

fn card_height(ws: &Value, selected: bool) -> u16 {
    match servers(ws).len() {
        n if selected && n > 0 => 4 + n as u16,
        _ => 3,
    }
}

fn draw_card(f: &mut Frame, rect: Rect, ws: &Value, selected: bool, hovered: bool, home: &str) {
    let p = palette();
    let (dot, status) = state(ws);
    let name = ws["name"].as_str().unwrap_or("?").to_string();
    let border = match (selected, hovered) {
        (true, _) => p.accent,
        (false, true) => p.muted,
        _ => p.border,
    };
    let name_style = if selected {
        bold().fg(p.accent)
    } else {
        bold()
    };
    let expanded = selected && !servers(ws).is_empty();
    let mut title = if expanded {
        vec![Span::raw(" ")]
    } else {
        vec![Span::raw(" "), dot, Span::raw(" ")]
    };
    title.extend([Span::styled(name, name_style), Span::raw(" ")]);
    if let Some(key) = ws["key"].as_str() {
        title.push(Span::styled(format!("{key} "), faint()));
    }
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::new().fg(border))
        .title(Line::from(title))
        .title(Line::styled(format!(" {status} "), muted()).right_aligned());
    let inner = block.inner(rect);
    f.render_widget(block, rect);
    let inner = Rect::new(
        inner.x + 1,
        inner.y,
        inner.width.saturating_sub(2),
        inner.height,
    );
    let root = spec::contract(ws["root"].as_str().unwrap_or("~"), home);
    let mut lines = vec![Line::styled(root, faint())];
    if expanded {
        lines.push(Line::default());
        let width = servers(ws)
            .iter()
            .filter_map(|s| s["label"].as_str())
            .map(str::len)
            .max()
            .unwrap_or(0);
        for s in servers(ws) {
            let up = s["up"].as_bool().unwrap_or(false);
            let dot = if up {
                Span::styled("●", Style::new().fg(p.success))
            } else {
                Span::styled("○", faint())
            };
            let label = s["label"].as_str().unwrap_or("");
            let cmd = s["cmd"].as_str().unwrap_or("").to_string();
            let mut spans = vec![
                dot,
                Span::styled(format!(" {label:<width$}  "), text()),
                Span::styled(cmd, muted()),
            ];
            if let Some(wt) = shown_worktree(s) {
                spans.push(Span::styled(format!("  ⎇ {wt}"), faint()));
            }
            lines.push(Line::from(spans));
        }
    }
    f.render_widget(Paragraph::new(lines), inner);
}

fn first_visible(cards: &[(usize, &Value)], selected: usize, room: u16) -> usize {
    let Some(end) = cards.iter().position(|(i, _)| *i == selected) else {
        return 0;
    };
    let span = |start: usize| -> u16 {
        cards[start..=end]
            .iter()
            .map(|(i, w)| card_height(w, *i == selected))
            .sum()
    };
    let mut start = 0;
    while start < end && span(start) > room {
        start += 1;
    }
    start
}

pub fn render(f: &mut Frame, area: Rect, view: View, hits: &mut Hits, hover: Option<Target>) {
    let cards: Vec<(usize, &Value)> = view
        .visible
        .iter()
        .map(|&i| (i, &view.workspaces[i]))
        .collect();
    let current = view
        .workspaces
        .get(view.selected)
        .filter(|_| view.visible.contains(&view.selected));
    let any = !view.workspaces.is_empty();
    let actions = buttons(current);
    if view.loaded && !any {
        first_workspace(f, area, hits, hover);
        return;
    }
    let bar: Vec<Button> = actions.into_iter().map(|(_, b)| b).collect();
    let bar_height = button_rows(area, &bar);
    let mut top = area.y;
    if let Some(query) = view.filter {
        let p = palette();
        let typing = view.button_focus.is_none();
        let mut spans = vec![
            Span::styled("Filter  ", muted()),
            Span::styled(query.to_string(), bold()),
        ];
        if typing {
            spans.push(Span::styled(" ", Style::new().bg(p.accent)));
        }
        spans.push(Span::styled("   esc clears", faint()));
        line(f, area, 0, Line::from(spans));
        top += 2;
    }
    let room = (area.y + area.height).saturating_sub(top + bar_height + 4);
    if view.loaded && cards.is_empty() {
        let rect = Rect::new(area.x, top, area.width, 1);
        line(f, rect, 0, Line::styled("No workspaces match", muted()));
    }
    let mut y = top;
    let start = first_visible(&cards, view.selected, room);
    for &(i, ws) in cards.iter().skip(start) {
        let selected = i == view.selected;
        let mut height = card_height(ws, selected);
        if y + height > top + room {
            if y > top || room < 3 {
                break;
            }
            height = room;
        }
        let rect = Rect::new(area.x, y, area.width, height);
        let hovered = hover == Some(Target::Row(i));
        draw_card(f, rect, ws, selected, hovered, view.home);
        hits.add(rect, Target::Row(i));
        y += height;
    }

    let bar_area = Rect::new(
        area.x,
        area.y + area.height.saturating_sub(bar_height),
        area.width,
        bar_height,
    );
    button_row(f, bar_area, &bar, hits, hover, view.button_focus);
    let extras_y = if bar.is_empty() {
        bar_area.y.saturating_sub(1)
    } else {
        bar_area.y.saturating_sub(2)
    };
    if extras_y >= top {
        let rect = Rect::new(area.x, extras_y, area.width, 1);
        extras_line(f, rect, any, hits, hover);
    }
    if let Some(status) = view.status {
        let rect = Rect::new(area.x, extras_y.saturating_sub(2), area.width, 1);
        line(f, rect, 0, status);
    }
}

fn first_workspace(f: &mut Frame, area: Rect, hits: &mut Hits, hover: Option<Target>) {
    let lead = "Add your first workspace  →  ";
    let y = area.y + area.height.saturating_sub(BUTTON_HEIGHT);
    let x = area.x + lead.chars().count() as u16;
    let b = Button::new("New", "n", Tone::Normal);
    let rect = Rect::new(
        x,
        y,
        b.width().min(area.width.saturating_sub(x - area.x)),
        1,
    );
    line(
        f,
        Rect::new(area.x, y, area.width, 1),
        0,
        Line::styled(lead, muted()),
    );
    let hovered = hover == Some(Target::Extra(0));
    draw_button(f, rect, &b, hovered, None);
    hits.add(rect, Target::Extra(0));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn labels(ws: Value) -> Vec<String> {
        buttons(Some(&ws))
            .into_iter()
            .map(|(_, b)| b.label)
            .collect()
    }

    #[test]
    fn only_buttons_that_apply_are_shown() {
        assert!(buttons(None).is_empty());
        assert_eq!(labels(json!({})), ["Open", "Edit"]);
        let servers = json!([{ "label": "web" }, { "label": "api" }]);
        assert_eq!(
            labels(json!({ "servers": servers })),
            ["Open", "Start", "Edit"]
        );
        let some = json!({ "running": true, "servers_up": 1, "servers": servers });
        assert_eq!(
            labels(some),
            [
                "Open",
                "Start",
                "Stop",
                "Restart",
                "Save & Close",
                "Close",
                "Edit"
            ]
        );
        let all = json!({ "running": true, "servers_up": 2, "servers": servers });
        assert_eq!(
            labels(all),
            ["Open", "Stop", "Restart", "Save & Close", "Close", "Edit"]
        );
        let none = json!({ "running": true, "servers_up": 0, "servers": servers });
        assert_eq!(
            labels(none),
            ["Open", "Start", "Save & Close", "Close", "Edit"]
        );
        let panes = json!({ "running": true, "stops_panes": true });
        assert_eq!(
            labels(panes),
            ["Open", "Stop", "Save & Close", "Close", "Edit"]
        );
        let paused = json!({ "running": true, "paused": true });
        assert_eq!(labels(paused), ["Open", "Close", "Edit"]);
        assert_eq!(
            labels(json!({ "saved": true })),
            ["Open", "Forget saved", "Edit"]
        );
    }

    #[test]
    fn filter_shows_only_with_workspaces() {
        assert_eq!(extras(false).len(), 2);
        assert_eq!(extras(true)[2].1, "Filter");
    }

    #[test]
    fn worktree_shows_unless_main() {
        assert_eq!(
            shown_worktree(&json!({ "worktree": "feat-x" })),
            Some("feat-x")
        );
        assert_eq!(shown_worktree(&json!({ "worktree": "main" })), None);
        assert_eq!(shown_worktree(&json!({})), None);
    }

    #[test]
    fn status_label_is_lowercase() {
        let status = |ws: Value| state(&ws).1;
        assert_eq!(status(json!({})), "stopped");
        assert_eq!(status(json!({ "running": true })), "open");
        let ws = json!({ "running": true, "servers_up": 1, "servers": [{}, {}] });
        assert_eq!(status(ws), "1 of 2 running");
        assert_eq!(status(json!({ "running": true, "paused": true })), "paused");
        assert_eq!(status(json!({ "saved": true })), "saved");
    }
}
