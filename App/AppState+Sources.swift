import Foundation
import SukiruCore

/// Finding sources for orphan skills: skills.sh listings with the same name,
/// verified against the local `SKILL.md` (`SourceMatcher`). Matching every
/// orphan at once queues adoption of each verified match, so the user only
/// reviews the cart instead of typing repositories.
@MainActor
extension AppState {
    enum SourceLookup: Equatable {
        case searching
        case found([SourceCandidate])
        case failed(String)

        /// The strongest candidate whose content was confirmed.
        var verifiedMatch: SourceCandidate? {
            guard case .found(let candidates) = self else { return nil }
            return candidates.first { $0.match >= .similar }
        }
    }

    /// Lookups run a handful at a time to stay polite to skills.sh and GitHub.
    nonisolated private static let concurrentLookups = 4

    /// Adopting a found source runs `npx skills add`, so it needs Node.js.
    var canAdoptFromSource: Bool {
        capabilities?.npx.canRunSkills != false
    }

    func sourceLookup(for skill: Skill) -> SourceLookup? {
        sourceLookups[Self.skillID(skill)]
    }

    var sourceMatchingInFlight: Bool {
        sourceLookups.values.contains(.searching)
    }

    /// Opens the source picker for an orphan, looking it up unless a result
    /// is already on hand.
    func findSource(for skill: Skill) {
        sourceSheetSkill = skill
        switch sourceLookup(for: skill) {
        case .searching, .found: break
        case .failed, nil: lookUpSources(for: [skill], queueMatches: false)
        }
    }

    /// Looks up every orphan among the entries and queues adoption of each
    /// verified match.
    func matchSources(_ entries: [FindingEntry]) {
        let orphans = entries.compactMap { entry -> Skill? in
            guard ProblemKind.of(entry.finding) == .orphan else { return nil }
            return skill(matching: entry.finding)
        }
        lookUpSources(for: orphans, queueMatches: true)
    }

    private func lookUpSources(for skills: [Skill], queueMatches: Bool) {
        let jobs = skills.compactMap { skill -> (skill: Skill, directory: String)? in
            guard sourceLookup(for: skill) != .searching,
                let directory = skill.placements.first(where: { $0.kind == .directory })?.path
            else { return nil }
            return (skill, directory)
        }
        guard !jobs.isEmpty else { return }
        for job in jobs {
            sourceLookups[Self.skillID(job.skill)] = .searching
        }
        let matcher = SourceMatcher(transport: URLSessionMarketplaceTransport())
        Task.detached(priority: .userInitiated) { [weak self] in
            await withTaskGroup(of: (Skill, SourceLookup).self) { group in
                var started = 0
                while started < min(Self.concurrentLookups, jobs.count) {
                    let job = jobs[started]
                    group.addTask {
                        (job.skill, await Self.lookUp(job.skill, job.directory, matcher))
                    }
                    started += 1
                }
                while let (skill, lookup) = await group.next() {
                    await self?.finishLookup(lookup, for: skill, queueMatch: queueMatches)
                    if started < jobs.count {
                        let job = jobs[started]
                        group.addTask {
                            (job.skill, await Self.lookUp(job.skill, job.directory, matcher))
                        }
                        started += 1
                    }
                }
            }
        }
    }

    nonisolated private static func lookUp(
        _ skill: Skill, _ directory: String, _ matcher: SourceMatcher
    ) async -> SourceLookup {
        let path = HostPathResolver.join(directory, "SKILL.md")
        let local = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        do {
            return .found(try await matcher.candidates(name: skill.name, localSkillMD: local))
        } catch {
            return .failed(UserFacingError.message(for: error))
        }
    }

    private func finishLookup(_ lookup: SourceLookup, for skill: Skill, queueMatch: Bool) {
        sourceLookups[Self.skillID(skill)] = lookup
        guard queueMatch, canAdoptFromSource, let match = lookup.verifiedMatch,
            let finding = orphanFinding(for: skill), cartItem(for: finding) == nil
        else { return }
        queue(.adopt, choice: .adoptVercel(source: match.installSource), for: finding)
    }
}
