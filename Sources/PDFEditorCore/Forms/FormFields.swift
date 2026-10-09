import AppKit
import PDFKit

public enum FormFieldKind: String, CaseIterable, Identifiable {
    case textField, multilineText, checkbox, radioButton, comboBox, listBox, pushButton, signature

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .textField: return "Text Field"
        case .multilineText: return "Text Area"
        case .checkbox: return "Checkbox"
        case .radioButton: return "Radio Button"
        case .comboBox: return "Dropdown"
        case .listBox: return "List Box"
        case .pushButton: return "Button"
        case .signature: return "Signature"
        }
    }

    /// Size used when the user clicks instead of dragging.
    public var defaultSize: CGSize {
        switch self {
        case .checkbox, .radioButton: return CGSize(width: 16, height: 16)
        case .multilineText, .listBox: return CGSize(width: 200, height: 70)
        case .signature: return CGSize(width: 180, height: 44)
        case .pushButton: return CGSize(width: 90, height: 26)
        default: return CGSize(width: 180, height: 24)
        }
    }
}

/// Creates and reads interactive form fields (AcroForm widgets).
public enum FormFields {
    public static func make(_ kind: FormFieldKind, rect: CGRect, name: String, options: [String] = ["Option 1", "Option 2", "Option 3"]) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect.standardized, forType: .widget, withProperties: nil)
        annotation.fieldName = name
        annotation.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08)
        annotation.font = .systemFont(ofSize: 12)
        annotation.fontColor = .black
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        annotation.color = .systemGray

        switch kind {
        case .textField, .multilineText:
            annotation.widgetFieldType = .text
            annotation.isMultiline = kind == .multilineText
            annotation.widgetStringValue = ""
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
            annotation.buttonWidgetState = .offState
            annotation.buttonWidgetStateString = "Yes"
        case .radioButton:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .radioButtonControl
            annotation.buttonWidgetState = .offState
            annotation.buttonWidgetStateString = "Choice\(Int.random(in: 1000...9999))"
        case .comboBox, .listBox:
            annotation.widgetFieldType = .choice
            annotation.isListChoice = kind == .listBox
            annotation.choices = options
            annotation.widgetStringValue = kind == .comboBox ? (options.first ?? "") : ""
        case .pushButton:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .pushButtonControl
            annotation.caption = "Reset"
            annotation.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2)
            annotation.action = PDFActionResetForm()
        case .signature:
            annotation.widgetFieldType = .signature
            annotation.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15)
        }
        annotation.userName = AnnotationFactory.authorName
        annotation.modificationDate = Date()
        return annotation
    }

    /// A field name not yet used in `document`, e.g. "Text Field 3".
    public static func uniqueName(for kind: FormFieldKind, in document: PDFDocument) -> String {
        let existing = Set(widgets(in: document).compactMap { $0.annotation.fieldName })
        var number = 1
        while existing.contains("\(kind.title) \(number)") { number += 1 }
        return "\(kind.title) \(number)"
    }

    public static func widgets(in document: PDFDocument) -> [(pageIndex: Int, annotation: PDFAnnotation)] {
        document.allAnnotations().filter { $0.annotation.isSubtype(.widget) }
    }

    /// Current value of a widget as text ("Yes"/"Off" for checkboxes).
    public static func value(of widget: PDFAnnotation) -> String {
        switch widget.widgetFieldType {
        case .button:
            if isPushButton(widget) { return "" }
            return widget.buttonWidgetState == .onState ? (widget.buttonWidgetStateString.isEmpty ? "Yes" : widget.buttonWidgetStateString) : "Off"
        default:
            return widget.widgetStringValue ?? ""
        }
    }

    /// Push buttons carry no value. Checked through the field type first,
    /// because text and choice widgets report a push-button control type.
    static func isPushButton(_ widget: PDFAnnotation) -> Bool {
        widget.widgetFieldType == .button && widget.widgetControlType == .pushButtonControl
            && (widget.action != nil || widget.caption != nil)
    }

    /// Field values keyed by field name. Radio groups report the selected option.
    public static func values(in document: PDFDocument) -> [String: String] {
        var result: [String: String] = [:]
        for (_, widget) in widgets(in: document) {
            guard let name = widget.fieldName, !name.isEmpty else { continue }
            if isPushButton(widget) { continue }
            let value = value(of: widget)
            if widget.widgetControlType == .radioButtonControl {
                if value != "Off" || result[name] == nil { result[name] = value }
            } else {
                result[name] = value
            }
        }
        return result
    }

    /// Applies values produced by `values(in:)`.
    public static func apply(_ values: [String: String], to document: PDFDocument) {
        for (_, widget) in widgets(in: document) {
            guard let name = widget.fieldName, let value = values[name] else { continue }
            switch widget.widgetFieldType {
            case .button:
                switch widget.widgetControlType {
                case .checkBoxControl:
                    widget.buttonWidgetState = (value == "Off" || value.isEmpty) ? .offState : .onState
                case .radioButtonControl:
                    widget.buttonWidgetState = value == widget.buttonWidgetStateString ? .onState : .offState
                default:
                    if !isPushButton(widget) {
                        widget.buttonWidgetState = (value == "Off" || value.isEmpty) ? .offState : .onState
                    }
                }
            default:
                widget.widgetStringValue = value
            }
        }
    }

    public static func reset(_ document: PDFDocument) {
        for (_, widget) in widgets(in: document) {
            switch widget.widgetFieldType {
            case .button:
                if !isPushButton(widget) { widget.buttonWidgetState = .offState }
            default:
                widget.widgetStringValue = widget.widgetDefaultStringValue ?? ""
            }
        }
    }

    public static func exportJSON(_ document: PDFDocument) throws -> Data {
        try JSONSerialization.data(withJSONObject: values(in: document), options: [.prettyPrinted, .sortedKeys])
    }

    public static func exportCSV(_ document: PDFDocument) -> String {
        let rows = values(in: document).sorted { $0.key < $1.key }
        func quote(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["\"Field\",\"Value\""] + rows.map { quote($0.key) + "," + quote($0.value) }).joined(separator: "\n")
    }

    public static func importJSON(_ data: Data, into document: PDFDocument) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var values: [String: String] = [:]
        for (key, value) in object { values[key] = "\(value)" }
        apply(values, to: document)
    }

    /// Finds likely form blanks (runs of underscores and empty boxes drawn with
    /// "[ ]") in the page text and proposes text fields or checkboxes there.
    public static func detectFields(on page: PDFPage) -> [(FormFieldKind, CGRect)] {
        guard let text = page.string else { return [] }
        let ns = text as NSString
        var result: [(FormFieldKind, CGRect)] = []
        let patterns: [(String, FormFieldKind)] = [("_{4,}", .textField), ("\\[\\s?\\]|☐", .checkbox)]
        for (pattern, kind) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let selection = page.selection(for: match.range) else { continue }
                var rect = selection.bounds(for: page)
                guard rect.width > 2 else { continue }
                switch kind {
                case .checkbox:
                    let side = max(rect.height, 10)
                    rect = CGRect(x: rect.minX, y: rect.midY - side / 2, width: side, height: side)
                default:
                    rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(rect.height + 4, 16))
                }
                result.append((kind, rect))
            }
        }
        return result
    }
}
