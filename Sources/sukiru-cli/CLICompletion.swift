import Foundation
import SukiruCore

extension CLI {
    static func completionScript(_ tokens: [String]) throws -> String? {
        let options = tokens.prefix { $0 != "--" }
        guard
            let index = options.firstIndex(where: {
                $0 == "--generate-completion-script"
                    || $0.hasPrefix("--generate-completion-script=")
            })
        else { return nil }
        let token = tokens[index]
        let shell: String
        if let separator = token.firstIndex(of: "=") {
            shell = String(token[token.index(after: separator)...])
        } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
            shell = tokens[index + 1]
        } else {
            shell =
                URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "")
                .lastPathComponent
        }
        switch shell {
        case "bash": return bashCompletion()
        case "zsh": return zshCompletion()
        case "fish": return fishCompletion()
        default:
            throw CLIUsageError(
                "Can't generate completion scripts for '\(shell)'. "
                    + "Use --generate-completion-script=<shell> with bash, zsh or fish."
            )
        }
    }

    private static func completionChoices(_ name: String) -> [String] {
        switch name {
        case "scope": return Scope.allCases.map(\.rawValue)
        case "installer": return InstallerChoice.allCases.map(\.rawValue)
        case "mode": return PlacementMode.allCases.map(\.rawValue)
        case "backend": return SkillSearchResult.Backend.allCases.map(\.rawValue)
        default: return []
        }
    }

    private static func completionContext(_ command: CLICommand) -> String {
        command.path.isEmpty ? "sukiru" : "sukiru " + command.path
    }

    private static var valueOptions: [CLIOption] {
        var names: Set<String> = []
        return commands.flatMap(\.options).filter {
            $0.takesValue && names.insert($0.name).inserted
        }
    }

    private static func completionCandidates(_ command: CLICommand) -> [String] {
        let prefix = command.path.isEmpty ? "" : command.path + " "
        let children = commands.filter {
            $0.path.hasPrefix(prefix) && $0.path != command.path
                && !$0.path.dropFirst(prefix.count).contains(" ")
        }.map { String($0.path.dropFirst(prefix.count)) }
        return children + (command.path.isEmpty ? ["help"] : [])
            + (command.options + builtIns).map { "--" + $0.name }
            + ["-h"] + (command.options.contains { $0.name == "yes" } ? ["-y"] : [])
    }

    private static var contextCases: String {
        commands.filter { !$0.path.isEmpty }.map {
            "      '\(completionContext($0))') context='\(completionContext($0))';;"
        }.joined(separator: "\n")
    }

    private static var candidateCases: String {
        commands.map {
            "      '\(completionContext($0))') candidates='\(completionCandidates($0).joined(separator: " "))';;"
        }.joined(separator: "\n")
    }

    private static var valueCases: String {
        valueOptions.map {
            "      '--\($0.name)') candidates='\(completionChoices($0.name).joined(separator: " "))';;"
        }.joined(separator: "\n")
    }

    private static var valuePatterns: String {
        valueOptions.map { "--" + $0.name }.joined(separator: "|")
    }

    private static func bashCompletion() -> String {
        """
        #!/bin/bash
        _sukiru() {
          local context=sukiru expecting='' word candidates='' i cur="${COMP_WORDS[COMP_CWORD]}"
          for ((i=1; i<COMP_CWORD; i++)); do
            word="${COMP_WORDS[i]}"
            if [[ -n "$expecting" ]]; then expecting=''; continue; fi
            case "$context $word" in
        \(contextCases)
            esac
            case "$word" in \(valuePatterns)) expecting="$word";; esac
          done
          if [[ "$cur" == --*=* ]]; then
            expecting="${cur%%=*}"
            cur="${cur#*=}"
          fi
          if [[ -n "$expecting" ]]; then
            case "$expecting" in
        \(valueCases)
            esac
          else
            case "$context" in
        \(candidateCases)
            esac
          fi
          COMPREPLY=($(compgen -W "$candidates" -- "$cur"))
          if [[ "${COMP_WORDS[COMP_CWORD]}" == --*=* ]]; then
            for ((i=0; i<${#COMPREPLY[@]}; i++)); do COMPREPLY[i]="$expecting=${COMPREPLY[i]}"; done
          fi
        }
        complete -F _sukiru sukiru
        """
    }

    private static func zshCompletion() -> String {
        """
        #compdef sukiru
        _sukiru() {
          local context=sukiru expecting='' word candidates='' i
          for ((i=2; i<CURRENT; i++)); do
            word="${words[i]}"
            if [[ -n "$expecting" ]]; then expecting=''; continue; fi
            case "$context $word" in
        \(contextCases)
            esac
            case "$word" in \(valuePatterns)) expecting="$word";; esac
          done
          if [[ "$PREFIX" == --*=* ]]; then
            expecting="${PREFIX%%=*}"
            compset -P '*='
          fi
          if [[ -n "$expecting" ]]; then
            case "$expecting" in
        \(valueCases)
            esac
          else
            case "$context" in
        \(candidateCases)
            esac
          fi
          compadd -- ${=candidates}
        }
        compdef _sukiru sukiru
        """
    }

    private static func fishCompletion() -> String {
        let cases = commands.filter { !$0.path.isEmpty }.map {
            "      case '\(completionContext($0))'\n        set context '\(completionContext($0))'"
        }.joined(separator: "\n")
        var lines = [
            """
            function __sukiru_context
              set -l context sukiru
              set -l expecting ''
              for word in (commandline -opc)[2..-1]
                if test -n "$expecting"
                  set expecting ''
                  continue
                end
                switch "$context $word"
            \(cases)
                end
                switch "$word"
                  case \(valueOptions.map { "'--" + $0.name + "'" }.joined(separator: " "))
                    set expecting "$word"
                end
              end
              echo "$context"
            end
            """
        ]
        for command in commands {
            let condition = "-n 'test (__sukiru_context) = \"\(completionContext(command))\"'"
            let names = completionCandidates(command).filter { !$0.hasPrefix("-") }
            lines.append("complete -c sukiru -f \(condition) -a '\(names.joined(separator: " "))'")
            for option in command.options + builtIns {
                let values = completionChoices(option.name).joined(separator: " ")
                let short = option.name == "help" ? " -s h" : option.name == "yes" ? " -s y" : ""
                let required = option.takesValue ? " -r" : ""
                lines.append(
                    "complete -c sukiru \(condition) -l \(option.name)\(short)\(required) -a '\(values)'"
                )
            }
        }
        return lines.joined(separator: "\n")
    }
}
