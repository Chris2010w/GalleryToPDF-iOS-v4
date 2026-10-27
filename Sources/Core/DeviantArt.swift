import Foundation

/// DeviantArt video downloader. yt-dlp has no DeviantArt extractor, so we read the page ourselves,
/// look for direct video files (wixmp CDN) and fall back to DeviantArt's own JSON endpoints.
final class DeviantArtEngine {
    private let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\\u002F", with: "/")
         .replacingOccurrences(of: "\\u0026", with: "&")
         .replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "&amp;", with: "&")
    }

    private func videoURLs(in raw: String) -> [String] {
        let t = clean(raw)
        guard let re = try? NSRegularExpression(pattern: #"https?://[^"'\s<>\\)]+?\.(?:mp4|webm|m4v)(?:\?[^"'\s<>\\)]*)?"#, options: [.caseInsensitive]) else { return [] }
        let ns = t as NSString
        var out: [String] = []
        for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range)
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    private func score(_ u: String) -> Int {
        let l = u.lowercased()
        var s = 0
        if l.contains(".mp4") { s += 1000 }
        if let r = try? NSRegularExpression(pattern: #"(\d{3,4})p"#),
           let m = r.firstMatch(in: l, range: NSRange(location: 0, length: (l as NSString).length)) {
            s += Int((l as NSString).substring(with: m.range(at: 1))) ?? 0
        }
        if l.contains("preview") || l.contains("thumb") { s -= 5000 }
        return s
    }

    func run(url: String, nameIn: String, outDir: String, workRoot: String, cb: Reporter) async throws -> [String] {
        let fm = FileManager.default
        let jobDir = (workRoot as NSString).appendingPathComponent("da_" + UUID().uuidString)
        try fm.createDirectory(atPath: jobDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: jobDir) }

        cb.log("== DeviantArt βίντεο ==")
        cb.progress(0, 0, "Ανάγνωση σελίδας DeviantArt...")
        let f = Fetcher()
        f.extraHeaders = ["User-Agent": desktopUA, "Accept-Language": "en-US,en;q=0.9"]

        var candidates: [String] = []
        var title = ""
        var html = ""
        let id = regexFirst(#"-(\d{6,})(?:[/?#]|$)"#, url)?[1] ?? regexFirst(#"(\d{6,})"#, url)?[1] ?? ""
        let user = regexFirst(#"deviantart\.com/([^/]+)/"#, url)?[1] ?? ""
        cb.log("Deviation id: \(id)")

        do {
            html = try await f.text(url)
            cb.log("Σελίδα: \(html.count) χαρακτήρες")
            if let m = regexFirst(#"<title>([^<]+)</title>"#, html) { title = htmlUnescape(m[1]) }
        } catch {
            cb.log("Η σελίδα δεν ανοίγει: \(error.localizedDescription)")
        }

        // 1) API keyed by this exact deviation id: everything in it belongs to this video.
        if !id.isEmpty {
            let api = "https://www.deviantart.com/_napi/da-browse/shared_api/deviation/extended_fetch?deviationid=\(id)&username=\(user)&type=art&include_session=false"
            do {
                let j = try await f.text(api, referer: url)
                cb.log("API: \(j.count) χαρακτήρες")
                candidates += videoURLs(in: j)
                if title.isEmpty, let m = regexFirst(#""title":"([^"]+)""#, j) { title = htmlUnescape(m[1]) }
                cb.log("Βίντεο από API: \(candidates.count)")
                if candidates.isEmpty { cb.log("API απάντηση: " + String(clean(j).prefix(300))) }
            } catch {
                cb.log("API σφάλμα: \(error.localizedDescription)")
            }
        }

        // 2) Page: only the JSON object of THIS deviation (the page also holds other videos of the same artist).
        if candidates.isEmpty, !html.isEmpty, !id.isEmpty {
            let t = clean(html)
            let chars = Array(t.utf8)
            var found: [String] = []
            for pat in ["\"deviationId\":\(id)", "\"deviationId\":\"\(id)\""] {
                var from = t.startIndex
                while let r = t.range(of: pat, range: from..<t.endIndex) {
                    let pos = t.utf8.distance(from: t.startIndex, to: r.lowerBound)
                    // walk back to the opening brace of the enclosing object
                    var depth = 0, i = pos, start = -1
                    while i >= 0 {
                        let c = chars[i]
                        if c == 125 { depth += 1 } else if c == 123 { if depth == 0 { start = i; break }; depth -= 1 }
                        i -= 1
                    }
                    if start >= 0 {
                        depth = 0; var e = start; var end = -1
                        while e < chars.count {
                            let c = chars[e]
                            if c == 123 { depth += 1 } else if c == 125 { depth -= 1; if depth == 0 { end = e; break } }
                            e += 1
                        }
                        if end > start, let sub = String(bytes: chars[start...end], encoding: .utf8) {
                            found += videoURLs(in: sub)
                        }
                    }
                    from = r.upperBound
                }
            }
            for u in found where !candidates.contains(u) { candidates.append(u) }
            cb.log("Βίντεο από το αντικείμενο της σελίδας: \(candidates.count)")
        }

        // Fallback 2: oEmbed
        if candidates.isEmpty {
            let enc = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
            if let j = try? await f.text("https://backend.deviantart.com/oembed?url=\(enc)") {
                cb.log("oEmbed: " + String(clean(j).prefix(300)))
                candidates += videoURLs(in: j)
            }
        }

        guard !candidates.isEmpty else {
            if html.lowercased().contains("log in") || html.lowercased().contains("mature") {
                cb.log("Η σελίδα ζητά login / mature content.")
            }
            throw JobError.message("Δεν βρήκα βίντεο σε αυτό το link DeviantArt (δες το log).")
        }
        // Check every candidate's real size: the page also contains tiny previews/other videos. Pick the biggest.
        var sized: [(url: String, size: Int64)] = []
        for c in candidates.prefix(12) {
            var size: Int64 = -1
            if let cu = URL(string: c) {
                var r = URLRequest(url: cu)
                r.httpMethod = "GET"
                r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                r.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
                r.setValue("https://www.deviantart.com/", forHTTPHeaderField: "Referer")
                if let (_, resp) = try? await URLSession.shared.data(for: r), let h = resp as? HTTPURLResponse {
                    if let cr = h.value(forHTTPHeaderField: "Content-Range"), let tot = cr.split(separator: "/").last, let n = Int64(tot) { size = n }
                    else { size = h.expectedContentLength }
                    cb.log("• HTTP \(h.statusCode) \(size / 1024) KB  \(c.suffix(90))")
                } else {
                    cb.log("• δεν ανοίγει: \(c.suffix(90))")
                }
            }
            sized.append((c, size))
        }
        guard let pick = sized.max(by: { $0.size < $1.size }), pick.size > 200_000 else {
            throw JobError.message("Βρέθηκαν μόνο μικρά/άκυρα αρχεία βίντεο (δες το log).")
        }
        let best = pick.url
        cb.log("Επιλέχθηκε (\(pick.size / 1_048_576) MB): \(best.prefix(140))")

        var ext = "mp4"
        if let r = try? NSRegularExpression(pattern: #"\.(mp4|webm|m4v)(?:\?|$)"#, options: .caseInsensitive),
           let m = r.firstMatch(in: best, range: NSRange(location: 0, length: (best as NSString).length)) {
            ext = (best as NSString).substring(with: m.range(at: 1)).lowercased()
        }
        let base = safeName(nameIn.isEmpty ? (title.isEmpty ? "deviantart_video" : title) : nameIn)
        try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let dst = URL(fileURLWithPath: outDir).appendingPathComponent(base + "." + ext)
        let tmp = URL(fileURLWithPath: jobDir).appendingPathComponent("v." + ext)

        guard let u = URL(string: best) else { throw JobError.message("Μη έγκυρο URL βίντεο.") }
        var req = URLRequest(url: u)
        req.setValue(desktopUA, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.deviantart.com/", forHTTPHeaderField: "Referer")
        cb.log("Λήψη βίντεο...")
        try await FileDownloader().download(req, to: tmp) { got, exp in
            let mb = Double(got) / 1_048_576
            if exp > 0 {
                let frac = Double(got) / Double(exp)
                cb.progress(Int(frac * 1000), 1000, "Λήψη \(Int(frac * 100))% (\(Int(mb)) MB)")
                cb.download(Int(got), Int(exp))
            } else {
                cb.progress(0, 0, "Λήψη \(Int(mb)) MB")
            }
        }
        try? fm.removeItem(at: dst)
        try fm.moveItem(at: tmp, to: dst)
        cb.progress(1000, 1000, "Έτοιμο ✔")
        cb.log("Έτοιμο: \(dst.lastPathComponent)")
        return [dst.path]
    }
}
