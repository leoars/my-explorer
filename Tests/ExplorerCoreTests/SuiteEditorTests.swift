// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ExplorerCore

final class SuiteEditorTests: XCTestCase {
    private let paintTypes = ["public.png", "public.jpeg", "com.microsoft.bmp", "com.compuserve.gif", "public.tiff"]
    private let notepadTypes = ["public.plain-text"]

    private func file(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/" + name) }

    func testDocumentTypesComeFromEveryDeclaredDocument() {
        let info: [String: Any] = ["CFBundleDocumentTypes": [
            ["CFBundleTypeName": "Image", "LSItemContentTypes": ["public.png", "public.jpeg"]],
            ["CFBundleTypeName": "Legacy"],
            ["LSItemContentTypes": ["public.tiff"]]
        ]]
        XCTAssertEqual(SuiteEditor.documentTypes(inInfoDictionary: info), ["public.png", "public.jpeg", "public.tiff"])
        XCTAssertEqual(SuiteEditor.documentTypes(inInfoDictionary: [:]), [])
        XCTAssertEqual(SuiteEditor.documentTypes(ofApplicationAt: file("Missing.app")), [])
    }

    func testPaintTypesCoverItsImageExtensionsOnly() {
        for name in ["a.png", "b.JPG", "c.jpeg", "d.bmp", "e.gif", "f.tif", "g.tiff"] {
            XCTAssertTrue(SuiteEditor.supports(file(name), documentTypes: paintTypes), name)
        }
        for name in ["notes.txt", "report.pdf", "vector.svg", "archive.zip", "Makefile"] {
            XCTAssertFalse(SuiteEditor.supports(file(name), documentTypes: paintTypes), name)
        }
    }

    func testNotepadTypesCoverTextButNotRichText() {
        for name in ["notes.txt", "README.md", "main.swift", "data.csv", "config.json", "feed.xml", "page.html", "style.css"] {
            XCTAssertTrue(SuiteEditor.supports(file(name), documentTypes: notepadTypes), name)
        }
        for name in ["photo.png", "report.pdf", "letter.rtf", "LICENSE"] {
            XCTAssertFalse(SuiteEditor.supports(file(name), documentTypes: notepadTypes), name)
        }
    }

    func testNothingIsSupportedWithoutDeclaredTypes() {
        XCTAssertFalse(SuiteEditor.supports(file("notes.txt"), documentTypes: []))
        XCTAssertFalse(SuiteEditor.supports(file("config.json"), documentTypes: paintTypes))
        XCTAssertEqual(SuiteEditor.notepad.bundleIdentifier, "local.mynotepad.editor")
        XCTAssertEqual(SuiteEditor.paint.bundleIdentifier, "local.mypaint.editor")
    }

    func testOpeningByDefaultIsNarrowerForTextThanTheMenu() {
        // Images keep opening in My Explorer's own viewer; My Paint is a context menu choice.
        for name in ["a.png", "b.jpg", "c.bmp", "d.gif", "e.tiff", "photo.heic", "notes.txt"] {
            XCTAssertFalse(SuiteEditor.paint.opensByDefault(file(name), documentTypes: paintTypes), name)
        }
        for name in ["notes.txt", "NOTES.TXT", "app.log", "read.text"] {
            XCTAssertTrue(SuiteEditor.notepad.opensByDefault(file(name), documentTypes: notepadTypes), name)
        }
        // Supported in the context menu, but a double click keeps their usual applications.
        for name in ["page.html", "data.csv", "config.json", "main.swift", "README.md"] {
            XCTAssertTrue(SuiteEditor.supports(file(name), documentTypes: notepadTypes), name)
            XCTAssertFalse(SuiteEditor.notepad.opensByDefault(file(name), documentTypes: notepadTypes), name)
        }
        XCTAssertFalse(SuiteEditor.notepad.opensByDefault(file("notes.txt"), documentTypes: []))
    }
}
