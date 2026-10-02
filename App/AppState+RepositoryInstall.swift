import Foundation
import SukiruCore

/// What the install sheet installs: the selected search result, or skills
/// picked from a typed repository.
enum InstallOrigin: Equatable {
    case searchResult
    case repository
}

/// Listing a typed repository through the chosen installer's CLI. A
/// listing belongs to the installer that produced it: the two CLIs name the
/// same repository's skills differently.
enum RepositoryListingPhase: Equatable {
    case idle
    case listing
    case listed(repo: String, installer: InstallerChoice, skills: [RepositorySkill])
    case failed(String)
}

/// The typed-repository flow: the source as typed, the installer's listing
/// of it, and the skills picked from that listing.
struct RepositoryInstall {
    var source = ""
    var listing: RepositoryListingPhase = .idle
    var selection: Set<String> = []
    /// Identifies the latest listing; stale completions are dropped.
    var generation = 0
}

/// Install from Repository: type a source, list its skills with the
/// installer that will install them, pick several or all, and send one
/// Command Batch to Pending Changes.
@MainActor
extension AppState {
    /// Opens the install sheet with an empty repository source.
    func presentRepositoryInstallSheet() {
        surface = .search
        resetInstallSheet(origin: .repository)
        repositoryInstall = RepositoryInstall(generation: repositoryInstall.generation + 1)
        showingInstallSheet = true
    }

    /// The skills of the current listing, when it matches the chosen
    /// installer.
    var listedRepositorySkills: [RepositorySkill] {
        guard case .listed(_, let installer, let skills) = repositoryInstall.listing,
            installer == installInstaller
        else { return [] }
        return skills
    }

    /// Lists the typed source's skills with the chosen installer, off the
    /// main actor. A newer listing supersedes an older one in flight.
    func listRepositorySkills() {
        let repo: String
        do {
            repo = try InstallPlanBuilder.ownerRepo(fromSource: repositoryInstall.source)
        } catch {
            repositoryInstall.listing = .failed(UserFacingError.message(for: error))
            return
        }
        guard installCapabilityAvailable(installInstaller) else {
            repositoryInstall.listing = .failed(
                installInstaller == .vercel
                    ? String(localized: "install.error.needsNode")
                    : String(localized: "install.error.needsGitHub"))
            return
        }
        // The listing runs npx offline, so it cannot fetch a CLI that is
        // not on this Mac yet.
        if installInstaller == .vercel, capabilities?.npx.reason == .notDownloaded {
            repositoryInstall.listing = .failed(
                String(localized: "install.error.skillsNotDownloaded"))
            return
        }
        repositoryInstall.generation += 1
        let generation = repositoryInstall.generation
        let installer = installInstaller
        let lister = RepositorySkillLister(environment: environment)
        repositoryInstall.listing = .listing
        repositoryInstall.selection = []
        Task.detached(priority: .userInitiated) { [weak self] in
            let phase: RepositoryListingPhase
            do {
                let skills = try lister.skills(in: repo, installer: installer)
                phase = .listed(repo: repo, installer: installer, skills: skills)
            } catch {
                phase = .failed(UserFacingError.message(for: error))
            }
            await self?.applyRepositoryListing(phase, generation: generation)
        }
    }

    private func applyRepositoryListing(_ phase: RepositoryListingPhase, generation: Int) {
        guard generation == repositoryInstall.generation else { return }
        repositoryInstall.listing = phase
        if case .listed(_, _, let skills) = phase, skills.count == 1 {
            repositoryInstall.selection = [skills[0].name]
        }
    }

    /// The installer changed: an existing listing names skills the new
    /// installer may not recognize, so the source is listed again.
    func installerChangedForRepository() {
        guard installOrigin == .repository, repositoryInstall.listing != .idle else { return }
        listRepositorySkills()
    }

    /// Selects every listed skill, or clears the selection when all are
    /// already selected.
    func toggleAllRepositorySkills() {
        let names = Set(listedRepositorySkills.map(\.name))
        repositoryInstall.selection = repositoryInstall.selection == names ? [] : names
    }

    /// The selected skills in listing order, with the repository they
    /// came from.
    func selectedRepositorySkills() -> (repo: String, skills: [String])? {
        guard case .listed(let repo, _, _) = repositoryInstall.listing else { return nil }
        let skills = listedRepositorySkills.map(\.name)
            .filter(repositoryInstall.selection.contains)
        return skills.isEmpty ? nil : (repo, skills)
    }
}
