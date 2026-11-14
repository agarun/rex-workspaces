use crate::theme::{accent, bold, faint, muted, palette, text};
use crate::widgets::{
    button_row, fill, hint, line, padded, Button, Hits, Target, Tone, BUTTON_HEIGHT,
};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Clear};
use ratatui::Frame;
use std::path::PathBuf;

pub const BUTTONS: [&str; 3] = ["use", "up", "cancel"];

pub struct Picker {
    pub dir: PathBuf,
    pub entries: Vec<String>,
    pub selected: usize,
    pub ptr: String,
    pub relative_to: Option<PathBuf>,
}

impl Picker {
    pub fn open(start: PathBuf, ptr: String, relative_to: Option<PathBuf>) -> Self {
        let dir = if start.is_dir() {
            start
        } else {
            relative_to.clone().unwrap_or_else(|| PathBuf::from("/"))
        };
        let mut picker = Self {
            dir,
            entries: Vec::new(),
            selected: 0,
            ptr,
            relative_to,
        };
        picker.load();
        picker
    }

    fn load(&mut self) {
        let mut dirs: Vec<String> = std::fs::read_dir(&self.dir)
            .map(|it| {
                it.filter_map(Result::ok)
                    .filter(|e| e.path().is_dir())
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| !n.starts_with('.'))
                    .collect()
            })
            .unwrap_or_default();
        dirs.sort_by_key(|d| d.to_lowercase());
        if self.dir.parent().is_some() {
            dirs.insert(0, "..".into());
        }
        self.entries = dirs;
        self.selected = 0;
    }

    pub fn up(&mut self) {
        if let Some(parent) = self.dir.parent() {
            self.dir = parent.to_path_buf();
            self.load();
        }
    }

    pub fn enter(&mut self, i: usize) {
        match self.entries.get(i).map(String::as_str) {
            Some("..") => self.up(),
            Some(name) => {
                self.dir.push(name);
                self.load();
            }
            None => {}
        }
    }

    pub fn move_by(&mut self, delta: i32) {
        let last = self.entries.len().saturating_sub(1) as i32;
        self.selected = (self.selected as i32 + delta).clamp(0, last) as usize;
    }

    pub fn value(&self, home: &str) -> Option<String> {
        if let Some(root) = &self.relative_to {
            if let Ok(rel) = self.dir.strip_prefix(root) {
                let rel = rel.to_string_lossy().into_owned();
                return if rel.is_empty() { None } else { Some(rel) };
            }
        }
        Some(crate::spec::contract(&self.dir.to_string_lossy(), home))
    }

    pub fn render(&self, f: &mut Frame, hits: &mut Hits, hover: Option<Target>, home: &str) {
        let p = palette();
        let full = f.area();
        let width = full.width.saturating_sub(8).min(72);
        let height = full.height.saturating_sub(4).min(26);
        let area = Rect::new(
            full.x + (full.width - width) / 2,
            full.y + (full.height - height) / 2,
            width,
            height,
        );
        f.render_widget(Clear, area);
        let block = Block::bordered()
            .border_type(BorderType::Rounded)
            .border_style(Style::new().fg(p.accent))
            .title(Line::from(Span::styled(" Choose a folder ", bold())));
        let inner = padded(block.inner(area));
        f.render_widget(block, area);
        hits.clear();

        let shown = crate::spec::contract(&self.dir.to_string_lossy(), home);
        line(
            f,
            inner,
            0,
            Line::from(vec![
                Span::styled("In  ", muted()),
                Span::styled(shown, bold()),
            ]),
        );
        let rows = inner.height.saturating_sub(BUTTON_HEIGHT + 4) as usize;
        let start = self.selected.saturating_sub(rows.saturating_sub(1));
        for (n, i) in (start..self.entries.len()).take(rows).enumerate() {
            let rect = Rect::new(inner.x, inner.y + 2 + n as u16, inner.width, 1);
            let selected = i == self.selected;
            if selected {
                fill(f, rect, p.selected);
            } else if hover == Some(Target::PickerRow(i)) {
                fill(f, rect, p.hover);
            }
            let name = &self.entries[i];
            let bar = if selected {
                Span::styled("▍", accent())
            } else {
                Span::raw(" ")
            };
            let content = if name == ".." {
                Line::from(vec![bar, Span::styled(" ↑  Up one folder", muted())])
            } else {
                let style = if selected {
                    accent().add_modifier(Modifier::BOLD)
                } else {
                    text()
                };
                Line::from(vec![
                    bar,
                    Span::styled(" ▸  ", faint()),
                    Span::styled(format!("{name}/"), style),
                ])
            };
            line(f, rect, 0, content);
            hits.add(rect, Target::PickerRow(i));
        }
        if self.entries.is_empty() {
            line(f, inner, 2, Line::styled("No folders here", muted()));
        }
        let bar = Rect::new(
            inner.x,
            inner.y + inner.height.saturating_sub(BUTTON_HEIGHT + 1),
            inner.width,
            BUTTON_HEIGHT,
        );
        let buttons = [
            Button::new("Use this folder", "space", Tone::Primary),
            Button::new("Up", "backspace", Tone::Normal),
            Button::new("Cancel", "esc", Tone::Normal),
        ];
        button_row(f, bar, &buttons, hits, hover, None);
        let footer = Rect::new(
            inner.x,
            inner.y + inner.height.saturating_sub(1),
            inner.width,
            1,
        );
        line(
            f,
            footer,
            0,
            hint("[Enter] Open · [Space] Use · [Backspace] Up · [Esc] Cancel"),
        );
    }
}
