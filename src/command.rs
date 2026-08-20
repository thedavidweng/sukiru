use crate::planner::{InstallMode, PlanAction};
use crate::protocol::SkillSource;

/// Equivalent official CLI command when one can be represented (spec §8.2).
pub fn equivalent_command(
    action: PlanAction,
    skill_name: &str,
    source: Option<&SkillSource>,
    global: bool,
    mode: Option<InstallMode>,
) -> Option<String> {
    let mut parts = match action {
        PlanAction::Install => {
            let source = source?;
            let mut cmd = format!("npx skills add {}", source_token(source));
            if !source_selects_skill(source, skill_name) {
                cmd.push_str(" --skill ");
                cmd.push_str(skill_name);
            }
            cmd
        }
        PlanAction::Update => format!("npx skills update {skill_name}"),
        PlanAction::Remove => format!("npx skills remove {skill_name}"),
        PlanAction::AttachSource => {
            let source = source?;
            format!(
                "npx skills add {} --skill {skill_name}",
                source_token(source)
            )
        }
        PlanAction::Copy | PlanAction::Move | PlanAction::Relink | PlanAction::Restore => {
            return None;
        }
        PlanAction::Metadata => return None,
    };
    if global {
        parts.push_str(" --global");
    }
    // Upstream default is symlink; `--copy` is the opt-in. There is no `--link`.
    if matches!(mode, Some(InstallMode::Copy)) {
        parts.push_str(" --copy");
    }
    Some(parts)
}

pub fn find_command(query: &str) -> String {
    if query.trim().is_empty() {
        "npx skills find".to_owned()
    } else {
        format!("npx skills find {query}")
    }
}

fn source_token(source: &SkillSource) -> String {
    source.input.clone()
}

fn source_selects_skill(source: &SkillSource, skill_name: &str) -> bool {
    source
        .skill_filter
        .as_deref()
        .is_some_and(|filter| filter.eq_ignore_ascii_case(skill_name))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_and_remove_commands_match_upstream_shape() {
        let source = SkillSource::parse("vercel-labs/agent-skills@demo").expect("source");
        assert_eq!(
            equivalent_command(PlanAction::Install, "demo", Some(&source), true, None).as_deref(),
            Some("npx skills add vercel-labs/agent-skills@demo --global")
        );
        assert_eq!(
            equivalent_command(PlanAction::Remove, "demo", None, false, None).as_deref(),
            Some("npx skills remove demo")
        );
        assert_eq!(find_command("tdd"), "npx skills find tdd");
    }

    #[test]
    fn add_update_find_and_copy_flags_match_upstream_cli() {
        let repo = SkillSource::parse("vercel-labs/agent-skills").expect("repo");
        assert_eq!(
            equivalent_command(PlanAction::Install, "demo", Some(&repo), false, None).as_deref(),
            Some("npx skills add vercel-labs/agent-skills --skill demo")
        );
        assert_eq!(
            equivalent_command(
                PlanAction::Install,
                "demo",
                Some(&repo),
                true,
                Some(InstallMode::Copy)
            )
            .as_deref(),
            Some("npx skills add vercel-labs/agent-skills --skill demo --global --copy")
        );
        assert_eq!(
            equivalent_command(
                PlanAction::Install,
                "demo",
                Some(&repo),
                false,
                Some(InstallMode::Link)
            )
            .as_deref(),
            Some("npx skills add vercel-labs/agent-skills --skill demo")
        );
        assert_eq!(
            equivalent_command(PlanAction::Update, "demo", None, true, None).as_deref(),
            Some("npx skills update demo --global")
        );
        assert_eq!(
            equivalent_command(PlanAction::AttachSource, "demo", Some(&repo), false, None)
                .as_deref(),
            Some("npx skills add vercel-labs/agent-skills --skill demo")
        );
        assert_eq!(find_command(""), "npx skills find");
        assert!(equivalent_command(PlanAction::Move, "demo", None, false, None).is_none());
    }
}
