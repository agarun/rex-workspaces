use crate::spec;
use crate::theme::{accent, bold, danger, faint, muted, palette, text};
use crate::widgets::{
    button_row, fill, hint, line, link, Button, Hits, Target, Tone, BUTTON_HEIGHT,
};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::Frame;
use serde_json::{json, Value};

const LABEL_WIDTH: usize = 20;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Browse {
    Root,
    Relative,
}

#[derive(Clone)]
pub enum Act {
    AddServer,
    RemoveServer(usize),
    AddTab,
    RemoveTab(usize),
    AddPane(usize),
    RemovePane(usize, usize),
    Use(usize),
    Suggest,
}

pub enum Kind {
    Header,
    Spacer,
    Text {
        ptr: String,
        placeholder: &'static str,
        browse: Option<Browse>,
        number: bool,
    },
    Toggle {
        ptr: String,
        default: bool,
    },
    Choice {
        ptr: String,
        options: &'static [&'static str],
    },
    Action(Act),
}

pub struct Row {
    pub label: String,
    pub kind: Kind,
    pub hint: &'static str,
    pub tree: String,
    pub side: Option<Act>,
}

impl Row {
    fn new(label: &str, kind: Kind, hint: &'static str) -> Self {
        Self {
            label: label.into(),
            kind,
            hint,
            tree: String::new(),
            side: None,
        }
    }

    fn header(label: &str) -> Self {
        Self::new(label, Kind::Header, "")
    }

    fn spacer() -> Self {
        Self::new("", Kind::Spacer, "")
    }

    fn text(label: &str, ptr: String, placeholder: &'static str, hint: &'static str) -> Self {
        Self::new(
            label,
            Kind::Text {
                ptr,
                placeholder,
                browse: None,
                number: false,
            },
            hint,
        )
    }

    fn folder(label: &str, ptr: String, browse: Browse, placeholder: &'static str) -> Self {
        let hint = "Type a path, or press Ctrl+O to pick a folder";
        Self::new(
            label,
            Kind::Text {
                ptr,
                placeholder,
                browse: Some(browse),
                number: false,
            },
            hint,
        )
    }

    fn toggle(label: &str, ptr: String, default: bool, hint: &'static str) -> Self {
        Self::new(label, Kind::Toggle { ptr, default }, hint)
    }

    fn choice(
        label: &str,
        ptr: String,
        options: &'static [&'static str],
        hint: &'static str,
    ) -> Self {
        Self::new(label, Kind::Choice { ptr, options }, hint)
    }

    fn action(label: &str, act: Act, hint: &'static str) -> Self {
        Self::new(label, Kind::Action(act), hint)
    }

    fn tree(mut self, prefix: &str) -> Self {
        self.tree = prefix.into();
        self
    }

    fn removes(mut self, act: Act) -> Self {
        self.side = Some(act);
        self
    }

    pub fn focusable(&self) -> bool {
        !matches!(self.kind, Kind::Header | Kind::Spacer)
    }

    fn is_text(&self) -> bool {
        matches!(self.kind, Kind::Text { .. })
    }
}

fn branch(last: bool) -> &'static str {
    if last {
        "└─ "
    } else {
        "├─ "
    }
}

fn stem(last: bool) -> &'static str {
    if last {
        "   "
    } else {
        "│  "
    }
}

pub struct Editor {
    pub name: String,
    pub previous: Option<String>,
    pub spec: Value,
    pub focus: usize,
    pub cursor: usize,
    pub scroll: usize,
    pub detected: Vec<Value>,
    pub detecting: bool,
    pub suggesting: bool,
    pub message: Option<(String, bool)>,
    pub fresh: bool,
    pub confirm_remove: bool,
    pub pending: bool,
    pub recording: bool,
}

pub const SHORTCUT: &str = "/key";

impl Editor {
    pub fn new(name: String, previous: Option<String>, spec: Value) -> Self {
        let fresh = previous.is_none();
        let mut editor = Self {
            name,
            previous,
            spec,
            focus: 0,
            cursor: 0,
            scroll: 0,
            detected: Vec::new(),
            detecting: true,
            suggesting: false,
            message: None,
            fresh,
            confirm_remove: false,
            pending: false,
            recording: false,
        };
        editor.focus_row(1);
        editor
    }

    pub fn rows(&self) -> Vec<Row> {
        let s = &self.spec;
        let mut rows = vec![
            Row::header("General"),
            Row::text(
                "Name",
                "#name".into(),
                "",
                "The session's label and the name in the command palette",
            ),
            Row::folder("Folder", "/root".into(), Browse::Root, "~"),
            Row::text(
                "Shortcut",
                SHORTCUT.into(),
                "None. Press Enter, then the keys",
                "Press Enter, then the keys. Or type it, e.g. ctrl+cmd+1",
            ),
            Row::spacer(),
            Row::header("Servers"),
        ];
        for i in 0..spec::len(s, "/servers") {
            let p = format!("/servers/{i}");
            let hint = "Shown on the pane. Ctrl+X removes this server";
            rows.push(
                Row::text("Server", format!("{p}/label"), "Name it", hint)
                    .tree(branch(false))
                    .removes(Act::RemoveServer(i)),
            );
            let t = stem(false);
            rows.push(
                Row::text(
                    "Command",
                    format!("{p}/cmd"),
                    "e.g. pnpm dev",
                    "Typed into the pane's shell",
                )
                .tree(&format!("{t}{}", branch(false))),
            );
            rows.push(
                Row::folder(
                    "Folder",
                    format!("{p}/cwd"),
                    Browse::Relative,
                    "Workspace folder",
                )
                .tree(&format!("{t}{}", branch(false))),
            );
            rows.push(
                Row::toggle(
                    "Minimized",
                    format!("{p}/minimized"),
                    true,
                    "Start the floating pane tucked away",
                )
                .tree(&format!("{t}{}", branch(true))),
            );
        }
        let unused: Vec<(usize, &Value)> = self
            .detected
            .iter()
            .enumerate()
            .filter(|(_, c)| !self.has_cmd(c))
            .collect();
        let listed = if self.suggesting { unused.len() } else { 0 };
        rows.push(
            Row::action(
                "+ Add server",
                Act::AddServer,
                "Stop presses Ctrl+C in every server",
            )
            .tree(branch(false)),
        );
        for (n, (k, c)) in unused.into_iter().take(listed).enumerate() {
            let label = format!("+ {}", field(c, "label"));
            let width = LABEL_WIDTH - branch(false).chars().count();
            let mut row = Row::action(&label, Act::Use(k), "Add this command as a server");
            row.label = format!("{label:<width$}{}", field(c, "cmd"));
            rows.push(row.tree(branch(n + 1 == listed)));
        }
        if listed == 0 {
            rows.push(
                Row::action(
                    "See suggestions",
                    Act::Suggest,
                    "Scripts, make targets and Procfile entries found in this folder",
                )
                .tree(branch(true)),
            );
        }
        rows.push(Row::spacer());
        rows.push(Row::header("Tabs"));
        for t in 0..spec::len(s, "/tabs") {
            let p = format!("/tabs/{t}");
            let hint = "Ctrl+X removes this tab";
            rows.push(
                Row::text("Tab", format!("{p}/name"), "Name it", hint)
                    .tree(branch(false))
                    .removes(Act::RemoveTab(t)),
            );
            let ts = stem(false);
            rows.push(
                Row::choice(
                    "Layout",
                    format!("{p}/split"),
                    &["right", "down"],
                    "Panes side by side, or stacked",
                )
                .tree(&format!("{ts}{}", branch(false))),
            );
            for n in 0..spec::len(s, &format!("{p}/panes")) {
                let q = format!("{p}/panes/{n}");
                rows.push(
                    Row::text(
                        "Pane",
                        format!("{q}/label"),
                        "Name it",
                        "Ctrl+X removes this pane",
                    )
                    .tree(&format!("{ts}{}", branch(false)))
                    .removes(Act::RemovePane(t, n)),
                );
                let ps = format!("{ts}{}", stem(false));
                rows.push(
                    Row::folder(
                        "Folder",
                        format!("{q}/cwd"),
                        Browse::Relative,
                        "Workspace folder",
                    )
                    .tree(&format!("{ps}{}", branch(false))),
                );
                rows.push(
                    Row::text(
                        "Command",
                        format!("{q}/cmd"),
                        "Just a shell",
                        "Typed in when the pane opens",
                    )
                    .tree(&format!("{ps}{}", branch(true))),
                );
            }
            rows.push(
                Row::action("+ Add pane", Act::AddPane(t), "")
                    .tree(&format!("{ts}{}", branch(true))),
            );
        }
        rows.push(
            Row::action(
                "+ Add tab",
                Act::AddTab,
                "With no tabs, one shell opens in the folder",
            )
            .tree(branch(true)),
        );
        rows.push(Row::spacer());
        rows.push(Row::header("Hooks"));
        for (label, key) in [
            ("Before start", "before_start"),
            ("After start", "after_start"),
            ("Before stop", "before_stop"),
            ("After stop", "after_stop"),
        ] {
            rows.push(Row::text(
                label,
                format!("/hooks/{key}"),
                "None",
                "A shell command run in the folder, 20 seconds max",
            ));
        }
        rows.push(Row::spacer());
        rows.push(Row::header("More"));
        rows.push(Row::text(
            "Show tab",
            "/focus".into(),
            "The first tab",
            "Tab to show when the session opens",
        ));
        rows.push(Row::toggle(
            "Switch to it",
            "/switch".into(),
            true,
            "Switch to the session after start",
        ));
        rows.push(Row::choice(
            "Servers in",
            "/servers_in".into(),
            &["float", "tab"],
            "Floating panes, or a tab named servers",
        ));
        rows.push(Row::choice(
            "Stop servers",
            "/stop/servers".into(),
            &["close", "interrupt", "leave"],
            "What Stop does to servers: Ctrl+C and close, Ctrl+C only, or nothing",
        ));
        rows.push(Row::choice(
            "Stop panes",
            "/stop/panes".into(),
            &["leave", "interrupt", "close"],
            "What Stop does to tab panes: nothing, Ctrl+C only, or Ctrl+C and close",
        ));
        rows.push(Row::new(
            "Stop timeout",
            Kind::Text {
                ptr: "/stop_timeout".into(),
                placeholder: "5",
                browse: None,
                number: true,
            },
            "Seconds to wait after Ctrl+C before closing a server anyway",
        ));
        rows
    }

    fn has_cmd(&self, c: &Value) -> bool {
        let (cmd, cwd) = (field(c, "cmd"), field(c, "cwd"));
        self.spec["servers"].as_array().is_some_and(|list| {
            list.iter()
                .any(|s| field(s, "cmd") == cmd && field(s, "cwd") == cwd)
        })
    }

    pub fn value(&self, ptr: &str) -> String {
        if ptr == "#name" {
            return self.name.clone();
        }
        spec::text(&self.spec, ptr)
    }

    pub fn set_text(&mut self, ptr: &str, value: String, number: bool) {
        if ptr == "#name" {
            self.name = value;
            return;
        }
        let v = if value.is_empty() {
            None
        } else if number {
            Some(number_or_text(value))
        } else {
            Some(json!(value))
        };
        spec::set(&mut self.spec, ptr, v);
    }

    fn focused_text(&self) -> Option<(String, bool)> {
        match self.rows().into_iter().nth(self.focus)?.kind {
            Kind::Text { ptr, number, .. } => Some((ptr, number)),
            _ => None,
        }
    }

    pub fn focused_is_text(&self) -> bool {
        self.rows().get(self.focus).is_some_and(Row::is_text)
    }

    pub fn focus_row(&mut self, delta: i32) {
        let rows = self.rows();
        let mut i = self.focus as i32;
        loop {
            i += delta;
            if i < 0 || i >= rows.len() as i32 {
                break;
            }
            if rows[i as usize].focusable() {
                self.focus = i as usize;
                break;
            }
        }
        self.cursor_to_end();
    }

    pub fn focus_at(&mut self, i: usize) {
        self.focus = i;
        self.cursor_to_end();
    }

    fn cursor_to_end(&mut self) {
        self.cursor = self
            .focused_text()
            .map_or(0, |(ptr, _)| self.value(&ptr).chars().count());
    }

    fn edit(&mut self, f: impl FnOnce(&mut Vec<char>, &mut usize)) {
        let Some((ptr, number)) = self.focused_text() else {
            return;
        };
        let mut chars: Vec<char> = self.value(&ptr).chars().collect();
        let mut cursor = self.cursor.min(chars.len());
        f(&mut chars, &mut cursor);
        self.cursor = cursor;
        self.set_text(&ptr, chars.into_iter().collect(), number);
    }

    pub fn type_char(&mut self, c: char) {
        if let Some((_, true)) = self.focused_text() {
            if !(c.is_ascii_digit() || c == '.') {
                return;
            }
        }
        self.edit(|chars, cursor| {
            chars.insert(*cursor, c);
            *cursor += 1;
        });
    }

    pub fn backspace(&mut self) {
        self.edit(|chars, cursor| {
            if *cursor > 0 {
                *cursor -= 1;
                chars.remove(*cursor);
            }
        });
    }

    pub fn delete(&mut self) {
        self.edit(|chars, cursor| {
            if *cursor < chars.len() {
                chars.remove(*cursor);
            }
        });
    }

    pub fn delete_word(&mut self) {
        self.edit(|chars, cursor| {
            let mut start = *cursor;
            while start > 0 && chars[start - 1] == ' ' {
                start -= 1;
            }
            while start > 0 && chars[start - 1] != ' ' && chars[start - 1] != '/' {
                start -= 1;
            }
            chars.drain(start..*cursor);
            *cursor = start;
        });
    }

    pub fn clear(&mut self) {
        self.edit(|chars, cursor| {
            chars.clear();
            *cursor = 0;
        });
    }

    pub fn move_cursor(&mut self, delta: i32) {
        let Some((ptr, _)) = self.focused_text() else {
            if delta != 0 {
                self.cycle(delta);
            }
            return;
        };
        let len = self.value(&ptr).chars().count() as i32;
        self.cursor = (self.cursor as i32 + delta).clamp(0, len) as usize;
    }

    pub fn cursor_home(&mut self) {
        self.cursor = 0;
    }

    pub fn cursor_end(&mut self) {
        self.cursor_to_end();
    }

    fn cycle(&mut self, delta: i32) {
        let rows = self.rows();
        match rows.get(self.focus).map(|r| &r.kind) {
            Some(Kind::Choice { ptr, options }) => {
                let cur = spec::text(&self.spec, ptr);
                let i = options.iter().position(|o| *o == cur).unwrap_or(0) as i32;
                let next = options[(i + delta).rem_euclid(options.len() as i32) as usize];
                spec::set(
                    &mut self.spec,
                    ptr,
                    if next == options[0] {
                        None
                    } else {
                        Some(json!(next))
                    },
                );
            }
            Some(Kind::Toggle { .. }) => {
                self.activate();
            }
            _ => {}
        }
    }

    pub fn activate(&mut self) -> bool {
        let rows = self.rows();
        let Some(row) = rows.get(self.focus) else {
            return false;
        };
        match &row.kind {
            Kind::Toggle { ptr, default } => {
                let on = spec::flag(&self.spec, ptr, *default);
                spec::set(
                    &mut self.spec,
                    ptr,
                    if !on == *default {
                        None
                    } else {
                        Some(json!(!on))
                    },
                );
            }
            Kind::Choice { .. } => self.cycle(1),
            Kind::Action(act) => self.run(act.clone()),
            Kind::Text {
                browse: Some(_), ..
            } => return true,
            Kind::Text { ptr, .. } if ptr == SHORTCUT => self.recording = true,
            Kind::Text { .. } => self.focus_row(1),
            Kind::Header | Kind::Spacer => {}
        }
        false
    }

    pub fn on_shortcut(&self) -> bool {
        matches!(
            self.rows().get(self.focus).map(|r| &r.kind),
            Some(Kind::Text { ptr, .. }) if ptr == SHORTCUT
        )
    }

    pub fn record(&mut self, k: KeyEvent) {
        if k.code == KeyCode::Esc {
            self.recording = false;
            return;
        }
        match shortcut(k) {
            Some(text) => {
                self.recording = false;
                self.set_text(SHORTCUT, text, false);
                self.cursor_end();
            }
            None if is_modifier(k.code) => {}
            None => self.message = Some(("Hold Ctrl, Alt or Cmd with the key".into(), true)),
        }
    }

    pub fn browse_target(&self) -> Option<(String, Browse)> {
        match self.rows().get(self.focus).map(|r| &r.kind) {
            Some(Kind::Text {
                ptr,
                browse: Some(b),
                ..
            }) => Some((ptr.clone(), *b)),
            _ => None,
        }
    }

    pub fn side(&mut self, i: usize) {
        if let Some(act) = self.rows().get(i).and_then(|r| r.side.clone()) {
            self.run(act);
        }
    }

    pub fn remove_focused(&mut self) {
        self.side(self.focus);
    }

    fn unique_label(&self, base: &str) -> String {
        let taken = |l: &str| {
            self.spec["servers"]
                .as_array()
                .is_some_and(|s| s.iter().any(|x| field(x, "label") == l))
        };
        let mut label = base.to_string();
        let mut n = 2;
        while taken(&label) {
            label = format!("{base} {n}");
            n += 1;
        }
        label
    }

    pub fn explain_suggestions(&mut self) {
        if self.detecting {
            self.message = Some(("Still looking in this folder…".into(), false));
        } else if self.detected.iter().all(|c| self.has_cmd(c)) {
            self.message = Some(("No other commands found in this folder".into(), false));
        } else {
            self.message = None;
        }
    }

    fn run(&mut self, act: Act) {
        match act {
            Act::AddServer => {
                let label = self.unique_label("server");
                spec::list(&mut self.spec, "/servers").push(json!({ "label": label, "cmd": "" }));
            }
            Act::RemoveServer(i) => {
                spec::list(&mut self.spec, "/servers").remove(i);
            }
            Act::AddTab => {
                let n = spec::len(&self.spec, "/tabs") + 1;
                let name = if n == 1 {
                    "main".to_string()
                } else {
                    format!("tab {n}")
                };
                spec::list(&mut self.spec, "/tabs")
                    .push(json!({ "name": name, "panes": [{ "label": "shell" }] }));
            }
            Act::RemoveTab(t) => {
                spec::list(&mut self.spec, "/tabs").remove(t);
            }
            Act::AddPane(t) => {
                let ptr = format!("/tabs/{t}/panes");
                let n = spec::len(&self.spec, &ptr) + 1;
                spec::list(&mut self.spec, &ptr).push(json!({ "label": format!("pane {n}") }));
            }
            Act::RemovePane(t, n) => {
                spec::list(&mut self.spec, &format!("/tabs/{t}/panes")).remove(n);
            }
            Act::Use(k) => {
                let Some(c) = self.detected.get(k).cloned() else {
                    return;
                };
                let label = self.unique_label(&field(&c, "label"));
                let mut server = json!({ "label": label, "cmd": field(&c, "cmd") });
                if !field(&c, "cwd").is_empty() {
                    server["cwd"] = json!(field(&c, "cwd"));
                }
                spec::list(&mut self.spec, "/servers").push(server);
            }
            Act::Suggest => {
                self.suggesting = true;
                self.explain_suggestions();
            }
        }
        let rows = self.rows();
        self.focus = self.focus.min(rows.len().saturating_sub(1));
        if !rows[self.focus].focusable() {
            self.focus_row(-1);
        }
        self.cursor_to_end();
    }

    pub fn buttons(&self) -> Vec<(&'static str, Button)> {
        let remove = if self.confirm_remove {
            "Really remove?"
        } else {
            "Remove"
        };
        let mut out = vec![
            ("save", Button::new("Save", "ctrl+s", Tone::Primary)),
            ("cancel", Button::new("Cancel", "esc", Tone::Normal)),
        ];
        if self.browse_target().is_some() {
            out.push(("browse", Button::new("Browse", "ctrl+o", Tone::Normal)));
        }
        if self.previous.is_some() {
            out.push(("remove", Button::new(remove, "", Tone::Danger)));
        }
        out
    }

    pub fn render(&mut self, f: &mut Frame, area: Rect, hits: &mut Hits, hover: Option<Target>) {
        let rows = self.rows();
        let body = Rect::new(
            area.x,
            area.y,
            area.width,
            area.height.saturating_sub(BUTTON_HEIGHT + 4),
        );
        let height = body.height as usize;
        if self.focus < self.scroll {
            self.scroll = self.focus.saturating_sub(1);
        } else if height > 0 && self.focus >= self.scroll + height {
            self.scroll = self.focus + 1 - height;
        }
        for (n, i) in (self.scroll..rows.len()).take(height).enumerate() {
            let rect = Rect::new(body.x, body.y + n as u16, body.width, 1);
            self.draw_row(f, rect, &rows[i], i, hits, hover);
        }
        if self.scroll + height < rows.len() {
            let more = Rect::new(body.x, body.y + body.height, body.width, 1);
            line(f, more, 0, Line::styled("  ↓ More below", faint()));
        }

        let bar = Rect::new(
            area.x,
            area.y + area.height.saturating_sub(BUTTON_HEIGHT),
            area.width,
            BUTTON_HEIGHT,
        );
        let buttons: Vec<Button> = self.buttons().into_iter().map(|(_, b)| b).collect();
        button_row(f, bar, &buttons, hits, hover, None);

        let footer = Rect::new(area.x, bar.y.saturating_sub(2), area.width, 1);
        let content = match &self.message {
            Some((m, true)) => Line::styled(m.clone(), danger()),
            Some((m, false)) => Line::styled(m.clone(), muted()),
            None => {
                let row_hint = rows
                    .get(self.focus)
                    .map(|r| r.hint)
                    .filter(|h| !h.is_empty());
                hint(&row_hint.map_or(
                    "[↑↓] Move · [Enter] Toggle · [Tab] Next".to_string(),
                    |h| h.to_string(),
                ))
            }
        };
        line(f, footer, 0, content);
    }

    fn draw_row(
        &self,
        f: &mut Frame,
        rect: Rect,
        row: &Row,
        i: usize,
        hits: &mut Hits,
        hover: Option<Target>,
    ) {
        let p = palette();
        let focused = i == self.focus;
        let hovered = hover == Some(Target::Row(i));
        if let Kind::Header = row.kind {
            let title = row.label.clone();
            let rule = "─".repeat((rect.width as usize).saturating_sub(title.chars().count() + 2));
            line(
                f,
                rect,
                0,
                Line::from(vec![
                    Span::styled(title, bold()),
                    Span::raw(" "),
                    Span::styled(rule, Style::new().fg(p.border)),
                ]),
            );
            return;
        }
        if let Kind::Spacer = row.kind {
            return;
        }
        if focused {
            fill(f, rect, p.selected);
        } else if hovered {
            fill(f, rect, p.hover);
        }
        hits.add(rect, Target::Row(i));

        let bar = if focused {
            Span::styled("▍", accent())
        } else {
            Span::raw(" ")
        };
        let mut spans = vec![
            bar,
            Span::raw(" "),
            Span::styled(row.tree.clone(), Style::new().fg(p.border)),
        ];
        let label_width = LABEL_WIDTH.saturating_sub(row.tree.chars().count());
        let label_style = if focused {
            accent().add_modifier(Modifier::BOLD)
        } else {
            muted()
        };
        let side_room = if row.side.is_some()
            || matches!(
                row.kind,
                Kind::Text {
                    browse: Some(_),
                    ..
                }
            ) {
            10
        } else {
            2
        };
        let room = (rect.width as usize).saturating_sub(LABEL_WIDTH + 2 + side_room);

        match &row.kind {
            Kind::Text {
                ptr, placeholder, ..
            } => {
                spans.push(Span::styled(
                    format!("{:<label_width$}", row.label),
                    label_style,
                ));
                let value = self.value(ptr);
                if focused && self.recording {
                    spans.push(Span::styled(
                        "Press the shortcut now. Esc cancels",
                        accent().add_modifier(Modifier::ITALIC),
                    ));
                } else if focused {
                    spans.extend(cursor_spans(&value, self.cursor, room));
                } else if value.is_empty() {
                    spans.push(Span::styled(
                        placeholder.to_string(),
                        faint().add_modifier(Modifier::ITALIC),
                    ));
                } else {
                    spans.push(Span::styled(shorten(&value, room), text()));
                }
            }
            Kind::Toggle { ptr, default } => {
                spans.push(Span::styled(
                    format!("{:<label_width$}", row.label),
                    label_style,
                ));
                let on = spec::flag(&self.spec, ptr, *default);
                spans.extend(segments(&["On", "Off"], if on { 0 } else { 1 }));
            }
            Kind::Choice { ptr, options } => {
                spans.push(Span::styled(
                    format!("{:<label_width$}", row.label),
                    label_style,
                ));
                let cur = spec::text(&self.spec, ptr);
                let selected = options.iter().position(|o| *o == cur).unwrap_or(0);
                let names: Vec<String> = options.iter().map(|o| capitalize(o)).collect();
                let names: Vec<&str> = names.iter().map(String::as_str).collect();
                spans.extend(segments(&names, selected));
            }
            Kind::Action(_) => {
                let mut style = accent().add_modifier(Modifier::BOLD);
                if focused || hovered {
                    style = style.add_modifier(Modifier::UNDERLINED);
                }
                spans.push(Span::styled(row.label.clone(), style));
            }
            Kind::Header | Kind::Spacer => {}
        }
        f.render_widget(ratatui::widgets::Paragraph::new(Line::from(spans)), rect);

        let side = match (&row.kind, &row.side) {
            (
                Kind::Text {
                    browse: Some(_), ..
                },
                _,
            ) => Some(("Browse", Target::Browse(i), p.accent)),
            (_, Some(_)) => Some(("Remove", Target::Side(i), p.danger)),
            _ => None,
        };
        if let Some((label, target, color)) = side {
            let w = label.len() as u16;
            let tag = Rect::new(rect.x + rect.width.saturating_sub(w + 1), rect.y, w, 1);
            let shown = if focused || hover == Some(target) {
                color
            } else {
                p.faint
            };
            link(f, tag, label, shown, hover == Some(target));
            hits.add(tag, target);
        }
    }
}

fn segments(options: &[&str], selected: usize) -> Vec<Span<'static>> {
    let p = palette();
    let mut spans = Vec::new();
    for (i, o) in options.iter().enumerate() {
        let style = if i == selected {
            Style::new()
                .fg(p.on_accent)
                .bg(p.accent)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(p.muted).bg(p.hover)
        };
        spans.push(Span::styled(format!(" {o} "), style));
    }
    spans
}

fn cursor_spans(value: &str, cursor: usize, room: usize) -> Vec<Span<'static>> {
    let p = palette();
    let chars: Vec<char> = value.chars().collect();
    let cursor = cursor.min(chars.len());
    let room = room.max(4);
    let start = (cursor + 1).saturating_sub(room);
    let end = (start + room).min(chars.len());
    let before: String = chars[start..cursor].iter().collect();
    let at = chars.get(cursor).map_or(" ".to_string(), |c| c.to_string());
    let after: String = if cursor < end {
        chars[cursor + 1..end].iter().collect()
    } else {
        String::new()
    };
    let mut spans = Vec::new();
    if start > 0 {
        spans.push(Span::styled("…", faint()));
    }
    spans.push(Span::styled(before, text()));
    spans.push(Span::styled(at, Style::new().fg(p.on_accent).bg(p.accent)));
    spans.push(Span::styled(after, text()));
    spans
}

fn capitalize(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or(String::new(), |first| {
        first.to_uppercase().chain(c).collect()
    })
}

fn shorten(s: &str, room: usize) -> String {
    let count = s.chars().count();
    if count <= room || room < 2 {
        return s.to_string();
    }
    let tail: String = s.chars().skip(count - (room - 1)).collect();
    format!("…{tail}")
}

fn field(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn is_modifier(code: KeyCode) -> bool {
    matches!(code, KeyCode::Modifier(_))
}

pub fn shortcut(k: KeyEvent) -> Option<String> {
    let m = k.modifiers;
    let held = [
        (KeyModifiers::CONTROL, "ctrl"),
        (KeyModifiers::ALT, "alt"),
        (KeyModifiers::SHIFT, "shift"),
        (KeyModifiers::SUPER, "cmd"),
    ];
    if !m.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER) {
        return None;
    }
    let key = match k.code {
        KeyCode::Char(' ') => "space".to_string(),
        KeyCode::Char(c) => c.to_lowercase().to_string(),
        KeyCode::F(n) => format!("f{n}"),
        KeyCode::Up => "up".into(),
        KeyCode::Down => "down".into(),
        KeyCode::Left => "left".into(),
        KeyCode::Right => "right".into(),
        KeyCode::Enter => "enter".into(),
        KeyCode::Tab | KeyCode::BackTab => "tab".into(),
        KeyCode::Backspace => "backspace".into(),
        KeyCode::Delete => "delete".into(),
        KeyCode::Home => "home".into(),
        KeyCode::End => "end".into(),
        KeyCode::PageUp => "pageup".into(),
        KeyCode::PageDown => "pagedown".into(),
        _ => return None,
    };
    let mut parts: Vec<String> = held
        .iter()
        .filter(|(flag, _)| m.contains(*flag))
        .map(|(_, name)| name.to_string())
        .collect();
    parts.push(key);
    Some(parts.join("+"))
}

fn number_or_text(value: String) -> Value {
    if let Ok(n) = value.parse::<u64>() {
        return json!(n);
    }
    match value.parse::<f64>() {
        Ok(n) if !value.ends_with('.') => json!(n),
        _ => json!(value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(code: KeyCode, m: KeyModifiers) -> Option<String> {
        shortcut(KeyEvent::new(code, m))
    }

    #[test]
    fn shortcuts_use_rex_spelling() {
        let ctrl_cmd = KeyModifiers::CONTROL | KeyModifiers::SUPER;
        assert_eq!(
            press(KeyCode::Char('1'), ctrl_cmd).as_deref(),
            Some("ctrl+cmd+1")
        );
        let shift_cmd = KeyModifiers::SHIFT | KeyModifiers::SUPER;
        assert_eq!(
            press(KeyCode::Char('M'), shift_cmd).as_deref(),
            Some("shift+cmd+m")
        );
        assert_eq!(
            press(KeyCode::Up, KeyModifiers::ALT).as_deref(),
            Some("alt+up")
        );
    }

    #[test]
    fn shortcuts_need_a_real_modifier() {
        assert_eq!(press(KeyCode::Char('a'), KeyModifiers::NONE), None);
        assert_eq!(press(KeyCode::Char('A'), KeyModifiers::SHIFT), None);
    }
}
