import Foundation

/// Writes a minimal SpreadsheetML (.xlsx) workbook.
public struct XLSXWriter {
    public struct Sheet {
        public var name: String
        public var rows: [[String]]

        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    public var sheets: [Sheet] = []

    public init(sheets: [Sheet] = []) {
        self.sheets = sheets
    }

    /// Column letters for a 0-based index: 0 -> A, 26 -> AA.
    public static func columnName(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    static func sanitizedSheetName(_ name: String, used: inout Set<String>) -> String {
        let invalid = CharacterSet(charactersIn: "[]:*?/\\")
        var cleaned = String(name.unicodeScalars.filter { !invalid.contains($0) }.map(Character.init))
        if cleaned.isEmpty { cleaned = "Sheet" }
        cleaned = String(cleaned.prefix(31))
        var candidate = cleaned
        var counter = 2
        while used.contains(candidate.lowercased()) {
            let suffix = " (\(counter))"
            candidate = String(cleaned.prefix(31 - suffix.count)) + suffix
            counter += 1
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    public func data() -> Data {
        let sheets = self.sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : self.sheets
        var zip = ZipWriter()

        var overrides = ""
        for i in sheets.indices {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        zip.addFile(path: "[Content_Types].xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(overrides)\
        </Types>
        """)

        zip.addFile(path: "_rels/.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """)

        var used = Set<String>()
        var sheetEntries = ""
        var sheetRels = ""
        for (i, sheet) in sheets.enumerated() {
            let name = Self.sanitizedSheetName(sheet.name, used: &used)
            sheetEntries += "<sheet name=\"\(xmlEscaped(name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            sheetRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        sheetRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"

        zip.addFile(path: "xl/workbook.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\(sheetEntries)</sheets>\
        </workbook>
        """)

        zip.addFile(path: "xl/_rels/workbook.xml.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheetRels)</Relationships>
        """)

        zip.addFile(path: "xl/styles.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>\
        </styleSheet>
        """)

        for (i, sheet) in sheets.enumerated() {
            zip.addFile(path: "xl/worksheets/sheet\(i + 1).xml", string: Self.worksheetXML(rows: sheet.rows))
        }
        return zip.finalize()
    }

    static func worksheetXML(rows: [[String]]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + String(r + 1)
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                if let number = Double(trimmed.replacingOccurrences(of: ",", with: "")), trimmed.count < 16,
                   trimmed.range(of: "^-?[0-9][0-9,]*(\\.[0-9]+)?$", options: .regularExpression) != nil {
                    xml += "<c r=\"\(ref)\"><v>\(number)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscaped(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }
}

/// Writes a minimal PresentationML (.pptx) deck with one picture per slide.
public struct PPTXWriter {
    public struct Slide {
        /// PNG or JPEG bytes.
        public var imageData: Data
        public var imageExtension: String
        /// Optional speaker notes are not written; the text is kept as the slide's alt text.
        public var altText: String

        public init(imageData: Data, imageExtension: String, altText: String = "") {
            self.imageData = imageData
            self.imageExtension = imageExtension
            self.altText = altText
        }
    }

    public var slides: [Slide]
    /// Slide size in points.
    public var slideSize: CGSize

    public init(slides: [Slide], slideSize: CGSize) {
        self.slides = slides
        self.slideSize = slideSize
    }

    static let emuPerPoint = 12700

    public func data() -> Data {
        var zip = ZipWriter()
        let cx = Int(slideSize.width) * Self.emuPerPoint
        let cy = Int(slideSize.height) * Self.emuPerPoint

        var slideOverrides = ""
        for i in slides.indices {
            slideOverrides += "<Override PartName=\"/ppt/slides/slide\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        zip.addFile(path: "[Content_Types].xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpeg" ContentType="image/jpeg"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\
        \(slideOverrides)\
        </Types>
        """)

        zip.addFile(path: "_rels/.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
        </Relationships>
        """)

        var slideIds = ""
        var presentationRels = """
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>
        """
        for i in slides.indices {
            slideIds += "<p:sldId id=\"\(256 + i)\" r:id=\"rId\(i + 3)\"/>"
            presentationRels += "<Relationship Id=\"rId\(i + 3)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i + 1).xml\"/>"
        }

        zip.addFile(path: "ppt/presentation.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" saveSubsetFonts="1">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        <p:sldIdLst>\(slideIds)</p:sldIdLst>\
        <p:sldSz cx="\(cx)" cy="\(cy)"/>\
        <p:notesSz cx="\(cy)" cy="\(cx)"/>\
        </p:presentation>
        """)

        zip.addFile(path: "ppt/_rels/presentation.xml.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(presentationRels)</Relationships>
        """)

        zip.addFile(path: "ppt/slideMasters/slideMaster1.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        </p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
        <p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>\
        </p:sldMaster>
        """)

        zip.addFile(path: "ppt/slideMasters/_rels/slideMaster1.xml.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
        </Relationships>
        """)

        zip.addFile(path: "ppt/slideLayouts/slideLayout1.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1">\
        <p:cSld name="Blank"><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        </p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
        </p:sldLayout>
        """)

        zip.addFile(path: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
        </Relationships>
        """)

        zip.addFile(path: "ppt/theme/theme1.xml", string: Self.themeXML)

        for (i, slide) in slides.enumerated() {
            let ext = slide.imageExtension.lowercased()
            let mediaName = "image\(i + 1).\(ext)"
            zip.addFile(path: "ppt/media/\(mediaName)", data: slide.imageData)
            zip.addFile(path: "ppt/slides/_rels/slide\(i + 1).xml.rels", string: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/\(mediaName)"/>\
            </Relationships>
            """)
            zip.addFile(path: "ppt/slides/slide\(i + 1).xml", string: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
            <p:cSld><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(i + 1)" descr="\(xmlEscaped(String(slide.altText.prefix(2000))))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
            <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
            <p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            </p:pic>\
            </p:spTree></p:cSld>\
            <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\
            </p:sld>
            """)
        }
        return zip.finalize()
    }

    static let themeXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme">\
    <a:themeElements>\
    <a:clrScheme name="Office">\
    <a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1><a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="44546A"/></a:dk2><a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>\
    <a:accent1><a:srgbClr val="4472C4"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2>\
    <a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4>\
    <a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6>\
    <a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink>\
    </a:clrScheme>\
    <a:fontScheme name="Office">\
    <a:majorFont><a:latin typeface="Calibri Light"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>\
    </a:fontScheme>\
    <a:fmtScheme name="Office">\
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst>\
    </a:fmtScheme>\
    </a:themeElements>\
    </a:theme>
    """
}
