use serde_json::{json, Value};
use std::io::Write;
use std::process::{Command, Stdio};
use std::thread;

fn with_host<'a>(host: Option<&'a str>, args: &[&'a str]) -> Vec<&'a str> {
    let mut all = match host {
        Some(h) => vec!["-S", h],
        None => vec![],
    };
    all.extend_from_slice(args);
    all
}

fn run(args: &[&str], input: Option<&str>) -> Result<String, String> {
    let mut child = Command::new("rex")
        .args(args)
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("cannot run rex: {e}"))?;
    if let (Some(text), Some(mut stdin)) = (input, child.stdin.take()) {
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| e.to_string())?;
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }
    let err = String::from_utf8_lossy(&out.stderr);
    let err = err.trim().trim_start_matches("Error: ").replace('\n', " ");
    Err(if err.is_empty() {
        "rex failed".into()
    } else {
        err
    })
}

fn action(host: Option<&str>, name: &str, args: Value) -> Result<Value, String> {
    call(
        &with_host(host, &["do", name, "--args", "-", "--json"]),
        args,
    )
}

fn call(argv: &[&str], args: Value) -> Result<Value, String> {
    let text = run(argv, Some(&args.to_string()))?;
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub fn list(host: Option<&str>) -> Result<Value, String> {
    action(host, "workspace_list", json!({}))
}

pub fn plugin_hosts() -> Vec<String> {
    let labels = run(&["--timeout", "3s", "hosts", "--json"], None)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .map(|v| host_labels(&v))
        .unwrap_or_default();
    let probes: Vec<_> = labels
        .into_iter()
        .map(|h| {
            thread::spawn(move || {
                let argv = [
                    "--timeout",
                    "3s",
                    "do",
                    "workspace_list",
                    "--args",
                    "-",
                    "--json",
                ];
                call(&with_host(Some(&h), &argv), json!({}))
                    .is_ok()
                    .then_some(h)
            })
        })
        .collect();
    probes
        .into_iter()
        .filter_map(|p| p.join().ok().flatten())
        .collect()
}

fn host_labels(v: &Value) -> Vec<String> {
    let mut seen = Vec::new();
    let mut labels = Vec::new();
    for h in v["hosts"].as_array().into_iter().flatten() {
        let h = &h["host"];
        let Some(label) = h["label"].as_str().filter(|l| !l.is_empty()) else {
            continue;
        };
        let endpoints: Vec<&str> = h["endpoints"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .collect();
        if endpoints.iter().any(|e| seen.contains(e)) {
            continue;
        }
        seen.extend(endpoints);
        labels.push(label.to_string());
    }
    labels
}

pub fn verb(host: Option<&str>, verb: &str, name: &str) -> Result<Value, String> {
    let mut args = json!({ "name": name });
    if verb != "open" {
        args["select"] = json!(false);
    }
    action(host, &format!("workspace_{verb}"), args)
}

pub fn save(
    host: Option<&str>,
    name: &str,
    spec: &Value,
    previous: Option<&str>,
) -> Result<Value, String> {
    let mut args = json!({ "name": name, "spec": spec });
    if let Some(p) = previous {
        args["previous"] = json!(p);
    }
    action(host, "workspace_save", args)
}

pub fn remove(host: Option<&str>, name: &str) -> Result<Value, String> {
    action(host, "workspace_remove", json!({ "name": name }))
}

pub fn detect(host: Option<&str>, root: &str, name: &str) -> Result<Value, String> {
    action(
        host,
        "workspace_detect",
        json!({ "root": root, "name": name }),
    )
}

pub fn capture(host: Option<&str>, session: &str) -> Result<Value, String> {
    let mut args = json!({ "save": false });
    if !session.is_empty() {
        args["session"] = json!(session);
    }
    action(host, "workspace_capture", args)
}

pub fn resize(screen: &str) -> Result<Value, String> {
    action(None, "workspace_ui_resize", json!({ "screen": screen }))
}

pub fn reload(host: Option<&str>) -> Result<(), String> {
    run(&with_host(host, &["config", "reload"]), None).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_flag_only_when_set() {
        assert_eq!(with_host(None, &["do", "x"]), ["do", "x"]);
        assert_eq!(
            with_host(Some("desktop"), &["do", "x"]),
            ["-S", "desktop", "do", "x"]
        );
    }

    #[test]
    fn hosts_collapse_by_endpoint() {
        let v = json!({ "hosts": [
            { "host": { "label": "desktop", "endpoints": ["http://d:7297"] } },
            { "host": { "label": "Desktop PC", "endpoints": ["http://d:7297"] } },
            { "host": { "label": "studio", "endpoints": ["http://s:7297"] } },
            { "host": { "label": "", "endpoints": ["http://x:7297"] } },
        ]});
        assert_eq!(host_labels(&v), ["desktop", "studio"]);
    }
}
