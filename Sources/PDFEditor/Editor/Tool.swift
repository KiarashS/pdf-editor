import Foundation
import PDFEditorCore

/// Top-level editing modes, shown as a segmented control in the toolbar.
enum EditorMode: String, CaseIterable, Identifiable {
    case read, comment, edit, pages, forms, protect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .read: return "Read"
        case .comment: return "Comment"
        case .edit: return "Edit"
        case .pages: return "Pages"
        case .forms: return "Forms"
        case .protect: return "Redact"
        }
    }

    var systemImage: String {
        switch self {
        case .read: return "book"
        case .comment: return "text.bubble"
        case .edit: return "pencil.and.outline"
        case .pages: return "square.grid.2x2"
        case .forms: return "checklist"
        case .protect: return "eye.slash"
        }
    }

    var tools: [Tool] {
        switch self {
        case .read: return [.select, .hand]
        case .comment:
            return [.select, .highlight, .underline, .strikeout, .pen, .highlighterPen, .eraser,
                    .textBox, .note, .rectangle, .oval, .line, .arrow, .stamp, .signature, .measure]
        case .edit: return [.select, .editText, .addText, .addImage, .link, .crop]
        case .pages: return []
        case .forms: return [.select, .textField, .multilineText, .checkbox, .radioButton, .comboBox, .listBox, .pushButton, .signatureField]
        case .protect: return [.select, .redactArea, .redactText]
        }
    }
}

/// How a tool uses the mouse on the canvas.
enum ToolInteraction {
    /// PDFView's own behavior (text selection, links, form filling); annotations can be selected and moved.
    case select
    /// Scroll by dragging.
    case pan
    /// Select text with PDFView, then convert the selection on mouse up.
    case textMarkup
    /// Freehand strokes.
    case ink
    /// Drag out a rectangle; a click uses a default size.
    case rect
    /// Drag from a start point to an end point.
    case line
    /// Acts on the clicked point.
    case click
}

enum Tool: String, CaseIterable, Identifiable {
    case select, hand
    case highlight, underline, strikeout, pen, highlighterPen, eraser, textBox, note, rectangle, oval, line, arrow, stamp, signature, measure
    case editText, addText, addImage, link, crop
    case textField, multilineText, checkbox, radioButton, comboBox, listBox, pushButton, signatureField
    case redactArea, redactText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .hand: return "Hand"
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeout: return "Strikethrough"
        case .pen: return "Pen"
        case .highlighterPen: return "Marker"
        case .eraser: return "Eraser"
        case .textBox: return "Text Box"
        case .note: return "Note"
        case .rectangle: return "Rectangle"
        case .oval: return "Oval"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .stamp: return "Stamp"
        case .signature: return "Signature"
        case .measure: return "Measure"
        case .editText: return "Edit Text"
        case .addText: return "Add Text"
        case .addImage: return "Add Image"
        case .link: return "Link"
        case .crop: return "Crop"
        case .textField: return "Text Field"
        case .multilineText: return "Text Area"
        case .checkbox: return "Checkbox"
        case .radioButton: return "Radio Button"
        case .comboBox: return "Dropdown"
        case .listBox: return "List Box"
        case .pushButton: return "Button"
        case .signatureField: return "Signature Field"
        case .redactArea: return "Mark Area"
        case .redactText: return "Mark Text"
        }
    }

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"
        case .hand: return "hand.raised"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeout: return "strikethrough"
        case .pen: return "pencil.tip"
        case .highlighterPen: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .textBox: return "character.textbox"
        case .note: return "note.text"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .stamp: return "seal"
        case .signature: return "signature"
        case .measure: return "ruler"
        case .editText: return "text.cursor"
        case .addText: return "textformat"
        case .addImage: return "photo.badge.plus"
        case .link: return "link"
        case .crop: return "crop"
        case .textField: return "character.cursor.ibeam"
        case .multilineText: return "text.alignleft"
        case .checkbox: return "checkmark.square"
        case .radioButton: return "smallcircle.filled.circle"
        case .comboBox: return "chevron.down.square"
        case .listBox: return "list.bullet.rectangle"
        case .pushButton: return "button.horizontal"
        case .signatureField: return "signature"
        case .redactArea: return "rectangle.dashed"
        case .redactText: return "text.badge.xmark"
        }
    }

    var interaction: ToolInteraction {
        switch self {
        case .select: return .select
        case .hand: return .pan
        case .highlight, .underline, .strikeout, .redactText: return .textMarkup
        case .pen, .highlighterPen: return .ink
        case .line, .arrow, .measure: return .line
        case .eraser, .note, .editText: return .click
        case .textBox, .rectangle, .oval, .stamp, .signature, .addText, .addImage, .link, .crop,
             .textField, .multilineText, .checkbox, .radioButton, .comboBox, .listBox, .pushButton, .signatureField,
             .redactArea:
            return .rect
        }
    }

    var formFieldKind: FormFieldKind? {
        switch self {
        case .textField: return .textField
        case .multilineText: return .multilineText
        case .checkbox: return .checkbox
        case .radioButton: return .radioButton
        case .comboBox: return .comboBox
        case .listBox: return .listBox
        case .pushButton: return .pushButton
        case .signatureField: return .signature
        default: return nil
        }
    }

    /// Whether the style bar shows stroke color and width for this tool.
    var usesStroke: Bool {
        [.pen, .highlighterPen, .rectangle, .oval, .line, .arrow, .measure, .textBox].contains(self)
    }

    var usesFill: Bool { [.rectangle, .oval, .textBox].contains(self) }
    var usesFont: Bool { [.textBox, .addText].contains(self) }
    var usesHighlightColor: Bool { [.highlight, .underline, .strikeout, .note].contains(self) }
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case normal, dark, sepia, mint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "Default"
        case .dark: return "Night"
        case .sepia: return "Sepia"
        case .mint: return "Eye Care"
        }
    }
}

enum SidebarTab: String, CaseIterable, Identifiable {
    case thumbnails, outline, annotations, search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thumbnails: return "Pages"
        case .outline: return "Bookmarks"
        case .annotations: return "Comments"
        case .search: return "Search"
        }
    }

    var systemImage: String {
        switch self {
        case .thumbnails: return "rectangle.grid.1x2"
        case .outline: return "bookmark"
        case .annotations: return "text.bubble"
        case .search: return "magnifyingglass"
        }
    }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case properties, document, assistant

    var id: String { rawValue }

    var title: String {
        switch self {
        case .properties: return "Properties"
        case .document: return "Document"
        case .assistant: return "AI"
        }
    }
}
