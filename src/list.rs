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

fn state(ws: &Value) -> (Span<'static>, String) {
    let p = palette();
    let total = servers(ws).len();
    let up = ws["servers_up"].as_u64().unwrap_or(0) as usize;
    if !running(ws) {
        return (Span::styled("○", faint()), "stopped".into());
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

pub fn buttons(selected: Option<&Value>, any: bool) -> Vec<(&'static str, Button)> {
    let open = selected.is_some_and(running);
    let has_servers = selected.is_some_and(|w| !servers(w).is_empty());
    let up = selected.map_or(0, |w| w["servers_up"].as_u64().unwrap_or(0));
    let only_panes = !has_servers && selected.is_some_and(|w| w["stops_panes"] == true);
    let (serve, serve_label) = if open && (up > 0 || only_panes) {
        ("stop", "Stop")
    } else {
        ("start", "Start")
    };
    vec![
        (
            "open",
            Button::new("Open", "enter", Tone::Primary).enabled(selected.is_some()),
        ),
        (
            serve,
            Button::new(serve_label, "s", Tone::Normal)
                .enabled(has_servers || (open && only_panes)),
        ),
        (
            "restart",
            Button::new("Restart", "r", Tone::Normal).enabled(open && has_servers),
        ),
        (
            "close",
            Button::new("Close", "c", Tone::Danger).enabled(open),
        ),
        (
            "edit",
            Button::new("Edit", "e", Tone::Normal).enabled(selected.is_some()),
        ),
        ("new", Button::new("New", "n", Tone::Normal)),
        ("capture", Button::new("Save as new", "w", Tone::Normal)),
        (
            "filter",
            Button::new("Filter", "/", Tone::Normal).enabled(any),
        ),
    ]
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
    let actions = buttons(current, !view.workspaces.is_empty());
    if view.loaded && view.workspaces.is_empty() {
        first_workspace(f, area, &actions, hits, hover, view.button_focus);
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
    let room = (area.y + area.height).saturating_sub(top + bar_height + 2);
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
    if let Some(status) = view.status {
        let rect = Rect::new(area.x, bar_area.y.saturating_sub(2), area.width, 1);
        line(f, rect, 0, status);
    }
}

fn first_workspace(
    f: &mut Frame,
    area: Rect,
    actions: &[(&'static str, Button)],
    hits: &mut Hits,
    hover: Option<Target>,
    focus: Option<usize>,
) {
    let Some(i) = actions.iter().position(|(a, _)| *a == "new") else {
        return;
    };
    let lead = "Add your first workspace  →  ";
    let y = area.y + area.height.saturating_sub(BUTTON_HEIGHT);
    let x = area.x + lead.chars().count() as u16;
    let b = &actions[i].1;
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
    let hovered = hover == Some(Target::Button(i));
    draw_button(f, rect, b, hovered, focus.map(|n| n == i));
    hits.add(rect, Target::Button(i));
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn save_as_new_follows_new() {
        let labels: Vec<String> = buttons(None, true)
            .into_iter()
            .map(|(_, b)| b.label)
            .collect();
        assert_eq!(
            labels,
            [
                "Open",
                "Start",
                "Restart",
                "Close",
                "Edit",
                "New",
                "Save as new",
                "Filter"
            ]
        );
    }

    fn serve(ws: Value) -> (&'static str, bool) {
        let b = buttons(Some(&ws), true);
        (b[1].0, b[1].1.enabled)
    }

    #[test]
    fn stop_toggle_follows_servers_then_panes() {
        let servers = json!([{ "label": "web" }]);
        let up = json!({ "running": true, "servers_up": 1, "servers": servers });
        assert_eq!(serve(up), ("stop", true));
        let idle = json!({ "running": true, "servers_up": 0, "servers": servers });
        assert_eq!(serve(idle), ("start", true));
        let panes = json!({ "running": true, "stops_panes": true });
        assert_eq!(serve(panes), ("stop", true));
        assert_eq!(serve(json!({ "stops_panes": true })), ("start", false));
        assert_eq!(serve(json!({ "running": true })), ("start", false));
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
    }
}
