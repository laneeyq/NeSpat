use std::{env, path::PathBuf, process::ExitCode};
fn main() -> ExitCode {
    if unsafe { libc::geteuid() } == 0 {
        return ExitCode::FAILURE;
    }
    let args: Vec<_> = env::args_os().skip(1).collect();
    let [version, folder] = args.as_slice() else {
        return ExitCode::FAILURE;
    };
    let Some(version) = version.to_str() else {
        return ExitCode::FAILURE;
    };
    match nespat_core::updates::check(version, &PathBuf::from(folder)) {
        Ok(None) => {
            println!("null");
            ExitCode::SUCCESS
        }
        Ok(Some((version, path))) => {
            println!("{}", serde_json::json!({"version":version,"path":path}));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
