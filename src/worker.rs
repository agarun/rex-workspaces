use crate::rex;
use serde_json::Value;
use std::sync::mpsc::Sender;
use std::thread;

pub enum Job {
    List,
    Verb {
        verb: String,
        name: String,
    },
    Save {
        name: String,
        spec: Value,
        previous: Option<String>,
    },
    Remove {
        name: String,
    },
    Detect {
        root: String,
        name: String,
    },
    Capture {
        session: String,
    },
}

pub enum Done {
    List(Result<Value, String>),
    Verb {
        verb: String,
        name: String,
        result: Result<Value, String>,
    },
    Saved {
        name: String,
        result: Result<Option<String>, String>,
    },
    Removed {
        name: String,
        result: Result<Option<String>, String>,
    },
    Detected {
        root: String,
        result: Result<Value, String>,
    },
    Captured(Result<Value, String>),
}

fn reloaded(result: Result<Value, String>) -> Result<Option<String>, String> {
    result?;
    Ok(rex::reload().err())
}

fn run(job: Job) -> Done {
    match job {
        Job::List => Done::List(rex::list()),
        Job::Verb { verb, name } => {
            let result = rex::verb(&verb, &name);
            Done::Verb { verb, name, result }
        }
        Job::Save {
            name,
            spec,
            previous,
        } => {
            let result = reloaded(rex::save(&name, &spec, previous.as_deref()));
            Done::Saved { name, result }
        }
        Job::Remove { name } => {
            let result = reloaded(rex::remove(&name));
            Done::Removed { name, result }
        }
        Job::Detect { root, name } => {
            let result = rex::detect(&root, &name);
            Done::Detected { root, result }
        }
        Job::Capture { session } => Done::Captured(rex::capture(&session)),
    }
}

pub fn spawn(tx: &Sender<Done>, job: Job) {
    let tx = tx.clone();
    thread::spawn(move || {
        let _ = tx.send(run(job));
    });
}
