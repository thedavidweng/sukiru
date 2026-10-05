import Foundation

extension RealCLIE2ESupport {
    /// Installs `npx`/`gh` passthrough wrappers into `tree/bin`: each logs
    /// `argv|cwd` to the transcript and its env (token PRESENCE only) to a
    /// per-tool dump, then execs the real binary. Returns the bin path to
    /// prepend to the CLI child's PATH.
    static func installToolWrappers(
        _ tools: RealTools, into tree: TempTree, skillsVersion: String? = nil
    ) throws -> String {
        let logDir = try tree.dir("tool-log")
        let envDump = """
              echo "HOME=$HOME"
              echo "PWD=$PWD"
              if [ -n "${GH_TOKEN:-}" ]; then echo "GH_TOKEN=present"; else echo "GH_TOKEN=absent"; fi
            """
        let pin =
            skillsVersion.map { version in
                """
                for arg do
                  shift
                  if [ "$arg" = "skills" ]; then
                    set -- "$@" "skills@\(version)"
                  else
                    set -- "$@" "$arg"
                  fi
                done
                """
            } ?? ""
        let npxWrapper = """
            #!/bin/sh
            echo "npx|$PWD|$*" >> "\(logDir)/transcript.log"
            {
            \(envDump)
            } >> "\(logDir)/env-npx.log"
            \(pin)
            exec "\(tools.node)" "\(tools.npxCLI)" "$@"
            """
        let ghWrapper = """
            #!/bin/sh
            echo "gh|$PWD|$*" >> "\(logDir)/transcript.log"
            {
            \(envDump)
            } >> "\(logDir)/env-gh.log"
            exec "\(tools.ghBinary)" "$@"
            """
        // `node` itself must ALSO be on PATH: the npx-downloaded skills
        // package bin has a `#!/usr/bin/env node` shebang, and the child
        // PATH (bin + /usr/bin:/bin) carries no node otherwise.
        let nodeWrapper = """
            #!/bin/sh
            exec "\(tools.node)" "$@"
            """
        try tree.executable("bin/npx", contents: npxWrapper)
        try tree.executable("bin/gh", contents: ghWrapper)
        try tree.executable("bin/node", contents: nodeWrapper)
        return tree.path + "/bin"
    }

}
