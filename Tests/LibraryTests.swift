import XCTest
@testable import SlideViewCore

final class LibraryTests: XCTestCase {
    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/Users/someone/notes/" + name) }

    // MARK: Credentials are never scanned, converted or cached

    func testCredentialFilesAreSensitive() {
        let secrets = [".env", ".env.local", ".ENV.production", "env", "env.txt", "prod.env",
                       "credentials.json", "Credentials.csv", "credentials.prod.yaml",
                       "secrets.yaml", "secrets.staging.json", "secret.txt",
                       "id_rsa", "id_ed25519", "id_rsa.pub",
                       "server.pem", "cert.p12", "store.pfx", "release.keystore", "app.jks",
                       "putty.ppk", "key.asc", "backup.gpg",
                       ".npmrc", ".netrc", ".pgpass", ".htpasswd", ".pypirc"]
        for name in secrets {
            XCTAssertTrue(Library.isSensitive(file(name)), "\(name) should be treated as credentials")
        }
    }

    func testOrdinaryStudyMaterialIsNotSensitive() {
        let material = ["Unit 1.pptx", "notes.md", "environment.md", "secretary.txt", "envelope.pdf",
                        "keys-and-locks.pdf", "public key cryptography.docx", "grades.csv",
                        "idea.excalidraw", "lab.ipynb"]
        for name in material {
            XCTAssertFalse(Library.isSensitive(file(name)), "\(name) should be openable")
        }
    }

    func testKeynoteFilesAreNotMistakenForKeys() {
        XCTAssertFalse(Library.isSensitive(file("Lecture 4.key")))
        XCTAssertEqual(Library.kind("key"), .office)
    }

    // MARK: Which renderer a file goes to

    func testKindsByExtension() {
        let expected: [(String, Library.Kind)] = [
            ("pdf", .pdf),
            ("pptx", .office), ("xlsx", .office), ("numbers", .office), ("pages", .office),
            ("docx", .attributed), ("rtf", .attributed), ("html", .attributed),
            ("csv", .table), ("tsv", .table),
            ("md", .markdown), ("rmd", .markdown),
            ("png", .image), ("heic", .image),
            ("ipynb", .notebook),
            ("excalidraw", .drawing),
            ("txt", .text), ("tex", .text), ("swift", .text), ("json", .text),
        ]
        for (ext, kind) in expected {
            XCTAssertEqual(Library.kind(ext), kind, ext)
        }
        XCTAssertNil(Library.kind("exe"))
        XCTAssertNil(Library.kind(""))
    }

    // MARK: What the library scan picks up

    func testCodeIsOpenableButNotScanned() {
        for ext in ["swift", "py", "js", "json", "yaml"] {
            XCTAssertFalse(Library.scanned.contains(ext), "\(ext) should not be indexed")
            XCTAssertTrue(Library.openable.contains(ext), "\(ext) should open on demand")
        }
        for ext in ["pdf", "pptx", "docx", "md", "ipynb", "excalidraw", "csv", "txt"] {
            XCTAssertTrue(Library.scanned.contains(ext), "\(ext) should be indexed")
        }
    }

    func testImagesAreScannedOnlyWhenAskedFor() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: "scanImages")
        defer { defaults.set(before, forKey: "scanImages") }

        defaults.removeObject(forKey: "scanImages")
        XCTAssertFalse(Library.scanned.contains("png"), "images are excluded by default")
        XCTAssertTrue(Library.scanned.contains("pdf"))

        defaults.set(true, forKey: "scanImages")
        XCTAssertTrue(Library.scanned.contains("png"))
        XCTAssertTrue(Library.scanned.contains("heic"))
    }

    func testEditableFormatsAreTheTextOnes() {
        for ext in ["txt", "md", "csv", "py", "excalidraw"] {
            XCTAssertTrue(Library.editable.contains(ext), ext)
        }
        for ext in ["pdf", "pptx", "docx", "png", "ipynb"] {
            XCTAssertFalse(Library.editable.contains(ext), ext)
        }
    }

    // MARK: Document ids

    func testIdsAreAStableHashOfThePath() {
        XCTAssertEqual(Library.hash(""), "e3b0c44298fc1c149afbf4c8996fb924")   // SHA-256, first 16 bytes
        XCTAssertEqual(Library.hash("/a/Unit 1.pptx"), Library.hash("/a/Unit 1.pptx"))
        XCTAssertNotEqual(Library.hash("/a/Unit 1.pptx"), Library.hash("/a/Unit 2.pptx"))
        XCTAssertEqual(Library.hash("/a/Unit 1.pptx").count, 32)
    }
}
