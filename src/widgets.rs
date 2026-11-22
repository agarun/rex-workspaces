use crate::theme::{faint, muted, palette};
use ratatui::layout::Rect;
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Paragraph};
use ratatui::Frame;

pub const BUTTON_HEIGHT: u16 = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target {
    Row(usize),
    Button(usize),
    PickerRow(usize),
    Browse(usize),
    Side(usize),
}

#[derive(Default)]
pub struct Hits(Vec<(Rect, Target)>);

impl Hits {
    pub fn clear(&mut self) {
        self.0.clear();
    }

    pub fn add(&mut self, area: Rect, target: Target) {
        self.0.push((area, target));
    }

    pub fn at(&self, x: u16, y: u16) -> Option<Target> {
        self.0
            .iter()
            .rev()
            .find(|(r, _)| x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
            .map(|(_, t)| *t)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Primary,
    Normal,
    Danger,
}

pub struct Button {
    pub label: String,
    pub key: &'static str,
    pub tone: Tone,
    pub enabled: bool,
}

impl Button {
    pub fn new(label: &str, key: &'static str, tone: Tone) -> Self {
        Self {
            label: label.into(),
            key,
            tone,
            enabled: true,
        }
    }

    pub fn enabled(mut self, on: bool) -> Self {
        self.enabled = on;
        self
    }

    pub fn width(&self) -> u16 {
        let key = if self.key.is_empty() {
            0
        } else {
            self.key.chars().count() + 2
        };
        (self.label.chars().count() + key + 2) as u16
    }
}

pub fn draw_button(f: &mut Frame, rect: Rect, b: &Button, hovered: bool, focus: Option<bool>) {
    let p = palette();
    let grey = if hovered { p.button_active } else { p.button };
    let (bg, label, key) = match (b.enabled, b.tone, focus) {
        (false, _, _) => (p.button, p.faint, p.border),
        (true, Tone::Danger, Some(true)) => (p.danger, p.on_accent, p.on_accent_dim),
        (true, _, Some(true)) => (p.accent, p.on_accent, p.on_accent_dim),
        (true, Tone::Primary, None) => (
            if hovered { p.accent_active } else { p.accent },
            p.on_accent,
            p.on_accent_dim,
        ),
        (true, Tone::Danger, _) => (grey, p.danger, p.key),
        (true, _, _) => (grey, p.text, p.key),
    };
    fill(f, rect, bg);
    let mut spans = vec![Span::styled(
        b.label.clone(),
        Style::new().fg(label).add_modifier(Modifier::BOLD),
    )];
    if !b.key.is_empty() {
        spans.push(Span::styled(format!("  {}", b.key), Style::new().fg(key)));
    }
    let inner = Rect::new(rect.x + 1, rect.y, rect.width.saturating_sub(1), 1);
    f.render_widget(Paragraph::new(Line::from(spans)), clip(f, inner));
}

pub fn button_rows(area: Rect, buttons: &[Button]) -> u16 {
    place(area, buttons)
        .last()
        .map_or(0, |r| r.y + r.height - area.y)
}

fn place(area: Rect, buttons: &[Button]) -> Vec<Rect> {
    let (mut x, mut y) = (area.x, area.y);
    let mut out = Vec::new();
    for b in buttons {
        let w = b.width().min(area.width);
        if x > area.x && x + w > area.x + area.width {
            x = area.x;
            y += BUTTON_HEIGHT + 1;
        }
        out.push(Rect::new(x, y, w, BUTTON_HEIGHT));
        x += w + 2;
    }
    out
}

pub fn button_row(
    f: &mut Frame,
    area: Rect,
    buttons: &[Button],
    hits: &mut Hits,
    hover: Option<Target>,
    focus: Option<usize>,
) {
    let bottom = area.y + area.height;
    for (i, (b, rect)) in buttons.iter().zip(place(area, buttons)).enumerate() {
        if rect.y + rect.height > bottom {
            break;
        }
        let hovered = hover == Some(Target::Button(i));
        draw_button(f, rect, b, hovered, focus.map(|n| n == i));
        if b.enabled {
            hits.add(rect, Target::Button(i));
        }
    }
}

pub fn fill(f: &mut Frame, rect: Rect, bg: Color) {
    f.render_widget(Block::new().style(Style::new().bg(bg)), clip(f, rect));
}

pub fn line(f: &mut Frame, area: Rect, y: u16, content: Line) -> Option<Rect> {
    if y >= area.height {
        return None;
    }
    let rect = Rect::new(area.x, area.y + y, area.width, 1);
    f.render_widget(Paragraph::new(content), clip(f, rect));
    Some(rect)
}

pub fn link(f: &mut Frame, rect: Rect, label: &str, color: Color, hovered: bool) {
    let style = if hovered {
        Style::new()
            .fg(color)
            .add_modifier(Modifier::UNDERLINED | Modifier::BOLD)
    } else {
        Style::new().fg(color)
    };
    f.render_widget(
        Paragraph::new(Span::styled(label.to_string(), style)),
        clip(f, rect),
    );
}

pub fn hint(text: &str) -> Line<'static> {
    let mut spans = Vec::new();
    for (i, part) in text.split(" · ").enumerate() {
        if i > 0 {
            spans.push(Span::styled("  ·  ", faint()));
        }
        match part.split_once(' ') {
            Some((key, rest)) if part.starts_with('[') => {
                spans.push(Span::styled(
                    key.trim_matches(|c| c == '[' || c == ']').to_string(),
                    muted().add_modifier(Modifier::BOLD),
                ));
                spans.push(Span::styled(format!(" {rest}"), faint()));
            }
            _ => spans.push(Span::styled(part.to_string(), muted())),
        }
    }
    Line::from(spans)
}

pub fn clip(f: &Frame, rect: Rect) -> Rect {
    rect.intersection(f.area())
}

pub fn padded(area: Rect) -> Rect {
    let x = 2.min(area.width);
    let y = 1.min(area.height);
    Rect::new(
        area.x + x,
        area.y + y,
        area.width.saturating_sub(x * 2),
        area.height.saturating_sub(y * 2),
    )
}
