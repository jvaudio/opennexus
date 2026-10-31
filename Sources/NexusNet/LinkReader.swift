import Foundation
import NexusCore
import NexusFormat

/// Open in OpenNexus (M47d, D441): a share link's sealed map, read from the link's own
/// hosts without credentials, as the viewer site reads it (M44): a URL as it is, a gist
/// through GitHub's API, and a gist over 1 MB from its raw address.
enum LinkReader {
    /// Where GitHub serves a gist file the API cuts short.
    static let rawGistHost = "gist.githubusercontent.com"

    /// A deleted object: 404 (a server, a gist), 410 (an expired share) or 403 (a bucket
    /// that doesn't let readers list what's missing). The link is turned off.
    static let off: Set<Int> = [403, 404, 410]

    /// The hosts reading the link may reach; nil when the link can't be read safely.
    static func hosts(source: ShareLinkCode.Source, locator: String) -> [String]? {
        switch source {
        case .url:
            guard let u = URL(string: locator), ShareDestination.secure(u), u.user() == nil, u.password() == nil,
                let host = u.host()?.lowercased()
            else { return nil }
            return [host]
        case .gist:
            guard GistTarget.valid(locator), let api = URL(string: ShareDestination.githubAPI)?.host() else {
                return nil
            }
            return [api, rawGistHost]
        }
    }

    static func read(source: ShareLinkCode.Source, locator: String, client: HTTPClient) async throws -> Data {
        switch source {
        case .url:
            return try check(await client.send(HTTPRequest("GET", try url(locator)))).body
        case .gist:
            let headers = [
                "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "OpenNexus",
            ]
            let r = try check(
                await client.send(
                    HTTPRequest("GET", try url("\(ShareDestination.githubAPI)/gists/\(locator)"), headers: headers)))
            guard let file = (try? CanonicalJSON.parse(r.body))?["files"]?[GistTarget.file] else {
                throw NetError.unexpected("the gist holds no shared map")
            }
            var text = file["content"]?.stringValue
            if file["truncated"]?.boolValue == true {
                guard let raw = file["raw_url"]?.stringValue.flatMap(URL.init(string:)), raw.scheme == "https",
                    raw.host()?.lowercased() == rawGistHost
                else { throw NetError.unexpected("the gist’s file is somewhere else") }
                text = String(
                    decoding: try check(
                        await client.send(HTTPRequest("GET", raw, headers: ["User-Agent": "OpenNexus"]))
                    ).body, as: UTF8.self)
            }
            guard let text, let data = Data(base64Encoded: text.filter { !$0.isWhitespace }) else {
                throw NetError.unexpected("the gist’s file isn’t a shared map")
            }
            return data
        }
    }

    static func check(_ r: HTTPResponse) throws -> HTTPResponse {
        guard r.ok else { throw NetError.status(r.status, off.contains(r.status) ? "the link is turned off" : "") }
        return r
    }
}
