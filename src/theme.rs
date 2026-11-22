use crate::cache;
use ratatui::style::{Color, Modifier, Style};
use serde_json::{json, Value};
use std::io::Write;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

const CACHE_FILE: &str = "theme.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Rgb(u8, u8, u8);

impl Rgb {
    fn mix(self, other: Rgb, t: f32) -> Rgb {
        let m = |a: u8, b: u8| (a as f32 + (b as f32 - a as f32) * t).round() as u8;
        Rgb(m(self.0, other.0), m(self.1, other.1), m(self.2, other.2))
    }

    fn color(self) -> Color {
        Color::Rgb(self.0, self.1, self.2)
    }

    fn luminance(self) -> f32 {
        (0.299 * self.0 as f32 + 0.587 * self.1 as f32 + 0.114 * self.2 as f32) / 255.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Theme {
    bg: Rgb,
    fg: Rgb,
    dark: bool,
    supported: bool,
}

impl Theme {
    fn from_reply(reply: &str, supported: bool) -> Self {
        let bg = parse_color(reply, "11");
        let fg = parse_color(reply, "10");
        let dark = if reply.contains("?997;2n") {
            false
        } else if reply.contains("?997;1n") {
            true
        } else {
            bg.is_none_or(|c| c.luminance() < 0.5)
        };
        let bg = bg.unwrap_or(if dark {
            Rgb(30, 30, 30)
        } else {
            Rgb(250, 250, 250)
        });
        let fg = fg.unwrap_or(if dark {
            Rgb(212, 212, 212)
        } else {
            Rgb(56, 58, 66)
        });
        Self {
            bg,
            fg,
            dark,
            supported,
        }
    }

    fn to_value(self) -> Value {
        json!({
            "bg": [self.bg.0, self.bg.1, self.bg.2],
            "fg": [self.fg.0, self.fg.1, self.fg.2],
            "dark": self.dark,
            "supported": self.supported,
        })
    }

    fn from_value(v: &Value) -> Option<Self> {
        let rgb = |key: &str| {
            let a = v[key].as_array()?;
            if a.len() != 3 {
                return None;
            }
            Some(Rgb(
                u8::try_from(a[0].as_u64()?).ok()?,
                u8::try_from(a[1].as_u64()?).ok()?,
                u8::try_from(a[2].as_u64()?).ok()?,
            ))
        };
        Some(Self {
            bg: rgb("bg")?,
            fg: rgb("fg")?,
            dark: v["dark"].as_bool()?,
            supported: v["supported"].as_bool().unwrap_or(true),
        })
    }
}

pub struct Palette {
    pub text: Color,
    pub muted: Color,
    pub faint: Color,
    pub border: Color,
    pub hover: Color,
    pub selected: Color,
    pub button: Color,
    pub button_active: Color,
    pub key: Color,
    pub accent: Color,
    pub accent_active: Color,
    pub on_accent: Color,
    pub on_accent_dim: Color,
    pub danger: Color,
    pub success: Color,
    pub warning: Color,
}

static PALETTE: OnceLock<Palette> = OnceLock::new();

fn build(bg: Rgb, fg: Rgb, dark: bool) -> Palette {
    let accent = if dark {
        Rgb(88, 150, 255)
    } else {
        Rgb(37, 99, 235)
    };
    let white = Rgb(255, 255, 255);
    Palette {
        text: fg.color(),
        muted: fg.mix(bg, 0.35).color(),
        faint: fg.mix(bg, 0.55).color(),
        border: fg.mix(bg, 0.75).color(),
        hover: fg.mix(bg, 0.93).color(),
        selected: accent.mix(bg, if dark { 0.78 } else { 0.88 }).color(),
        button: fg.mix(bg, if dark { 0.88 } else { 0.92 }).color(),
        button_active: fg.mix(bg, if dark { 0.78 } else { 0.84 }).color(),
        key: fg.mix(bg, 0.6).color(),
        accent: accent.color(),
        accent_active: accent.mix(fg, 0.2).color(),
        on_accent: white.color(),
        on_accent_dim: white.mix(accent, 0.4).color(),
        danger: if dark {
            Rgb(255, 110, 110)
        } else {
            Rgb(200, 40, 40)
        }
        .color(),
        success: if dark {
            Rgb(70, 190, 100)
        } else {
            Rgb(22, 140, 60)
        }
        .color(),
        warning: if dark {
            Rgb(230, 180, 60)
        } else {
            Rgb(180, 120, 0)
        }
        .color(),
    }
}

pub fn palette() -> &'static Palette {
    PALETTE.get_or_init(|| build(Rgb(30, 30, 30), Rgb(212, 212, 212), true))
}

fn hex4(s: &str) -> Option<u8> {
    u8::from_str_radix(s.get(..2)?, 16).ok()
}

fn parse_color(reply: &str, code: &str) -> Option<Rgb> {
    let start = reply.find(&format!("]{code};rgb:"))? + code.len() + 6;
    let mut parts = reply[start..].split(['/', '\x1b', '\x07']);
    Some(Rgb(
        hex4(parts.next()?)?,
        hex4(parts.next()?)?,
        hex4(parts.next()?)?,
    ))
}

fn device_attributes_seen(buf: &[u8]) -> bool {
    let text = String::from_utf8_lossy(buf);
    text.match_indices("\x1b[?").any(|(i, _)| {
        text[i + 3..]
            .chars()
            .find(|c| !(c.is_ascii_digit() || *c == ';'))
            == Some('c')
    })
}

fn query(timeout: Duration) -> (String, bool) {
    use std::os::fd::AsRawFd;
    let mut out = std::io::stdout();
    if out
        .write_all(b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[?996n\x1b[c")
        .and_then(|_| out.flush())
        .is_err()
    {
        return (String::new(), false);
    }
    let fd = std::io::stdin().as_raw_fd();
    let started = Instant::now();
    let mut buf = Vec::new();
    while !device_attributes_seen(&buf) {
        let Some(remaining) = timeout.checked_sub(started.elapsed()) else {
            break;
        };
        let wait = remaining.as_millis().clamp(1, 50) as i32;
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        if unsafe { libc::poll(&mut pfd, 1, wait) } <= 0 {
            continue;
        }
        let mut chunk = [0u8; 256];
        let n = unsafe { libc::read(fd, chunk.as_mut_ptr().cast(), chunk.len()) };
        if n > 0 {
            buf.extend_from_slice(&chunk[..n as usize]);
        }
    }
    let supported = device_attributes_seen(&buf);
    (String::from_utf8_lossy(&buf).into_owned(), supported)
}

pub fn init() -> bool {
    if let Some(theme) = cache::load(CACHE_FILE).and_then(|v| Theme::from_value(&v)) {
        let _ = PALETTE.set(build(theme.bg, theme.fg, theme.dark));
        return theme.supported;
    }
    use ratatui::crossterm::terminal::{disable_raw_mode, enable_raw_mode};
    let _ = std::io::stdout()
        .write_all(b"\x1b[?25l")
        .and_then(|_| std::io::stdout().flush());
    if enable_raw_mode().is_err() {
        return false;
    }
    let (reply, supported) = query(Duration::from_millis(500));
    let _ = disable_raw_mode();
    let theme = Theme::from_reply(&reply, supported);
    cache::store(CACHE_FILE, &theme.to_value());
    let _ = PALETTE.set(build(theme.bg, theme.fg, theme.dark));
    false
}

pub fn refresh() {
    let (reply, supported) = query(Duration::from_millis(50));
    if !supported {
        return;
    }
    let theme = Theme::from_reply(&reply, true);
    cache::store(CACHE_FILE, &theme.to_value());
}

pub fn text() -> Style {
    Style::new().fg(palette().text)
}

pub fn muted() -> Style {
    Style::new().fg(palette().muted)
}

pub fn faint() -> Style {
    Style::new().fg(palette().faint)
}

pub fn accent() -> Style {
    Style::new().fg(palette().accent)
}

pub fn danger() -> Style {
    Style::new().fg(palette().danger)
}

pub fn bold() -> Style {
    text().add_modifier(Modifier::BOLD)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn theme_round_trips_through_json() {
        let reply =
            "\x1b]10;rgb:d4d4/d4d4/d4d4\x1b\\\x1b]11;rgb:1e1e/1e1e/1e1e\x1b\\\x1b[?997;1n\x1b[?62c";
        let theme = Theme::from_reply(reply, true);
        assert_eq!(theme.bg, Rgb(0x1e, 0x1e, 0x1e));
        assert_eq!(theme.fg, Rgb(0xd4, 0xd4, 0xd4));
        assert!(theme.dark);
        assert!(theme.supported);
        assert_eq!(Theme::from_value(&theme.to_value()), Some(theme));
    }

    #[test]
    fn light_theme_from_dec_997() {
        let reply = "\x1b[?997;2n\x1b[?62c";
        let theme = Theme::from_reply(reply, true);
        assert!(!theme.dark);
        assert_eq!(theme.bg, Rgb(250, 250, 250));
        assert_eq!(theme.fg, Rgb(56, 58, 66));
    }
}
