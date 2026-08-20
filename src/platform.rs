//! OS integration: reveal, editor, folder picker, keychain, diagnostics.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use crate::error::{GinoError, Result, io_error};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExternalCommand {
    pub program: String,
    pub args: Vec<String>,
}

impl ExternalCommand {
    fn new(program: impl Into<String>, args: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
        }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(&self.program);
        command.args(&self.args);
        command
    }
}

pub fn reveal_command(path: &Path) -> ExternalCommand {
    #[cfg(target_os = "macos")]
    {
        ExternalCommand::new("open", ["-R", &path.display().to_string()])
    }
    #[cfg(target_os = "windows")]
    {
        ExternalCommand::new("explorer", [format!("/select,{}", path.display())])
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        let parent = path.parent().unwrap_or(path);
        ExternalCommand::new("xdg-open", [parent.display().to_string()])
    }
}

pub fn reveal_in_file_manager(path: &Path) -> Result<()> {
    spawn_detached(path, &reveal_command(path))
}

pub fn resolve_editor(
    configured: Option<&str>,
    visual: Option<&str>,
    editor: Option<&str>,
) -> Option<String> {
    first_nonempty(configured)
        .or_else(|| first_nonempty(visual))
        .or_else(|| first_nonempty(editor))
}

pub fn editor_command(path: &Path, editor: Option<&str>) -> ExternalCommand {
    let resolved = resolve_editor(
        editor,
        std::env::var("VISUAL").ok().as_deref(),
        std::env::var("EDITOR").ok().as_deref(),
    );
    if let Some(editor) = resolved {
        let mut parts = editor.split_whitespace();
        let program = parts.next().unwrap_or("true").to_owned();
        let mut args: Vec<String> = parts.map(ToOwned::to_owned).collect();
        args.push(path.display().to_string());
        return ExternalCommand { program, args };
    }
    #[cfg(target_os = "macos")]
    {
        ExternalCommand::new("open", [path.display().to_string()])
    }
    #[cfg(target_os = "windows")]
    {
        ExternalCommand::new("cmd", ["/C", "start", "", &path.display().to_string()])
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        ExternalCommand::new("xdg-open", [path.display().to_string()])
    }
}

pub fn open_in_editor(path: &Path, editor: Option<&str>) -> Result<()> {
    spawn_detached(path, &editor_command(path, editor))
}

pub fn open_url_command(url: &str) -> ExternalCommand {
    #[cfg(target_os = "macos")]
    {
        ExternalCommand::new("open", [url])
    }
    #[cfg(target_os = "windows")]
    {
        ExternalCommand::new("cmd", ["/C", "start", "", url])
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        ExternalCommand::new("xdg-open", [url])
    }
}

/// Open a user-visible URL (Settings → GitHub Releases). Not self-update.
pub fn open_url(url: &str) -> Result<()> {
    spawn_detached(Path::new(url), &open_url_command(url))
}

pub fn pick_folder_command() -> ExternalCommand {
    #[cfg(target_os = "macos")]
    {
        ExternalCommand::new("osascript", ["-e", "POSIX path of (choose folder)"])
    }
    #[cfg(target_os = "windows")]
    {
        ExternalCommand::new(
            "powershell",
            [
                "-NoProfile",
                "-Command",
                "Add-Type -AssemblyName System.Windows.Forms; $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }",
            ],
        )
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        ExternalCommand::new("zenity", ["--file-selection", "--directory"])
    }
}

pub fn pick_folder() -> Result<Option<PathBuf>> {
    let planned = pick_folder_command();
    let output = planned
        .command()
        .output()
        .map_err(|source| io_error(Path::new(&planned.program), source))?;
    if !output.status.success() {
        return Ok(None);
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if path.is_empty() {
        return Ok(None);
    }
    Ok(Some(PathBuf::from(path)))
}

pub fn store_secret(service: &str, account: &str, secret: &str) -> Result<()> {
    #[cfg(target_os = "macos")]
    {
        map_command(
            Path::new("security"),
            "security",
            Command::new("security")
                .args([
                    "add-generic-password",
                    "-U",
                    "-s",
                    service,
                    "-a",
                    account,
                    "-w",
                    secret,
                ])
                .output(),
        )
    }
    #[cfg(target_os = "windows")]
    {
        let target = windows_credential_target(service, account);
        map_command(
            Path::new("cmdkey"),
            "cmdkey",
            Command::new("cmdkey")
                .args([
                    format!("/generic:{target}"),
                    format!("/user:{account}"),
                    format!("/pass:{secret}"),
                ])
                .output(),
        )
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        store_secret_secret_tool(service, account, secret)
    }
}

pub fn read_secret(service: &str, account: &str) -> Result<Option<String>> {
    #[cfg(target_os = "macos")]
    {
        read_secret_output(
            Command::new("security")
                .args(["find-generic-password", "-s", service, "-a", account, "-w"])
                .output()
                .map_err(|source| credential_error("security", source))?,
        )
    }
    #[cfg(target_os = "windows")]
    {
        let target = windows_credential_target(service, account);
        read_secret_output(
            Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-Command",
                    &windows_read_secret_script(&target),
                ])
                .output()
                .map_err(|source| credential_error("powershell", source))?,
        )
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        read_secret_output(
            Command::new("secret-tool")
                .args(["lookup", "service", service, "account", account])
                .output()
                .map_err(|source| credential_error("secret-tool", source))?,
        )
    }
}

/// Zip sanitized logs and environment metadata. Skill contents are never added.
pub fn export_diagnostics(destination: &Path, logs: &str, environment: &str) -> Result<()> {
    if let Some(parent) = destination.parent() {
        std::fs::create_dir_all(parent).map_err(|source| io_error(parent, source))?;
    }
    let file =
        std::fs::File::create(destination).map_err(|source| io_error(destination, source))?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    zip.start_file("environment.txt", options)
        .map_err(|error| zip_error(destination, error))?;
    zip.write_all(sanitize(environment).as_bytes())
        .map_err(|source| io_error(destination, source))?;
    zip.start_file("app.log", options)
        .map_err(|error| zip_error(destination, error))?;
    zip.write_all(sanitize(logs).as_bytes())
        .map_err(|source| io_error(destination, source))?;
    zip.finish()
        .map_err(|error| zip_error(destination, error))?;
    Ok(())
}

pub fn sanitize(input: &str) -> String {
    let mut output = redact_bearer(input);
    output = redact_assignments(&output);
    redact_known_token_prefixes(&output)
}

fn first_nonempty(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn spawn_detached(path: &Path, planned: &ExternalCommand) -> Result<()> {
    planned
        .command()
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|source| io_error(path, source))?;
    Ok(())
}

fn read_secret_output(output: std::process::Output) -> Result<Option<String>> {
    if !output.status.success() {
        return Ok(None);
    }
    let secret = trim_secret_bytes(&output.stdout);
    Ok((!secret.is_empty()).then_some(secret))
}

fn trim_secret_bytes(bytes: &[u8]) -> String {
    let mut secret = String::from_utf8_lossy(bytes).into_owned();
    if secret.ends_with('\n') {
        secret.pop();
        if secret.ends_with('\r') {
            secret.pop();
        }
    }
    secret
}

fn credential_error(tool: &str, source: std::io::Error) -> GinoError {
    if source.kind() == std::io::ErrorKind::NotFound {
        GinoError::InvalidPlan(format!(
            "{tool} is not available; store tokens in the operating-system credential store"
        ))
    } else {
        io_error(Path::new(tool), source)
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
fn store_secret_secret_tool(service: &str, account: &str, secret: &str) -> Result<()> {
    let label = format!("gino {service} {account}");
    let mut child = Command::new("secret-tool")
        .args([
            "store", "--label", &label, "service", service, "account", account,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|source| credential_error("secret-tool", source))?;
    let Some(mut stdin) = child.stdin.take() else {
        return Err(GinoError::InvalidPlan(
            "secret-tool stdin was not available".to_owned(),
        ));
    };
    stdin
        .write_all(secret.as_bytes())
        .map_err(|source| io_error(Path::new("secret-tool"), source))?;
    drop(stdin);
    let output = child
        .wait_with_output()
        .map_err(|source| io_error(Path::new("secret-tool"), source))?;
    if output.status.success() {
        Ok(())
    } else {
        Err(GinoError::InvalidPlan(format!(
            "secret-tool store failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }
}

#[cfg(target_os = "windows")]
fn windows_credential_target(service: &str, account: &str) -> String {
    format!("gino/{service}/{account}")
}

#[cfg(target_os = "windows")]
fn windows_read_secret_script(target: &str) -> String {
    format!(
        r#"$target = {target}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class GinoCred {{
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct CREDENTIAL {{
    public int Flags;
    public int Type;
    public string TargetName;
    public string Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public int CredentialBlobSize;
    public IntPtr CredentialBlob;
    public int Persist;
    public int AttributeCount;
    public IntPtr Attributes;
    public string TargetAlias;
    public string UserName;
  }}
  [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  public static extern bool CredRead(string target, int type, int reserved, out IntPtr cred);
  [DllImport("advapi32.dll")]
  public static extern void CredFree(IntPtr cred);
  public static string Read(string target) {{
    IntPtr ptr;
    if (!CredRead(target, 1, 0, out ptr)) return "";
    try {{
      CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
      if (cred.CredentialBlob == IntPtr.Zero || cred.CredentialBlobSize <= 0) return "";
      return Marshal.PtrToStringUni(cred.CredentialBlob, cred.CredentialBlobSize / 2) ?? "";
    }} finally {{ CredFree(ptr); }}
  }}
}}
"@
[GinoCred]::Read($target)
"#,
        target = powershell_single_quoted(target)
    )
}

#[cfg(target_os = "windows")]
fn powershell_single_quoted(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn redact_assignments(input: &str) -> String {
    const KEYS: &[&str] = &[
        "authorization",
        "password",
        "passwd",
        "secret",
        "token",
        "api_key",
        "apikey",
        "access_key",
        "private_key",
        "credential",
    ];
    let mut output = input.to_owned();
    for key in KEYS {
        output = redact_assignment(&output, key);
    }
    output
}

fn redact_assignment(input: &str, key: &str) -> String {
    let lower = input.to_ascii_lowercase();
    let mut out = String::new();
    let mut start = 0;
    let mut search_from = 0;
    while let Some(rel) = lower[search_from..].find(key) {
        let idx = search_from + rel;
        let after_key = idx + key.len();
        if !isolated_match(input, idx, key.len()) {
            search_from = after_key;
            continue;
        }
        let mut cursor = after_key;
        cursor += skip_ws_and_quotes(&input[cursor..]);
        let Some(sep) = input[cursor..].chars().next() else {
            search_from = after_key;
            continue;
        };
        if sep != '=' && sep != ':' {
            search_from = after_key;
            continue;
        }
        cursor += sep.len_utf8();
        cursor += skip_ws_and_quotes(&input[cursor..]);
        let value_end = input[cursor..]
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ',' || c == '&')
            .map(|offset| cursor + offset)
            .unwrap_or(input.len());
        out.push_str(&input[start..cursor]);
        out.push_str("[redacted]");
        start = value_end;
        search_from = value_end;
    }
    out.push_str(&input[start..]);
    out
}

fn redact_bearer(input: &str) -> String {
    let lower = input.to_ascii_lowercase();
    let mut out = String::new();
    let mut start = 0;
    let mut search_from = 0;
    while let Some(rel) = lower[search_from..].find("bearer") {
        let idx = search_from + rel;
        let after = idx + "bearer".len();
        if !isolated_match(input, idx, "bearer".len()) {
            search_from = after;
            continue;
        }
        let ws = skip_ws(&input[after..]);
        let token_start = after + ws;
        if token_start == after {
            search_from = after;
            continue;
        }
        let token_end = input[token_start..]
            .find(|c: char| c.is_whitespace() || c == '"' || c == '\'')
            .map(|offset| token_start + offset)
            .unwrap_or(input.len());
        out.push_str(&input[start..token_start]);
        out.push_str("[redacted]");
        start = token_end;
        search_from = token_end;
    }
    out.push_str(&input[start..]);
    out
}

fn redact_known_token_prefixes(input: &str) -> String {
    const PREFIXES: &[&str] = &["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"];
    let mut output = input.to_owned();
    for prefix in PREFIXES {
        output = redact_prefix(&output, prefix);
    }
    output
}

fn redact_prefix(input: &str, prefix: &str) -> String {
    let mut out = String::new();
    let mut start = 0;
    let mut search_from = 0;
    while let Some(rel) = input[search_from..].find(prefix) {
        let idx = search_from + rel;
        let value_start = idx + prefix.len();
        let value_end = input[value_start..]
            .find(|c: char| !c.is_ascii_alphanumeric() && c != '_')
            .map(|offset| value_start + offset)
            .unwrap_or(input.len());
        out.push_str(&input[start..idx]);
        out.push_str("[redacted]");
        start = value_end;
        search_from = value_end;
    }
    out.push_str(&input[start..]);
    out
}

fn isolated_match(input: &str, start: usize, len: usize) -> bool {
    let before = input[..start].chars().next_back();
    let after = input[start + len..].chars().next();
    !before.is_some_and(is_ascii_word) && !after.is_some_and(is_ascii_word)
}

fn is_ascii_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

fn skip_ws(input: &str) -> usize {
    input.len() - input.trim_start_matches(|c: char| c.is_whitespace()).len()
}

fn skip_ws_and_quotes(input: &str) -> usize {
    input
        .chars()
        .take_while(|c| c.is_whitespace() || *c == '"' || *c == '\'')
        .map(char::len_utf8)
        .sum()
}

fn zip_error(path: &Path, error: zip::result::ZipError) -> GinoError {
    GinoError::Io {
        path: path.to_path_buf(),
        source: std::io::Error::other(error.to_string()),
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn map_command(
    path: &Path,
    command: &str,
    output: std::io::Result<std::process::Output>,
) -> Result<()> {
    let output = output.map_err(|source| {
        if source.kind() == std::io::ErrorKind::NotFound {
            credential_error(command, source)
        } else {
            io_error(path, source)
        }
    })?;
    if output.status.success() {
        return Ok(());
    }
    Err(GinoError::InvalidPlan(format!(
        "{command} failed for {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr).trim()
    )))
}

#[cfg(test)]
mod tests {
    use std::io::Read;

    use super::*;

    #[test]
    fn diagnostic_zip_redacts_tokens_and_omits_skill_contents() {
        let root = tempfile::tempdir().expect("tmp");
        let zip_path = root.path().join("diag.zip");
        export_diagnostics(
            &zip_path,
            "token=abc Authorization: Bearer hunter2 ghp_ABCDEF1234",
            "password: s3cret",
        )
        .expect("zip");
        assert!(zip_path.is_file());

        let file = std::fs::File::open(&zip_path).expect("open zip");
        let mut archive = zip::ZipArchive::new(file).expect("archive");
        let names: Vec<String> = (0..archive.len())
            .map(|index| archive.by_index(index).expect("entry").name().to_owned())
            .collect();
        assert_eq!(names, vec!["environment.txt", "app.log"]);

        let mut log = String::new();
        archive
            .by_name("app.log")
            .expect("log")
            .read_to_string(&mut log)
            .expect("read log");
        let mut environment = String::new();
        archive
            .by_name("environment.txt")
            .expect("env")
            .read_to_string(&mut environment)
            .expect("read env");
        assert!(!log.contains("hunter2"));
        assert!(!log.contains("abc"));
        assert!(!log.contains("ghp_ABCDEF1234"));
        assert!(!environment.contains("s3cret"));
        assert!(log.contains("[redacted]"));
    }

    #[test]
    fn sanitize_redacts_assignment_and_bearer_values() {
        assert_eq!(
            sanitize("token=abc Authorization: Bearer xyz"),
            "token=[redacted] Authorization: [redacted] [redacted]"
        );
        assert_eq!(sanitize("ready to scan"), "ready to scan");
        assert!(!sanitize("secret-tool lookup").contains("[redacted]"));
        assert_eq!(sanitize("tokens=keep"), "tokens=keep");
    }

    #[test]
    fn editor_prefers_configured_then_visual_then_editor() {
        assert_eq!(
            resolve_editor(Some("hx"), Some("vim"), Some("nano")).as_deref(),
            Some("hx")
        );
        assert_eq!(
            resolve_editor(Some("  "), Some("vim"), Some("nano")).as_deref(),
            Some("vim")
        );
        assert_eq!(
            resolve_editor(None, None, Some("nano")).as_deref(),
            Some("nano")
        );
        assert_eq!(resolve_editor(None, None, None), None);

        let skill = Path::new("SKILL.md");
        let command = editor_command(skill, Some("code --wait"));
        assert_eq!(command.program, "code");
        assert_eq!(
            command.args,
            vec!["--wait".to_owned(), skill.display().to_string()]
        );
    }

    #[test]
    fn open_url_uses_platform_opener() {
        let command = open_url_command("https://github.com/thedavidweng/gino/releases");
        #[cfg(target_os = "macos")]
        {
            assert_eq!(command.program, "open");
            assert_eq!(
                command.args,
                vec!["https://github.com/thedavidweng/gino/releases".to_owned()]
            );
        }
        #[cfg(target_os = "windows")]
        {
            assert_eq!(command.program, "cmd");
            assert_eq!(command.args[0], "/C");
            assert_eq!(
                command.args.last().map(String::as_str),
                Some("https://github.com/thedavidweng/gino/releases")
            );
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            assert_eq!(command.program, "xdg-open");
            assert_eq!(
                command.args,
                vec!["https://github.com/thedavidweng/gino/releases".to_owned()]
            );
        }
    }

    #[test]
    fn reveal_and_picker_use_platform_tools() {
        let reveal = reveal_command(Path::new("/tmp/SKILL.md"));
        let picker = pick_folder_command();
        #[cfg(target_os = "macos")]
        {
            assert_eq!(reveal.program, "open");
            assert_eq!(reveal.args[0], "-R");
            assert_eq!(picker.program, "osascript");
        }
        #[cfg(target_os = "windows")]
        {
            assert_eq!(reveal.program, "explorer");
            assert!(reveal.args[0].starts_with("/select,"));
            assert_eq!(picker.program, "powershell");
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        {
            assert_eq!(reveal.program, "xdg-open");
            assert_eq!(picker.program, "zenity");
        }
    }
}
