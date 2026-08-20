let meta = #{
    name: "ship-1-0",
    description: "Bring Gino to a releasable 1.0 against docs/spec.md and docs/release-plan.md",
    when_to_use: "Ship Gino 1.0: protocol, services, UI, CI, packaging",
    phases: [
        #{ title: "Protocol", detail: "Agents, sources, equivalent CLI" },
        #{ title: "Services", detail: "Marketplace, platform, preferences" },
        #{ title: "Product UI", detail: "All spec surfaces and keyboard" },
        #{ title: "Release", detail: "Docs, CI, packaging, version" },
        #{ title: "Verify", detail: "Build, test, clippy, gap check" },
    ],
};

let slice_schema = #{
    "type": "object",
    "required": ["ok", "summary", "files", "tests"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "files": #{ "type": "array", "items": #{ "type": "string" } },
        "tests": #{ "type": "string" },
        "blocked": #{ "type": "string" },
    },
};

let verify_schema = #{
    "type": "object",
    "required": ["ok", "summary", "failing"],
    "properties": #{
        "ok": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "failing": #{ "type": "array", "items": #{ "type": "string" } },
    },
};

fn implement_prompt(slice, files, extra) {
    let p = "";
    p += "You are implementing Gino, a native GPUI manager for Vercel-compatible agent Skills.\n";
    p += "Workspace: /Users/david/Development/gino\n";
    p += "Read docs/spec.md, docs/release-plan.md, compatibility.toml, Cargo.toml, and src/lib.rs first.\n";
    p += "Then read every file you will change. Do not answer from memory.\n\n";
    p += "SLICE: ";
    p += slice;
    p += "\nPRIMARY FILES: ";
    p += files;
    p += "\n";
    p += extra;
    p += "\n\nRULES:\n";
    p += "- Rust 2024, rust-version 1.85, unsafe_code forbid.\n";
    p += "- Filesystem + Vercel lockfiles are the source of truth. SQLite is UI-only.\n";
    p += "- No write except through Planner -> Apply. Refresh is read-only.\n";
    p += "- Preserve unknown lockfile JSON fields. Match vercel-labs/skills@1.5.9.\n";
    p += "- Do not add Node.js. Do not add telemetry or self-update.\n";
    p += "- Add or update tests in the same modules. Run cargo test and cargo clippy -D warnings.\n";
    p += "- Keep one implementation path; delete scaffolding you replace.\n";
    p += "- If a command fails, fix it before finishing.\n";
    p += "- Return ok=true only if cargo test and clippy succeeded for your changes.\n";
    p
}

phase("Protocol");
log("S1 protocol lock-in");
let s1 = "";
s1 += "Complete src/agents.rs so every 1.5.9 agent exists with correct project/global paths,\n";
s1 += "detection markers, XDG, CODEX_HOME, CLAUDE_CONFIG_DIR, VIBE_HOME, OpenClaw aliases,\n";
s1 += "Zed, Replit cwd, Pi .pi/agent, Windsurf .codeium/windsurf, Kimi ~/.kimi, Devin XDG.\n";
s1 += "Complete src/protocol.rs SkillSource::parse for local, github, gitlab, git, well-known,\n";
s1 += "github:/gitlab: prefixes, #ref fragments, owner/repo@skill, owner/repo/subpath,\n";
s1 += "GitLab /-/tree/ URLs. Add SourceType::WellKnown. Keep lock schema/hash behavior.\n";
s1 += "Add src/command.rs that formats equivalent npx skills add/remove/update/find commands.\n";
s1 += "Export new modules from src/lib.rs. Do not rewrite planner/executor/git unless required.\n";
let r1 = agent(implement_prompt("S1 Protocol lock-in", "src/agents.rs, src/protocol.rs, src/source.rs, src/command.rs, src/lib.rs", s1), #{
    label: "s1-protocol",
    capability_mode: "all",
    output_schema: slice_schema,
});
if r1 == () || !r1.success || r1.output.ok != true {
    log("S1 failed; continuing so later slices can still land");
}

phase("Services");
log("S2 application services");
let s2 = "";
s2 += "Add src/marketplace.rs: search https://skills.sh/api/search?q=&limit=25 with optional proxy.\n";
s2 += "Parse {skills:[{id,name,installs,source}]}. Tests must not require network: test JSON parse.\n";
s2 += "Add src/platform.rs: reveal path (open/xdg-open/explorer), open editor ($VISUAL/$EDITOR),\n";
s2 += "pick folder via osascript/zenity/powershell, store/read token via `security`/`secret-tool`,\n";
s2 += "export sanitized diagnostic zip excluding tokens and skill contents.\n";
s2 += "Extend src/metadata.rs with a settings key/value table and Preferences struct used by UI.\n";
s2 += "Default snapshot root to ~/.gino/snapshots. Wire src/main.rs to load preferences.\n";
s2 += "Add ureq (json+tls) and zip only if needed. Keep dependency surface small.\n";
let r2 = agent(implement_prompt("S2 Application services", "src/marketplace.rs, src/platform.rs, src/metadata.rs, src/main.rs, Cargo.toml", s2), #{
    label: "s2-services",
    capability_mode: "all",
    output_schema: slice_schema,
});
if r2 == () || !r2.success || r2.output.ok != true {
    log("S2 failed; UI must still degrade gracefully");
}

phase("Product UI");
log("S3 product UI");
let s3 = "";
s3 += "Replace the GPUI shell with real surfaces from spec §6.1 and US-001..025.\n";
s3 += "Wrap the window in gpui_component::Root so dialogs/notifications work.\n";
s3 += "Use gpui-component: Sidebar, Button, h_flex/v_flex, Dialog, Notification, TextView markdown,\n";
s3 += "Checkbox, Input if needed. Library list + detail pane. Marketplace search + queue install.\n";
s3 += "Projects/Custom: register folder (platform picker) and remove bookmark only.\n";
s3 += "Duplicates: show groups, keep-one via planner.resolve_duplicate_group.\n";
s3 += "Presets/Tags via MetadataStore. Pending review lists changes; Apply N changes.\n";
s3 += "Backup: show last commit, Check Remote via propose_sync, restore_from_dir plans.\n";
s3 += "Settings + Activity. Exit dialog when pending is non-empty.\n";
s3 += "Keyboard: r refresh, a apply, backspace/delete queue remove, 1-9 sections, escape cancel.\n";
s3 += "Selection never writes files. Snapshot dir ~/.gino/snapshots. Honour push mode from settings.\n";
s3 += "You may split src/ui.rs into src/ui/mod.rs and focused files.\n";
let r3 = agent(implement_prompt("S3 Product UI", "src/ui.rs, src/main.rs, src/ui/", s3), #{
    label: "s3-ui",
    capability_mode: "all",
    output_schema: slice_schema,
});
if r3 == () || !r3.success || r3.output.ok != true {
    log("S3 UI incomplete");
}

phase("Release");
log("S4 release hardening");
let s4 = "";
s4 += "Add README.md (what Gino is, install from source, how it relates to npx skills, no Node.js).\n";
s4 += "Add MIT LICENSE. Add .github/workflows/ci.yml: cargo fmt --check, clippy -D warnings, test\n";
s4 += "on macos-latest, ubuntu-latest, windows-latest.\n";
s4 += "Add scripts/package.sh that cargo build --release and documents bundle/signing as manual.\n";
s4 += "Set version 1.0.0 in Cargo.toml. Settings must show version and GitHub Releases link.\n";
s4 += "No telemetry. No self-update. Do not commit target/.\n";
let r4 = agent(implement_prompt("S4 Release hardening", "README.md, LICENSE, .github/workflows/ci.yml, scripts/package.sh, Cargo.toml", s4), #{
    label: "s4-release",
    capability_mode: "all",
    output_schema: slice_schema,
});

phase("Verify");
log("Release gate");
let vprompt = "";
vprompt += "Verify Gino is releasable. Read docs/spec.md §28, docs/release-plan.md, then inspect the repo.\n";
vprompt += "Run: cargo test, cargo clippy --all-targets -- -D warnings, cargo fmt --check.\n";
vprompt += "Confirm README, LICENSE, CI workflow, version 1.0.0, no Node.js runtime dep.\n";
vprompt += "Spot-check agents (claude-code uses CLAUDE_CONFIG_DIR), source parse (well-known + gitlab tree),\n";
vprompt += "and UI has distinct Marketplace/Settings/Pending review — not one list for every sidebar item.\n";
vprompt += "Set ok=true only if tests+clippy+fmt pass AND the product surfaces exist. List concrete failing items.\n";
vprompt += "Do not modify code unless a one-line compile fix is required to run the tools.\n";
let rv = agent(vprompt, #{
    label: "verify-release",
    capability_mode: "execute",
    output_schema: verify_schema,
});

let ok = rv != () && rv.success && rv.output.ok == true;
let summary = "ship-1-0 finished";
if rv != () && rv.success && rv.output.summary != () {
    summary = rv.output.summary;
}
let failing = [];
if rv != () && rv.success && rv.output.failing != () {
    failing = rv.output.failing;
}

let report = "";
report += "# ship-1-0 result\n\n";
report += summary;
report += "\n\nreleasable: ";
if ok { report += "yes"; } else { report += "no"; }
report += "\n";
let path = write_scratch_file("ship-1-0-report.md", report);
complete(#{
    path: path,
    summary: summary,
    releasable: ok,
    failing: failing,
});
