import Foundation

/// Outbound links to this repository, opened in the user's browser.
///
/// Every URL here is compiled into every shipped binary and cannot be changed
/// for installs already in the field, so each one is built to degrade rather
/// than break — the same constraint `SUFeedURL` lives under (docs/RELEASING.md).
///
/// `integrationRequest` routes through the issue *template* rather than
/// carrying `?labels=integration-request` the way the site's form does
/// (`site/components/sections/Integrations.tsx`). GitHub rejects the entire URL
/// if a label named in it no longer exists, which would strand every older
/// install on a dead link; a missing template merely falls back to the issue
/// chooser. The template applies the label server-side, and that label is what
/// `.github/workflows/integration-triage.yml` triggers on.
enum RunbarLinks {
    private static let repositoryPath = "https://github.com/markoradak/runbar"

    static let repository = URL(string: repositoryPath)!

    static let integrationRequest = URL(
        string: "\(repositoryPath)/issues/new?template=integration-request.yml"
    )!
}
