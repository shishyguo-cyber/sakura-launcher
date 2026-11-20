import XCTest
@testable import GardenBootCore

/// macOS new installs start on the built-in Welcome; nothing the user already has is replaced.
final class DefaultPackTests: XCTestCase {
    func testBrandNewInstallStartsOnWelcome() {
        XCTAssertEqual(PackLibrary.newInstallChoice(preferredID: nil, alreadyOfferedFeatured: false,
                                                    defaultID: "sakura-greeting"), "sakura-greeting")
    }

    func testExistingChoiceIsKept() {
        for chosen in ["raiden-garden", "demo-garden", "personal", "removed-pack"] {
            XCTAssertNil(PackLibrary.newInstallChoice(preferredID: chosen, alreadyOfferedFeatured: false,
                                                      defaultID: "sakura-greeting"), chosen)
            XCTAssertNil(PackLibrary.newInstallChoice(preferredID: chosen, alreadyOfferedFeatured: true,
                                                      defaultID: "sakura-greeting"), chosen)
        }
    }

    /// An upgrade that already went through the featured offer without picking anything keeps playing as before.
    func testUpgradeWithoutChoiceIsLeftAlone() {
        XCTAssertNil(PackLibrary.newInstallChoice(preferredID: nil, alreadyOfferedFeatured: true,
                                                  defaultID: "sakura-greeting"))
    }

    /// Once Welcome is current, the featured pack's first install no longer takes over.
    func testFeaturedInstallDoesNotReplaceWelcome() {
        XCTAssertEqual(PackLibrary.preferredAfterFirstFeaturedInstall(preferredID: "sakura-greeting",
                                                                      featuredID: "raiden-garden"), "sakura-greeting")
    }

    /// A removed choice falls back to Welcome when the app passes it as the fallback.
    func testMissingChoiceFallsBackToWelcome() throws {
        let packs = try ["demo-garden", "raiden-garden", "sakura-greeting"].map { id -> InstalledPack in
            let manifest = PackManifest(id: id, name: id, segments: [.video: "video.mp4"])
            return InstalledPack(manifest: manifest, layout: try manifest.validatedLayout(),
                                 directory: URL(fileURLWithPath: "/fixture/" + id))
        }
        XCTAssertEqual(PackLibrary.resolveActive(preferredID: "removed", packs: packs, fallbackID: "sakura-greeting")?.id,
                       "sakura-greeting")
    }
}
