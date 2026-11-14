use serde_json::{json, Value};
use std::io::Write;
use std::process::{Command, Stdio};

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

fn action(name: &str, args: Value) -> Result<Value, String> {
    let text = run(
        &["do", name, "--args", "-", "--json"],
        Some(&args.to_string()),
    )?;
    if text.trim().is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

pub fn list() -> Result<Value, String> {
    action("workspace_list", json!({}))
}

pub fn verb(verb: &str, name: &str) -> Result<Value, String> {
    let mut args = json!({ "name": name });
    if verb != "open" {
        args["select"] = json!(false);
    }
    action(&format!("workspace_{verb}"), args)
}

pub fn save(name: &str, spec: &Value, previous: Option<&str>) -> Result<Value, String> {
    let mut args = json!({ "name": name, "spec": spec });
    if let Some(p) = previous {
        args["previous"] = json!(p);
    }
    action("workspace_save", args)
}

pub fn remove(name: &str) -> Result<Value, String> {
    action("workspace_remove", json!({ "name": name }))
}

pub fn detect(root: &str, name: &str) -> Result<Value, String> {
    action("workspace_detect", json!({ "root": root, "name": name }))
}

pub fn resize(screen: &str) -> Result<Value, String> {
    action("workspace_ui_resize", json!({ "screen": screen }))
}

pub fn reload() -> Result<(), String> {
    run(&["config", "reload"], None).map(|_| ())
}
