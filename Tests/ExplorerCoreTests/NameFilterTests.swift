// SPDX-License-Identifier: Apache-2.0
import Testing
@testable import ExplorerCore

struct NameFilterTests {
    @Test func plainTextMatchesAnyPartOfTheName() {
        let filter = NameFilter("nota")
        #expect(filter.matches("Minhas Notas.txt") && filter.matches("NOTÁVEL") && !filter.matches("Contas.pdf"))
        #expect(NameFilter("").matches("anything") && NameFilter("").isEmpty && !NameFilter(" 22").matches("2022"))
    }

    @Test func wildcardsMatchTheWholeName() {
        let pdf = NameFilter("*.pdf")
        #expect(pdf.matches("Contrato.pdf") && pdf.matches("RELATÓRIO.PDF") && pdf.matches(".pdf"))
        #expect(!pdf.matches("Contrato.pdf.zip") && !pdf.matches("pdf") && !pdf.matches("Contrato.pdfx"))
        let photo = NameFilter("IMG_????.*")
        #expect(photo.matches("img_1234.jpg") && !photo.matches("IMG_123.jpg") && !photo.matches("IMG_12345.jpg"))
        #expect(NameFilter("*relat*").matches("Relatório anual.docx"))
        #expect(NameFilter("a*b*c").matches("aXXbYYbZZc") && !NameFilter("a*b*c").matches("aXXcYYb"))
        #expect(NameFilter("*").matches("qualquer coisa") && NameFilter(" *.pdf ").matches("x.pdf"))
    }
}
