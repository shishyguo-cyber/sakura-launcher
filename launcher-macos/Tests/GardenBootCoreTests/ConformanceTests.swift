import XCTest
import CoreGraphics
@testable import GardenBootCore

/// Runs the shared cases in `launcher-spec/conformance/` — the Windows port runs the same files,
/// so both launchers must behave identically.
final class ConformanceTests: XCTestCase {
    private static let specDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("launcher-spec/conformance")

    private func load(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.specDirectory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rect(_ value: Any?) -> CGRect {
        let n = (value as? [NSNumber] ?? []).map { CGFloat($0.doubleValue) }
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : .null
    }

    // MARK: Playback

    private func layout(_ raw: [String: Any]) -> PackLayout {
        PackLayout(intro: raw["intro"] as? String, loop: raw["loop"] as? String, final: raw["final"] as! String,
                   finalSegment: PackSegment(rawValue: raw["finalSegment"] as! String)!)
    }

    private func event(_ raw: [String: Any]) -> PlaybackEvent {
        switch raw["event"] as! String {
        case "start": return .start(windowReady: raw["windowReady"] as! Bool)
        case "windowReady": return .windowReady
        case "segmentEnded": return .segmentEnded(PackSegment(rawValue: raw["segment"] as! String)!)
        case "loopCycleEnded": return .loopCycleEnded
        case "reachedHandoff": return .reachedHandoff
        case "fadeCompleted": return .fadeCompleted
        case "skip": return .skip
        case "waitTimedOut": return .waitTimedOut
        case "targetExited": return .targetExited
        case "targetHidden": return .targetHidden
        case "userSwitched": return .userSwitched
        case "superseded": return .superseded
        case "failed": return .failed(raw["why"] as! String)
        case let other: fatalError("unknown event \(other)")
        }
    }

    /// Commands rendered to a canonical string so mismatches read clearly in both ports.
    private func describe(_ command: PlaybackCommand) -> String {
        switch command {
        case .showOnLaunchScreen: return "showOnLaunchScreen"
        case .showOnTargetWindow: return "showOnTargetWindow"
        case .moveToTargetWindow(let animated): return "moveToTargetWindow animated=\(animated)"
        case .play(let segment, let looping): return "play \(segment.rawValue) looping=\(looping)"
        case .holdLastFrame: return "holdLastFrame"
        case .beginFade(let duration): return "beginFade \(String(format: "%.2f", duration))"
        case .close(let reason, let visible): return "close \(reason.logName) visible=\(visible)"
        }
    }

    private func describe(_ raw: [String: Any]) -> String {
        switch raw["command"] as! String {
        case "moveToTargetWindow": return "moveToTargetWindow animated=\(raw["animated"] as! Bool)"
        case "play": return "play \(raw["segment"] as! String) looping=\(raw["looping"] as! Bool)"
        case "beginFade": return "beginFade \(String(format: "%.2f", (raw["duration"] as! NSNumber).doubleValue))"
        case "close": return "close \(raw["reason"] as! String) visible=\(raw["wasVisible"] as! Bool)"
        case let simple: return simple
        }
    }

    func testPlaybackCases() throws {
        let spec = try load("playback.json")
        let fade = (spec["fadeDuration"] as! NSNumber).doubleValue
        let cases = spec["cases"] as! [[String: Any]]
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let exit = (c["loopExit"] as? String).flatMap(LoopExit.init(rawValue:)) ?? .cycleEnd
            var machine = PlaybackMachine(layout: layout(c["layout"] as! [String: Any]), fadeDuration: fade, loopExit: exit)
            for (index, step) in (c["steps"] as! [[String: Any]]).enumerated() {
                let got = machine.handle(event(step["event"] as! [String: Any])).map(describe)
                let want = (step["expect"] as! [[String: Any]]).map(describe)
                XCTAssertEqual(got, want, "\(name) step \(index)")
            }
        }
    }

    // MARK: Manifest

    func testManifestCases() throws {
        let spec = try load("manifest.json")
        for c in spec["manifests"] as! [[String: Any]] {
            let name = c["name"] as! String
            let data = try JSONSerialization.data(withJSONObject: c["json"]!)
            let result = Result { try JSONDecoder().decode(PackManifest.self, from: data).validatedLayout() }
            if c.keys.contains("expectCover"), c["valid"] as! Bool {
                let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
                XCTAssertEqual(encoded["cover"] as? String, c["expectCover"] as? String, name)
            }
            if let expected = c["expectVideoFit"] as? String, c["valid"] as! Bool {
                let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any])
                XCTAssertEqual(encoded["videoFit"] as? String, expected, name)
            }
            if c.keys.contains("expectTextOverlay") {
                let manifest = try JSONDecoder().decode(PackManifest.self, from: data)
                let roundTrip = try JSONDecoder().decode(PackManifest.self, from: JSONEncoder().encode(manifest))
                XCTAssertEqual(roundTrip.textOverlay, c["expectTextOverlay"] as? String, name)
                XCTAssertEqual(manifest.showsGreeting, c["showsGreeting"] as? Bool, name)
            }
            if c["valid"] as! Bool {
                let got = try result.get()
                let want = c["layout"] as! [String: Any]
                XCTAssertEqual(got, layout(want), name)
                XCTAssertEqual(got.coversLaunch, want["coversLaunch"] as! Bool, name)
            } else {
                XCTAssertThrowsError(try result.get(), name)
            }
        }
        for c in spec["handoff"] as! [[String: Any]] {
            let manifest = PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"],
                                        handoffAt: (c["handoffAt"] as? NSNumber)?.doubleValue,
                                        fadeDuration: (c["fadeDuration"] as? NSNumber)?.doubleValue)
            XCTAssertEqual(manifest.handoffTime(finalDuration: (c["finalDuration"] as! NSNumber).doubleValue),
                           (c["expect"] as! NSNumber).doubleValue, accuracy: 1e-9, "\(c)")
        }
    }

    func testGreetingLightUsesLocalDaypart() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let cases: [(Int, Greeting.Light, String)] = [
            (0, .moonlight, "Good evening"), (4, .moonlight, "Good evening"),
            (5, .dawn, "Good morning"), (11, .dawn, "Good morning"),
            (12, .daylight, "Good afternoon"), (17, .daylight, "Good afternoon"),
            (18, .dusk, "Good evening"), (22, .dusk, "Good evening"),
            (23, .moonlight, "Good evening"),
        ]
        for (hour, light, text) in cases {
            let date = try XCTUnwrap(calendar.date(from: .init(year: 2026, month: 11, day: 20, hour: hour)))
            XCTAssertEqual(Greeting.light(at: date, calendar: calendar), light)
            XCTAssertEqual(Greeting.text(at: date, calendar: calendar, name: nil), text)
        }
    }

    func testGreetingReduceMotionUsesStillTreatmentForEitherStyle() {
        for style in [Greeting.Style.pen, .sweep, .script] {
            let still = Greeting.Treatment(style: style, reduceMotion: true)
            XCTAssertEqual(still, .still)
            XCTAssertFalse(still.allowsDocking)
            let animated = Greeting.Treatment(style: style, reduceMotion: false)
            XCTAssertEqual(animated, .animated(style))
            XCTAssertTrue(animated.allowsDocking)
        }
    }

    func testGreetingCases() throws {
        let spec = try load("greeting.json")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        for c in spec["messages"] as! [[String: Any]] {
            calendar.locale = Locale(identifier: c["language"] as! String)
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: c["hour"] as? Int)))
            XCTAssertEqual(Greeting.text(at: date, calendar: calendar, name: c["name"] as? String),
                           c["expect"] as? String, "\(c)")
        }
        for c in spec["names"] as! [[String: Any]] {
            if c["invalid"] as? Bool == true {
                XCTAssertThrowsError(try Greeting.normalizedName(c["input"] as? String))
            } else {
                XCTAssertEqual(try Greeting.normalizedName(c["input"] as? String), c["expect"] as? String)
            }
        }
    }

    func testExperienceSections() throws {
        for c in try load("experience.json")["cases"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: c["settings"]!)
            if !(c["valid"] as! Bool) { XCTAssertThrowsError(try ExperienceSettings.decode(data), c["name"] as! String); continue }
            let settings = try ExperienceSettings.decode(data)
            if let expected = c["expectTargets"] as? [String] {
                XCTAssertEqual(settings.targets.map(\.id), expected, c["name"] as! String)
            }
            if let expected = c["expectVideoFit"] as? String {
                let resolved = try settings.resolved(PackManifest(id: "a", name: "A", segments: [.video: "v.mp4"]))
                let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved)) as? [String: Any])
                XCTAssertEqual(encoded["videoFit"] as? String ?? "auto", expected, c["name"] as! String)
            }
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
            for (expect, field) in [("expectPlayback", "playback"), ("expectLibrary", "library")] {
                if let wanted = c[expect] as? [String: Any] {
                    // Compare the listed fields; later optional fields (quietWhenFullscreen) carry their defaults.
                    let got = encoded[field] as? [String: Any] ?? [:]
                    XCTAssertEqual(NSDictionary(dictionary: got.filter { wanted.keys.contains($0.key) }), NSDictionary(dictionary: wanted), c["name"] as! String)
                }
            }
        }
    }

    // MARK: Geometry and policy

    func testVideoFitCases() throws {
        let cases = try XCTUnwrap(try load("geometry.json")["videoFit"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let name = c["name"] as! String
            let size = c["frame"] as! [NSNumber]
            let got = VideoFit.resolve(mode: VideoFit.Mode(rawValue: c["mode"] as! String)!,
                frameSize: CGSize(width: size[0].doubleValue, height: size[1].doubleValue),
                videoAspect: CGFloat((c["videoAspect"] as! NSNumber).doubleValue))
            XCTAssertEqual(got.mode.rawValue, c["expect"] as! String, name)
            let want = rect(c["content"])
            XCTAssertEqual(got.contentRect.origin.x, want.origin.x, accuracy: 1e-6, name)
            XCTAssertEqual(got.contentRect.origin.y, want.origin.y, accuracy: 1e-6, name)
            XCTAssertEqual(got.contentRect.size.width, want.size.width, accuracy: 1e-6, name)
            XCTAssertEqual(got.contentRect.size.height, want.size.height, accuracy: 1e-6, name)
        }
    }

    func testGeometryCases() throws {
        let spec = try load("geometry.json")
        for c in spec["launchFrame"] as! [[String: Any]] {
            let got = OverlayGeometry.launchFrame(in: rect(c["visible"]), aspect: CGFloat((c["aspect"] as! NSNumber).doubleValue))
            XCTAssertEqual(got, rect(c["expect"]), "\(c)")
        }
        for c in spec["follow"] as! [[String: Any]] {
            XCTAssertEqual(OverlayGeometry.shouldFollow(current: rect(c["current"]), latest: rect(c["latest"])),
                           c["expect"] as! Bool, "\(c)")
        }
        for pair in spec["ease"] as! [[NSNumber]] {
            XCTAssertEqual(OverlayGeometry.ease(pair[0].doubleValue), pair[1].doubleValue, accuracy: 1e-9)
        }
    }

    func testPolicyCases() throws {
        let spec = try load("policy.json")
        for c in spec["launchFilter"] as! [[String: Any]] {
            let got = LaunchFilter.skip(targetHidden: c["targetHidden"] as! Bool,
                                        launcherAge: (c["launcherAge"] as! NSNumber).doubleValue,
                                        launcherStartedAtLogin: c["startedAtLogin"] as! Bool,
                                        systemUptime: (c["uptime"] as! NSNumber).doubleValue)
            XCTAssertEqual(got?.rawValue, c["expect"] as? String, "\(c)")
        }
        for c in spec["activation"] as! [[String: Any]] {
            XCTAssertEqual(PlaybackPolicy.endsOnActivation(isLauncher: c["isLauncher"] as! Bool, isTarget: c["isTarget"] as! Bool,
                                                           overlayAge: (c["age"] as! NSNumber).doubleValue),
                           c["expect"] as! Bool, "\(c)")
        }
        for c in spec["autoPlay"] as! [[String: Any]] {
            XCTAssertEqual(PlaybackPolicy.shouldAutoPlay(paused: c["paused"] as! Bool, reduceMotion: c["reduceMotion"] as! Bool,
                                                         playDespiteReduceMotion: c["override"] as! Bool),
                           c["expect"] as! Bool, "\(c)")
        }
    }
}

extension ConformanceTests {
    func testTargetChooseAndStateCases() throws {
        let spec = try load("targets.json")
        XCTAssertFalse((spec["windowsMatch"] as! [[String: Any]]).isEmpty) // Windows process matching is platform-specific.
        for c in spec["choose"] as! [[String: Any]] {
            let got = TargetPackChoice.choose(animation: c["animation"] as? String,
                rotation: PackRotation(rawValue: c["rotation"] as! String)!, favorites: c["favorites"] as! [String],
                available: c["available"] as! [String], active: c["active"] as? String,
                lastPackId: c["lastPackId"] as? String, random: (c["random"] as! NSNumber).doubleValue)
            XCTAssertEqual(got.id, c["expect"] as? String, c["name"] as! String)
            XCTAssertEqual(got.missing, c["expectMissing"] as! Bool, c["name"] as! String)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PlaybackStateStore(directory: directory)
        for c in spec["state"] as! [[String: Any]] {
            let data = try JSONSerialization.data(withJSONObject: c["json"]!)
            try data.write(to: store.file)
            var reset = false
            let got = store.load { reset = true }
            XCTAssertEqual(reset, c["expectReset"] as? Bool ?? false, c["name"] as! String)
            if reset { XCTAssertEqual(got, .init()); continue }
            XCTAssertEqual(got.snoozeUntil, (c["expectSnooze"] as? NSNumber)?.doubleValue)
            let expected = c["expectTargets"] as! [String: [String: Any]]
            XCTAssertEqual(Set(got.targets.keys), Set(expected.keys))
            for (id, state) in expected {
                XCTAssertEqual(got.targets[id]?.lastAutoPlayAt, (state["lastAutoPlayAt"] as? NSNumber)?.doubleValue)
                XCTAssertEqual(got.targets[id]?.lastPackId, state["lastPackId"] as? String)
            }
            try store.save(got)
            XCTAssertEqual(store.load(), got)
        }
    }

    func testScheduleCases() throws {
        let spec = try load("schedule.json")
        for c in spec["decide"] as! [[String: Any]] {
            let raw = c["state"] as! [String: Any]
            let state = PlaybackState(lastAutoPlayAt: (raw["lastAutoPlayAt"] as? NSNumber)?.doubleValue,
                                      snoozeUntil: (raw["snoozeUntil"] as? NSNumber)?.doubleValue)
            let got = ScheduleDecision.decide(frequency: PlaybackFrequency(rawValue: c["frequency"] as! String)!,
                dayStartHour: c["dayStartHour"] as! Int, state: state, now: (c["now"] as! NSNumber).doubleValue,
                nowOffset: c["nowOffset"] as! Int, lastOffset: c["lastOffset"] as! Int)
            XCTAssertEqual(got.rawValue, c["expect"] as! String, c["name"] as! String)
        }
        for c in spec["nextDayStart"] as! [[String: Any]] {
            XCTAssertEqual(ScheduleDecision.nextDayStart(now: (c["now"] as! NSNumber).doubleValue,
                nowOffset: c["nowOffset"] as! Int, dayStartHour: c["dayStartHour"] as! Int),
                (c["expect"] as! NSNumber).doubleValue, accuracy: 1e-9, c["name"] as! String)
        }
    }

    func testBuiltInSelectionCases() throws {
        for c in try load("library.json")["resolveActive"] as! [[String: Any]] {
            let packs = try (c["available"] as! [String]).map { id -> InstalledPack in
                let manifest = PackManifest(id: id, name: id, segments: [.video: "video.mp4"])
                return InstalledPack(manifest: manifest, layout: try manifest.validatedLayout(),
                                     directory: URL(fileURLWithPath: "/fixture/" + id))
            }
            var preferred = c["preferred"] as? String
            if let featured = c["justInstalledFeatured"] as? String {
                preferred = PackLibrary.preferredAfterFirstFeaturedInstall(preferredID: preferred, featuredID: featured)
                XCTAssertEqual(preferred, c["expectPreferred"] as? String, c["name"] as! String)
            }
            XCTAssertEqual(PackLibrary.resolveActive(preferredID: preferred, packs: packs,
                                                     fallbackID: "demo-garden")?.id,
                           c["expect"] as? String, c["name"] as! String)
        }
    }

    func testLibraryCases() throws {
        for c in try load("library.json")["choose"] as! [[String: Any]] {
            XCTAssertEqual(PackRotation.choose(rotation: PackRotation(rawValue: c["rotation"] as! String)!,
                favorites: c["favorites"] as! [String], available: c["available"] as! [String],
                active: c["active"] as? String, lastPackId: c["lastPackId"] as? String,
                random: (c["random"] as! NSNumber).doubleValue), c["expect"] as? String, c["name"] as! String)
        }
    }
}

extension ConformanceTests {
    func testCompatibilityCases() throws {
        let spec = try load("compatibility.json")
        for c in spec["verdict"] as! [[String: Any]] {
            let got = CompatibilityRules.verdict(runningAtStart: c["runningAtStart"] as! Bool, coldStart: c["coldStart"] as! Bool,
                                                 windowSeconds: (c["windowSeconds"] as? NSNumber)?.doubleValue,
                                                 maxWait: (c["maxWait"] as! NSNumber).doubleValue)
            XCTAssertEqual(got.rawValue, c["expect"] as? String, "\(c["name"]!)")
        }
        for c in spec["reappear"] as! [[String: Any]] {
            var tracker = ReappearTracker()
            var fired: [Int] = []
            for (index, s) in (c["samples"] as! [[String: Any]]).enumerated() {
                if tracker.feed(t: (s["t"] as! NSNumber).doubleValue, running: s["running"] as! Bool, hidden: s["hidden"] as! Bool,
                                hasWindow: s["hasWindow"] as! Bool, hasVisibleMain: s["hasVisibleMain"] as! Bool) { fired.append(index) }
            }
            XCTAssertEqual(fired, (c["expectFired"] as! [NSNumber]).map(\.intValue), "\(c["name"]!)")
        }
        for c in spec["quiet"] as! [[String: Any]] {
            let got = QuietRules.skip(enabled: c["enabled"] as! Bool, state: QuietState(rawValue: c["state"] as! String)!)
            XCTAssertEqual(got.skip, c["expectSkip"] as! Bool, "\(c["name"]!)")
            XCTAssertEqual(got.detail, c["expectDetail"] as? String, "\(c["name"]!)")
        }
    }

    func testCompatAndNewFieldsRoundTrip() throws {
        var state = PlaybackState()
        state.targets["a-1"] = .init(lastAutoPlayAt: 5, lastPackId: "demo", compat: .init(verdict: .slowWindow, windowSeconds: 12.5, at: 9))
        state.targets["b-2"] = .init(compat: .init(verdict: .notOpened, windowSeconds: nil, at: 3))
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(PlaybackState.self, from: data), state)
        // An unknown verdict (newer build) drops only that compat entry.
        let odd = #"{"schemaVersion":2,"targets":{"a-1":{"lastAutoPlayAt":5,"compat":{"verdict":"future","at":1}}}}"#
        let decoded = try JSONDecoder().decode(PlaybackState.self, from: Data(odd.utf8))
        XCTAssertEqual(decoded.targets["a-1"], .init(lastAutoPlayAt: 5))

        var settings = ExperienceSettings()
        XCTAssertTrue(settings.playback.quietWhenFullscreen)
        settings.playback.quietWhenFullscreen = false
        settings.targets[0].playOnReappear = true
        let round = try ExperienceSettings.decode(JSONEncoder().encode(settings))
        XCTAssertEqual(round, settings)
        XCTAssertNil(round.targets[0].platforms["playOnReappear"])
        // Files written before P-011 (and Windows' explicit false) still read.
        let legacy = #"{"frequency":"firstOfDay","dayStartHour":4}"#
        XCTAssertTrue(try JSONDecoder().decode(PlaybackPreferences.self, from: Data(legacy.utf8)).quietWhenFullscreen)
        let target = #"{"id":"x","name":"X","enabled":true,"animation":null,"playOnReappear":false,"mac":{"bundleId":"com.x"}}"#
        let t = try JSONDecoder().decode(ApplicationTarget.self, from: Data(target.utf8))
        XCTAssertFalse(t.playOnReappear); XCTAssertEqual(t.platforms.count, 1)
    }
}

extension ConformanceTests {
    func testVideoPackCases() throws {
        let spec = try load("video-pack.json")
        for c in spec["defaultName"] as! [[String: Any]] {
            XCTAssertEqual(VideoPackRules.defaultName(fileName: c["fileName"] as! String), c["expect"] as? String)
        }
        for c in spec["extension"] as! [[String: Any]] {
            XCTAssertEqual(VideoPackRules.fileExtension(fileName: c["fileName"] as! String), c["expect"] as? String, "\(c)")
        }
        for c in spec["validName"] as! [[String: Any]] {
            XCTAssertEqual(VideoPackRules.validName(c["name"] as! String), c["expect"] as! Bool, "\(c)")
        }
        for c in spec["makeId"] as! [[String: Any]] {
            XCTAssertEqual(VideoPackRules.makeID(random: (c["random"] as! NSNumber).uint32Value), c["expect"] as? String)
        }
        for c in spec["notice"] as! [[String: Any]] {
            XCTAssertEqual(VideoPackRules.notice(name: c["name"] as! String, sourceFileName: c["sourceFileName"] as! String,
                                                 date: c["date"] as! String), c["expect"] as? String)
        }
    }

    func testVideoPackBuildsALoadablePack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("video-pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let video = root.appendingPathComponent("My Clip.MOV")
        try Data("not decoded here".utf8).write(to: video)
        var draws: [UInt32] = [0, 0xdeadbeef]
        let folder = try VideoPackRules.build(video: video, name: "  开场  ", existingIDs: ["video-00000000"],
                                              in: root.appendingPathComponent("staging"), random: { draws.removeFirst() })
        let pack = try PackLibrary.load(directory: folder)
        XCTAssertEqual(pack.id, "video-deadbeef")
        XCTAssertEqual(pack.manifest.name, "开场")
        XCTAssertEqual(pack.manifest.segments, [.video: "video.mov"])
        let notice = try String(contentsOf: folder.appendingPathComponent("NOTICE.md"), encoding: .utf8)
        XCTAssertTrue(notice.contains("「My Clip.MOV」") && !notice.contains(root.path))
        XCTAssertThrowsError(try VideoPackRules.build(video: root.appendingPathComponent("x.avi"), name: "a", existingIDs: [], in: root))
        XCTAssertThrowsError(try VideoPackRules.build(video: video, name: " ", existingIDs: [], in: root))
    }
}

extension ConformanceTests {
    func testUpdateCases() throws {
        let spec = try load("updates.json")
        for c in spec["compare"] as! [[String: Any]] {
            let got = UpdateRules.compare(c["a"] as! String, c["b"] as! String)
            XCTAssertEqual(got, (c["expect"] as? NSNumber)?.intValue, "\(c["a"]!) vs \(c["b"]!)")
        }
        for c in spec["newest"] as! [[String: Any]] {
            let releases = (c["releases"] as! [[String: Any]]).map {
                UpdateRules.Release(tag: $0["tag"] as! String, url: $0["url"] as! String, draft: $0["draft"] as! Bool, prerelease: $0["prerelease"] as! Bool)
            }
            let got = UpdateRules.newest(releases, current: c["current"] as! String)
            let expect = (c["expect"] as? [String: String]).map { UpdateRules.Available(version: $0["version"]!, url: $0["url"]!) }
            XCTAssertEqual(got, expect, c["name"] as! String)
        }
        for c in spec["isDue"] as! [[String: Any]] {
            XCTAssertEqual(UpdateRules.isDue(lastCheckAt: (c["lastCheckAt"] as? NSNumber)?.doubleValue, now: (c["now"] as! NSNumber).doubleValue),
                           c["expect"] as! Bool, c["name"] as! String)
        }
    }

    func testReleaseListDecoding() throws {
        let json = #"[{"tag_name":"v0.2.0-preview.5","html_url":"https://github.com/x/y/releases/tag/v0.2.0-preview.5","draft":false,"prerelease":true},{"tag_name":"v9","html_url":"javascript:alert(1)"},{"name":"no tag"}]"#
        let releases = try UpdateRules.decodeReleases(Data(json.utf8))
        XCTAssertEqual(releases, [UpdateRules.Release(tag: "v0.2.0-preview.5", url: "https://github.com/x/y/releases/tag/v0.2.0-preview.5", draft: false, prerelease: true)])
        XCTAssertThrowsError(try UpdateRules.decodeReleases(Data(#"{"message":"rate limited"}"#.utf8)))
    }
}
