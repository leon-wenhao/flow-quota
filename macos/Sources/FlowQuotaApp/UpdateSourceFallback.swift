import Foundation

/// A check starts on GitHub every time. Only an unsuccessful probe selects Gitee;
/// an authenticated, valid "no update" result is a success and never retries.
@MainActor final class UpdateSourceFallback {
    enum Next: Equatable { case probe, resolveGitee, interactive, done, failed(String) }
    private(set) var manual = false
    private(set) var probing = false
    private(set) var feedURL: URL?
    private(set) var source = "GitHub"
    private var primaryFailure: String?

    func begin(manual: Bool) -> Next {
        self.manual = manual
        probing = true
        feedURL = nil
        source = "GitHub"
        primaryFailure = nil
        return .probe
    }

    func probeFinished(failure: String?, fallbackAllowed: Bool = true) -> Next {
        if let failure {
            if source == "GitHub", !fallbackAllowed {
                probing = false
                return .failed("GitHub：\(failure)")
            }
            if source == "GitHub" {
                primaryFailure = failure
                source = "Gitee"
                return .resolveGitee
            }
            return giteeFailed(failure)
        }
        probing = false
        return manual ? .interactive : .done
    }

    func resolvedGitee(_ url: URL) -> Next {
        feedURL = url
        return .probe
    }

    func cancel() { probing = false }

    func giteeFailed(_ failure: String) -> Next {
        probing = false
        return .failed("GitHub：\(primaryFailure ?? "检查失败")\nGitee：\(failure)")
    }
}
