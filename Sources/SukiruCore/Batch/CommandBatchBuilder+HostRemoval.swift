import Foundation

extension CommandBatchBuilder {
    /// Only hosts with scanned entries in this concrete scope are offered.
    public func hostRemovalCandidates(
        bucket: String, report: ScanReport, context: HostRemovalContext
    ) -> [HostSpec] {
        guard let facts = context.scopes[bucket] else { return [] }
        return HostTable.hosts.filter { host in
            guard let root = facts.nativeRoots[host.id] else { return false }
            return report.skills.contains { skill in
                Self.bucket(of: skill, report: report) == bucket
                    && skill.placements.contains { $0.path.hasPrefix(root + "/") }
            }
        }.sorted { $0.id < $1.id }
    }

    /// Pure planning from scan and captured disk evidence; this never mutates files.
    public func planHostRemoval(
        hostID: String, bucket: String, report: ScanReport, context: HostRemovalContext,
        capabilities: CapabilityReport? = nil
    ) throws -> HostRemovalPlan {
        guard let host = HostTable.host(id: hostID), let facts = context.scopes[bucket],
            let root = facts.nativeRoots[hostID]
        else {
            throw BatchBuildError(problems: [
                "Unknown Agent Host or unscanned scope: \(hostID), \(bucket)"
            ])
        }
        let skills = report.skills.filter { Self.bucket(of: $0, report: report) == bucket }
        let selection = HostRemovalSelection(root: root, facts: facts, skills: skills)
        let (removed, kept) = selection.entries()
        let uncertain =
            capabilities?.npx.skillsVersion.map { $0 != "1.7.0" } == true
            || report.issues.contains { issue in
                facts.workspaces.contains { issue.path.hasPrefix($0.workspace.root) }
                    || issue.path == facts.lockPath
            }
        let deletions = Set(removed.map(\.name)).sorted().filter { name in
            uncertain
                || !facts.detectedHosts.contains { other in
                    guard other != hostID, let installRoot = facts.installRoots[other] else {
                        return false
                    }
                    return facts.existingPaths.contains(
                        installRoot + "/" + HostRemovalContext.folderName(name))
                }
        }
        let visible = selection.visible(host: host, removed: removed, deletions: deletions)
        var problems: [String] = []
        if removed.isEmpty {
            problems.append(
                selection.sharedFolder
                    ? "Nothing can be removed for \(host.displayName) alone: "
                        + "its skills folder is shared with other hosts."
                    : "No entries installed by npx skills are removable for \(host.displayName) "
                        + "in \(bucket). Review the entries left in place."
            )
        }
        if capabilities?.npx.canRunSkills == false {
            problems.append(LifecycleBlocker.needsNpx.message)
        }
        return HostRemovalPlan(
            hostID: hostID, bucket: bucket, removed: removed, leftInPlace: kept,
            stillVisible: visible, sharedCopyDeletions: deletions, predictionUncertain: uncertain,
            settingHint: hostID == "opencode"
                ? "To hide skills in OpenCode, configure permission.skill (for example, \"*\": \"deny\")."
                : nil,
            problems: problems)
    }

    func planHostRemovals(
        _ requests: [HostRemovalRequest], report: ScanReport, context: HostRemovalContext?,
        capabilities: CapabilityReport?, into planned: inout PlannedDecisions
    ) {
        var projected = context
        for request in requests.sorted(by: { $0.id < $1.id }) {
            do {
                guard var current = projected else {
                    throw BatchBuildError(problems: [
                        "Host removal needs current disk evidence; scan again."
                    ])
                }
                let plan = try planHostRemoval(
                    hostID: request.hostID, bucket: request.bucket, report: report,
                    context: current, capabilities: capabilities)
                guard plan.problems.isEmpty else { throw BatchBuildError(problems: plan.problems) }
                guard request.names == plan.request.names else {
                    throw BatchBuildError(problems: [
                        "Host removal entries changed; review and queue the removal again."
                    ])
                }
                let facts = current.scopes[request.bucket]!
                let command = Self.hostRemovalCommand(plan, facts: facts)
                let alreadyPlanned = planned.commands.contains {
                    $0.argv == command.argv && $0.workingDirectory == command.workingDirectory
                }
                if !alreadyPlanned {
                    planned.commands.append(command)
                    planned.refs.append(
                        FindingRef(
                            findingID: request.id, ruleID: HostRemovalRequest.ruleID,
                            skillName: nil, workspaceID: request.bucket))
                    let deletedPaths = Set(plan.removed.map(\.path)).union(
                        plan.sharedCopyDeletions.map {
                            facts.sharedRoot + "/" + HostRemovalContext.folderName($0)
                        })
                    current.exclude(deletedPaths, bucket: request.bucket)
                    projected = current
                }
            } catch let error as BatchBuildError { planned.problems += error.problems } catch {
                planned.problems.append("\(error)")
            }
        }
    }

    private static func hostRemovalCommand(
        _ plan: HostRemovalPlan, facts: HostRemovalContext.ScopeFacts
    ) -> BatchCommand {
        let warning =
            plan.sharedCopyDeletions.isEmpty
            ? nil
            : "Also uninstalls \(plan.sharedCopyDeletions.joined(separator: ", ")) "
                + "from every agent and drops its lock entry."
        let consequence: CommandConsequence? =
            plan.sharedCopyDeletions.isEmpty
            ? nil
            : .removesLockedSkill(
                skill: plan.sharedCopyDeletions.joined(separator: ", "),
                deleting: plan.sharedCopyDeletions.map {
                    facts.sharedRoot + "/" + HostRemovalContext.folderName($0)
                })
        return BatchCommandFactory.vercelRemove(
            names: plan.request.names, agents: [plan.request.hostID],
            scope: plan.request.bucket == "user" ? .user : .project,
            atRisk: plan.sharedCopyDeletions.map {
                AtRiskSkill(skill: $0, ownership: Ownership.vercel.rawValue)
            },
            intent: "Remove Skills from Agent \(plan.request.hostID) in \(plan.request.bucket).",
            consequence: consequence,
            workingDirectory: Self.projectRoot(ofBucket: plan.request.bucket),
            captureRoots: [
                facts.nativeRoots[plan.request.hostID]!, facts.sharedRoot, facts.lockPath
            ],
            sharedCopyWarning: warning)
    }
}
