import Foundation

/// Well-known command ids, for binding handlers and for tests.
extension CommandID {
    // Create
    public static let addChild: CommandID = "topic.addChild"
    public static let addSiblingAfter: CommandID = "topic.addSiblingAfter"
    public static let addSiblingBefore: CommandID = "topic.addSiblingBefore"
    public static let addParent: CommandID = "topic.addParent"
    public static let addFloating: CommandID = "topic.addFloating"
    public static let duplicate: CommandID = "topic.duplicate"
    // Edit text
    public static let editKeepText: CommandID = "topic.edit"
    public static let commitEdit: CommandID = "editor.commit"
    public static let commitAndAddChild: CommandID = "editor.commitAndAddChild"
    public static let commitAndPromote: CommandID = "editor.commitAndPromote"
    public static let commitAndAddParent: CommandID = "editor.commitAndAddParent"
    public static let lineBreak: CommandID = "editor.lineBreak"
    public static let bold: CommandID = "editor.bold"
    public static let italic: CommandID = "editor.italic"
    public static let editorLink: CommandID = "editor.link"
    // Navigate & select
    public static let selectUp: CommandID = "select.up"
    public static let selectDown: CommandID = "select.down"
    public static let selectLeft: CommandID = "select.left"
    public static let selectRight: CommandID = "select.right"
    public static let extendUp: CommandID = "select.extendUp"
    public static let extendDown: CommandID = "select.extendDown"
    public static let extendLeft: CommandID = "select.extendLeft"
    public static let extendRight: CommandID = "select.extendRight"
    public static let selectRoot: CommandID = "select.root"
    public static let selectSiblings: CommandID = "select.siblings"
    public static let selectChildren: CommandID = "select.children"
    public static let selectAll: CommandID = "select.all"
    public static let collapseSelection: CommandID = "select.collapse"
    public static let find: CommandID = "find.show"
    public static let findNext: CommandID = "find.next"
    public static let findPrevious: CommandID = "find.previous"
    public static let replace: CommandID = "find.replace"
    public static let replaceAll: CommandID = "find.replaceAll"
    public static let palette: CommandID = "view.palette"
    public static let quickJump: CommandID = "view.quickJump"
    public static let flyBack: CommandID = "navigate.flyBack"
    // Restructure
    public static let moveUp: CommandID = "topic.moveUp"
    public static let moveDown: CommandID = "topic.moveDown"
    public static let promote: CommandID = "topic.promote"
    public static let demote: CommandID = "topic.demote"
    public static let delete: CommandID = "topic.delete"
    public static let deleteKeepChildren: CommandID = "topic.deleteKeepChildren"
    public static let fold: CommandID = "topic.fold"
    public static let foldAll: CommandID = "topic.foldAll"
    public static func structure(_ n: Int) -> CommandID { CommandID(rawValue: "structure.\(n)") }
    // Elements
    public static let connect: CommandID = "element.connect"
    // Technical canvases (M4)
    public static let slashMenu: CommandID = "insert.slash"
    public static let laneUp: CommandID = "diagram.laneUp"
    public static let laneDown: CommandID = "diagram.laneDown"
    public static let iconLibrary: CommandID = "diagram.iconLibrary"
    public static let copyMermaid: CommandID = "diagram.copyMermaid"
    public static let threatTable: CommandID = "diagram.threatTable"
    public static let suggestThreats: CommandID = "diagram.suggestThreats"
    // AI actions (M6), also in ⌘K
    public static let aiBreakdown: CommandID = "ai.breakdown"
    public static let aiTodos: CommandID = "ai.todos"
    public static let aiFindGaps: CommandID = "ai.findGaps"
    public static let aiExpand: CommandID = "ai.expand"
    public static let aiRewrite: CommandID = "ai.rewrite"
    public static let aiSummarize: CommandID = "ai.summarize"
    public static let aiTranslate: CommandID = "ai.translate"
    public static let aiMask: CommandID = "ai.mask"
    public static let aiRemoveBackground: CommandID = "ai.removeBackground"
    public static let aiSticker: CommandID = "ai.sticker"
    public static let aiRecord: CommandID = "ai.record"
    // Outline (M5)
    public static let outlineIndent: CommandID = "outline.indent"
    public static let outlineOutdent: CommandID = "outline.outdent"
    public static let outlineSibling: CommandID = "outline.sibling"
    public static let outlinePrevious: CommandID = "outline.previous"
    public static let outlineNext: CommandID = "outline.next"
    public static let outlineCollapse: CommandID = "outline.collapse"
    public static let outlineExpand: CommandID = "outline.expand"
    public static let boundary: CommandID = "element.boundary"
    public static let summary: CommandID = "element.summary"
    public static let callout: CommandID = "element.callout"
    public static let note: CommandID = "element.note"
    public static let hyperlink: CommandID = "element.hyperlink"
    /// Topic comments (M14).
    public static let comment: CommandID = "element.comment"
    public static let image: CommandID = "element.image"
    public static let label: CommandID = "element.label"
    public static func priority(_ n: Int) -> CommandID { CommandID(rawValue: "marker.priority\(n)") }
    public static let toggleTodo: CommandID = "marker.todo"
    public static let markerPicker: CommandID = "marker.picker"
    public static let zone: CommandID = "element.zone"
    public static let bringToFront: CommandID = "element.bringToFront"
    public static let sendToBack: CommandID = "element.sendToBack"
    // Style
    public static let copyStyle: CommandID = "style.copy"
    public static let pasteStyle: CommandID = "style.paste"
    public static let resetStyle: CommandID = "style.reset"
    public static func quickStyle(_ n: Int) -> CommandID { CommandID(rawValue: "style.quick\(n)") }
    public static let cycleNodeStyle: CommandID = "style.cycleNodeStyle"
    public static let smartColor: CommandID = "style.smartColor"
    // View
    public static let zoomIn: CommandID = "view.zoomIn"
    public static let zoomOut: CommandID = "view.zoomOut"
    public static let actualSize: CommandID = "view.actualSize"
    public static let fitToWindow: CommandID = "view.fit"
    public static let focusBranch: CommandID = "view.focus"
    public static let zen: CommandID = "view.zen"
    public static let toggleOutline: CommandID = "view.toggleOutline"
    public static let showCanvas: CommandID = "view.canvas"
    public static let showOutline: CommandID = "view.outline"
    public static let showSplit: CommandID = "view.split"
    public static let inspector: CommandID = "view.inspector"
    /// F6 / ⇧F6: move keyboard focus between the window's panels (M10).
    public static let nextPanel: CommandID = "view.nextPanel"
    public static let previousPanel: CommandID = "view.previousPanel"
    public static let filterBar: CommandID = "view.filter"
    public static let present: CommandID = "view.present"
    public static let convert: CommandID = "view.convert"
    public static func navigationTab(_ n: Int) -> CommandID { CommandID(rawValue: "view.navigationTab\(n)") }
    // AI
    public static let aiGhosts: CommandID = "ai.ghosts"
    public static let aiAccept: CommandID = "ai.accept"
    public static let aiAcceptAll: CommandID = "ai.acceptAll"
    public static let aiPrompt: CommandID = "ai.prompt"
    public static let aiPanel: CommandID = "ai.panel"
    // File
    public static let newCanvas: CommandID = "file.newCanvas"
    public static let newCanvasFromTopic: CommandID = "file.newCanvasFromTopic"
    public static let export: CommandID = "file.export"
    public static let mapShot: CommandID = "file.mapShot"
    public static let copyAsImage: CommandID = "file.copyAsImage"
    public static let copyAsMarkdown: CommandID = "file.copyAsMarkdown"
    public static let home: CommandID = "app.home"
    public static let newChooseType: CommandID = "file.newChooseType"
    public static let printDocument: CommandID = "file.print"
    public static let printBranch: CommandID = "file.printBranch"
    public static let importFile: CommandID = "file.import"
    public static let mergeDocuments: CommandID = "file.merge"
    public static let setPassword: CommandID = "file.setPassword"
    public static let recoverySnapshots: CommandID = "file.recoverySnapshots"
    public static let exportBranchPNG: CommandID = "file.exportBranchPNG"
    public static let exportBranchSVG: CommandID = "file.exportBranchSVG"
    public static let exportBranchMarkdown: CommandID = "file.exportBranchMarkdown"
    public static let exportZone: CommandID = "file.exportZone"
    public static let printZone: CommandID = "file.printZone"
    public static let splitByBranch: CommandID = "file.splitByBranch"
    public static let duplicateCanvas: CommandID = "canvas.duplicate"
    public static let renameCanvas: CommandID = "canvas.rename"
    public static let deleteCanvas: CommandID = "canvas.delete"
    public static let copyCanvas: CommandID = "canvas.copy"
    public static let pasteCanvas: CommandID = "canvas.paste"
    public static let saveCanvasAsDocument: CommandID = "canvas.saveAsDocument"
    public static let moveCanvasToWindow: CommandID = "canvas.moveToWindow"
    public static let copy: CommandID = "edit.copy"
    public static let cut: CommandID = "edit.cut"
    public static let paste: CommandID = "edit.paste"
    public static let pasteImageAsMap: CommandID = "edit.pasteImageAsMap"
    public static let quickCapture: CommandID = "app.quickCapture"
    public static let undo: CommandID = "edit.undo"
    public static let redo: CommandID = "edit.redo"
    // Task planning (M11)
    public static let taskDetails: CommandID = "task.details"
    public static let showGantt: CommandID = "view.gantt"
    public static let exportGantt: CommandID = "file.exportGantt"
    public static let ganttPrevious: CommandID = "gantt.previous"
    public static let ganttNext: CommandID = "gantt.next"
    public static let ganttExtendUp: CommandID = "gantt.extendUp"
    public static let ganttExtendDown: CommandID = "gantt.extendDown"
    public static let ganttCollapse: CommandID = "gantt.collapse"
    public static let ganttExpand: CommandID = "gantt.expand"
    public static let ganttEarlier: CommandID = "gantt.earlier"
    public static let ganttLater: CommandID = "gantt.later"
    public static let ganttWeekEarlier: CommandID = "gantt.weekEarlier"
    public static let ganttWeekLater: CommandID = "gantt.weekLater"
    public static let ganttShorten: CommandID = "gantt.shorten"
    public static let ganttLengthen: CommandID = "gantt.lengthen"
    public static let ganttToggleDone: CommandID = "gantt.toggleDone"
    public static func ganttProgress(_ n: Int) -> CommandID { CommandID(rawValue: "gantt.progress\(n)") }
    public static let ganttLink: CommandID = "gantt.link"
    public static let ganttUnlink: CommandID = "gantt.unlink"
    public static let ganttScheduleToday: CommandID = "gantt.scheduleToday"
    public static let ganttToday: CommandID = "gantt.today"
    public static let ganttEditTask: CommandID = "gantt.editTask"
    public static let ganttExit: CommandID = "gantt.exit"
    // Connect mode
    public static let connectConfirm: CommandID = "connect.confirm"
    public static let connectCancel: CommandID = "connect.cancel"
}

/// The OpenNexus default key map: Xmind's keys unchanged, plus Connect, Convert and AI
/// (brief §4, artboards 05 Keyboard and 06 Shortcuts, README §7).
public enum DefaultCommands {
    private static func k(_ spec: String) -> KeyChord {
        guard let c = KeyChord(spec) else { fatalError("bad chord \(spec)") }
        return c
    }

    typealias C = CommandDescriptor

    public static let all: [CommandDescriptor] =
        create + edit + navigate + restructure + elements + style + view + ai
        + file + connect + diagrams + outline + aiActions + tasks

    static let aiActions: [C] = [
        C(.aiBreakdown, "Break Down", .ai, menu: .ai, note: "Phases with priority and duration, as ghosts"),
        C(.aiTodos, "Make To-dos", .ai, menu: .ai, note: "Checkable steps with a progress ring"),
        C(.aiFindGaps, "Find Gaps", .ai, menu: .ai, note: "What's missing, as ghosts"),
        C(.aiExpand, "Expand Branch", .ai, menu: .ai, note: "More children, as ghosts"),
        C(.aiRewrite, "Rewrite Shorter", .ai, menu: .ai, note: "A plan of renames to review"),
        C(.aiSummarize, "Summarize", .ai, menu: .ai, note: "In the AI panel"),
        C(.aiTranslate, "Translate Map…", .ai, menu: .ai, note: "A new canvas; the original stays"),
        C(.aiMask, "Mask Data…", .ai, menu: .ai, note: "Emails, keys, names, phones; review each hit"),
        C(.aiRemoveBackground, "Remove Image Background", .ai, menu: .ai, note: "Subject lift"),
        C(.aiSticker, "Make a Sticker…", .ai, menu: .ai, note: "Image Playground"),
        C(.aiRecord, "Record to Map…", .ai, menu: .ai, note: "Live transcript; key points as ghosts"),
    ]

    /// Task planning and the Gantt view (M11). Gantt keys live in their own scope (D146).
    static let tasks: [C] =
        [
            C(
                .taskDetails, "Task…", .elements, keys: [k("ctrl+cmd+t")], menu: .topic,
                note: "Start, due, owner, progress, dependencies"),
            C(
                .showGantt, "Gantt", .view, scope: .global, keys: [k("cmd+4")], menu: .view,
                note: "The canvas's tasks on a timeline"),
            C(.exportGantt, "Export Gantt…", .file, scope: .global, menu: .file, note: "PNG, JPEG, PDF, CSV, Calendar"),
            C(.ganttPrevious, "Previous Task", .navigate, scope: .gantt, keys: [k("up")], note: "Gantt"),
            C(.ganttNext, "Next Task", .navigate, scope: .gantt, keys: [k("down")], note: "Gantt"),
            C(.ganttExtendUp, "Extend Selection Up", .navigate, scope: .gantt, keys: [k("shift+up")], note: "Gantt"),
            C(
                .ganttExtendDown, "Extend Selection Down", .navigate, scope: .gantt, keys: [k("shift+down")],
                note: "Gantt"),
            C(.ganttCollapse, "Collapse Row", .navigate, scope: .gantt, keys: [k("left")], note: "Gantt"),
            C(.ganttExpand, "Expand Row", .navigate, scope: .gantt, keys: [k("right")], note: "Gantt"),
            C(
                .ganttEarlier, "Move a Working Day Earlier", .restructure, scope: .gantt, keys: [k("opt+left")],
                note: "Dependants follow"),
            C(
                .ganttLater, "Move a Working Day Later", .restructure, scope: .gantt, keys: [k("opt+right")],
                note: "Dependants follow"),
            C(.ganttWeekEarlier, "Move a Week Earlier", .restructure, scope: .gantt, keys: [k("opt+cmd+left")]),
            C(.ganttWeekLater, "Move a Week Later", .restructure, scope: .gantt, keys: [k("opt+cmd+right")]),
            C(.ganttShorten, "Shorten by a Working Day", .restructure, scope: .gantt, keys: [k("opt+shift+left")]),
            C(.ganttLengthen, "Lengthen by a Working Day", .restructure, scope: .gantt, keys: [k("opt+shift+right")]),
            C(.ganttToggleDone, "Mark Done", .elements, scope: .gantt, keys: [k("space")], note: "Gantt"),
            C(
                .ganttLink, "Link Tasks", .elements, scope: .gantt, keys: [k("cmd+l")],
                note: "Selected tasks, finish to start, in row order"),
            C(.ganttUnlink, "Remove Dependencies", .elements, scope: .gantt, keys: [k("shift+cmd+l")]),
            C(
                .ganttScheduleToday, "Schedule from Today", .elements, scope: .gantt, keys: [k("cmd+d")],
                note: "Undated tasks start today"),
            C(.ganttToday, "Go to Today", .navigate, scope: .gantt, keys: [k("t")]),
            C(.ganttEditTask, "Edit Task…", .edit, scope: .gantt, keys: [k("return")], note: "Gantt"),
            C(.ganttExit, "Back to Canvas", .view, scope: .gantt, keys: [k("esc")], note: "Keeps the selection"),
        ]
        + (0...9).map { n in
            C(.ganttProgress(n), "Progress \(n * 10)%", .elements, scope: .gantt, keys: [k("\(n)")], note: "Gantt")
        }

    static let outline: [C] = [
        C(.outlineSibling, "Add Sibling", .create, scope: .outline, keys: [k("return")], note: "Outline"),
        C(.outlineIndent, "Indent", .restructure, scope: .outline, keys: [k("tab")], note: "Outline"),
        C(.outlineOutdent, "Outdent", .restructure, scope: .outline, keys: [k("shift+tab")], note: "Outline"),
        C(.outlinePrevious, "Previous Row", .navigate, scope: .outline, keys: [k("up")]),
        C(.outlineNext, "Next Row", .navigate, scope: .outline, keys: [k("down")]),
        C(.outlineCollapse, "Collapse / Parent", .navigate, scope: .outline, keys: [k("left")]),
        C(.outlineExpand, "Expand / Child", .navigate, scope: .outline, keys: [k("right")]),
    ]

    static let diagrams: [C] = [
        C(
            .slashMenu, "Insert…", .elements, keys: [k("/")], menu: .insert,
            note: "Slash menu: node types, icons, /math, /code; also / at the start of a topic"),
        C(.laneUp, "Move to Lane Above", .restructure, keys: [k("opt+up")], menu: .topic, note: "Swimlanes"),
        C(.laneDown, "Move to Lane Below", .restructure, keys: [k("opt+down")], menu: .topic, note: "Swimlanes"),
        C(
            .iconLibrary, "Icon Library", .view, scope: .global, keys: [k("shift+cmd+y")], menu: .view,
            note: "Architecture icons; ↩ inserts a child"),
        C(.copyMermaid, "Copy as Mermaid", .file, scope: .global, menu: .edit, note: "Sequence and flowchart"),
        C(.threatTable, "Threat Table", .view, scope: .global, menu: .view, note: "Threat models"),
        C(.suggestThreats, "Suggest STRIDE Threats", .ai, menu: .ai, note: "Threat models"),
    ]

    static let create: [C] = [
        C(
            .addChild, "Add Child Topic", .create, keys: [k("tab")], menu: .insert, xmind: true,
            note: "Select or Edit mode; child starts in Edit"),
        C(
            .addSiblingAfter, "Add Sibling After", .create, keys: [k("return")], menu: .insert, xmind: true,
            note: "In Edit, first ↩ commits, next creates"),
        C(
            .addSiblingBefore, "Add Sibling Before", .create, keys: [k("shift+return")], menu: .insert, xmind: true,
            note: "In Edit, ⇧↩ is a line break"),
        C(
            .addParent, "Add Parent Topic", .create, keys: [k("cmd+return")], menu: .insert, xmind: true,
            note: "Inserts between selection and parent"),
        C(
            .addFloating, "Add Floating Topic", .create, keys: [k("opt+cmd+return")], menu: .insert, xmind: true,
            note: "Or double-click empty canvas"),
        C(
            .duplicate, "Duplicate Branch", .create, keys: [k("cmd+d")], menu: .topic,
            note: "Copy lands after the original"),
    ]

    static let edit: [C] = [
        C(.editKeepText, "Edit Topic", .edit, keys: [k("space")], menu: .topic, xmind: true, note: "Caret at end"),
        C(
            .commitEdit, "Commit", .edit, scope: .editor, keys: [k("return"), k("esc")], xmind: true,
            note: "Both return to Select on the same node"),
        C(.commitAndAddChild, "Commit and Add Child", .edit, scope: .editor, keys: [k("tab")], xmind: true),
        C(.commitAndPromote, "Commit and Promote", .edit, scope: .editor, keys: [k("shift+tab")]),
        C(.commitAndAddParent, "Commit and Add Parent", .edit, scope: .editor, keys: [k("cmd+return")], xmind: true),
        C(.lineBreak, "Line Break", .edit, scope: .editor, keys: [k("shift+return")], xmind: true),
        C(.bold, "Bold", .edit, scope: .editor, keys: [k("cmd+b")], xmind: true),
        C(.italic, "Italic", .edit, scope: .editor, keys: [k("cmd+i")], xmind: true),
        C(.editorLink, "Link", .edit, scope: .editor, keys: [k("cmd+k")], xmind: true),
        C(.undo, "Undo", .edit, scope: .global, keys: [k("cmd+z")], menu: .edit, xmind: true, standardAction: "undo:"),
        C(
            .redo, "Redo", .edit, scope: .global, keys: [k("shift+cmd+z")], menu: .edit, xmind: true,
            standardAction: "redo:"),
    ]

    static let navigate: [C] = [
        C(.selectUp, "Select Up", .navigate, keys: [k("up")], xmind: true, note: "Spatial: nearest node that way"),
        C(.selectDown, "Select Down", .navigate, keys: [k("down")], xmind: true),
        C(.selectLeft, "Select Left", .navigate, keys: [k("left")], xmind: true),
        C(.selectRight, "Select Right", .navigate, keys: [k("right")], xmind: true),
        C(.extendUp, "Extend Selection Up", .navigate, keys: [k("shift+up")], xmind: true),
        C(.extendDown, "Extend Selection Down", .navigate, keys: [k("shift+down")], xmind: true),
        C(.extendLeft, "Extend Selection Left", .navigate, keys: [k("shift+left")], xmind: true),
        C(.extendRight, "Extend Selection Right", .navigate, keys: [k("shift+right")], xmind: true),
        C(.selectRoot, "Jump to Central Topic", .navigate, keys: [k("cmd+home")], menu: .edit, xmind: true),
        C(.selectSiblings, "Select Siblings", .navigate, keys: [k("shift+cmd+a")], menu: .edit, xmind: true),
        C(.selectChildren, "Select Children", .navigate, keys: [k("opt+cmd+a")], menu: .edit, xmind: true),
        C(.selectAll, "Select All Topics", .navigate, keys: [k("cmd+a")], menu: .edit, xmind: true),
        C(.collapseSelection, "Select Only Primary", .navigate, keys: [k("esc")]),
        C(
            .find, "Find and Replace…", .navigate, scope: .global, keys: [k("cmd+f")], menu: .edit, xmind: true,
            note: "Matches glow on canvas and list"),
        C(.findNext, "Find Next", .navigate, scope: .global, keys: [k("cmd+g")], menu: .edit),
        C(.findPrevious, "Find Previous", .navigate, scope: .global, keys: [k("shift+cmd+g")], menu: .edit),
        C(.replace, "Replace", .navigate, scope: .find, keys: [k("opt+return")]),
        C(.replaceAll, "Replace All", .navigate, scope: .find, keys: [k("opt+cmd+return")]),
        C(
            .palette, "Command Palette…", .navigate, keys: [k("cmd+k")], hyper: k("hyper+k"), menu: .view,
            note: "Every action, with its key"),
        C(
            .quickJump, "Quick Jump…", .navigate, scope: .global, keys: [k("cmd+j")], menu: .view,
            note: "Fuzzy node search; ↩ flies there"),
        C(.flyBack, "Fly Back", .navigate, keys: [k("cmd+[")], menu: .view, note: "After following a topic link"),
    ]

    static let restructure: [C] =
        [
            C(.moveUp, "Move Up", .restructure, keys: [k("opt+cmd+up")], menu: .topic, note: "Animated swap"),
            C(.moveDown, "Move Down", .restructure, keys: [k("opt+cmd+down")], menu: .topic, note: "Animated swap"),
            C(.promote, "Promote", .restructure, keys: [k("shift+tab")], menu: .topic, note: "Outdent one level"),
            C(
                .demote, "Demote", .restructure, keys: [k("opt+cmd+right")], menu: .topic,
                note: "Under previous sibling"),
            C(.delete, "Delete", .restructure, keys: [k("delete"), k("fwddelete")], menu: .topic, xmind: true),
            C(
                .deleteKeepChildren, "Delete, Keep Children", .restructure, keys: [k("opt+delete")], menu: .topic,
                note: "Children move up a level"),
            C(
                .fold, "Fold / Unfold Branch", .restructure, keys: [k("cmd+/")], menu: .topic, xmind: true,
                note: "Badge shows hidden count"),
            C(.foldAll, "Fold / Unfold All", .restructure, keys: [k("opt+cmd+/")], menu: .topic, xmind: true),
        ]
        + (1...9).map { n in
            C(
                .structure(n), "Branch Structure \(n)", .restructure, keys: [k("opt+cmd+\(n)")], hyper: k("hyper+\(n)"),
                menu: .format, note: "Cycles structure of the branch")
        }

    static let elements: [C] =
        [
            C(
                .connect, "Relationship (Connect Mode)", .elements, keys: [k("shift+cmd+l")], hyper: k("hyper+c"),
                menu: .insert, note: "Opens Connect mode"),
            C(.boundary, "Boundary", .elements, keys: [k("shift+cmd+b")], menu: .insert, xmind: true),
            C(.summary, "Summary", .elements, keys: [k("shift+cmd+]")], menu: .insert, xmind: true),
            C(.callout, "Callout", .elements, keys: [k("shift+cmd+c")], menu: .insert, xmind: true),
            C(.note, "Note", .elements, keys: [k("shift+cmd+n")], menu: .insert, xmind: true),
            C(.hyperlink, "Hyperlink…", .elements, keys: [k("shift+cmd+k")], menu: .insert, xmind: true),
            C(
                .comment, "Comment…", .elements, keys: [k("ctrl+cmd+n")], menu: .insert,
                note: "Add, edit and delete review comments"),
            C(.image, "Image…", .elements, keys: [k("shift+cmd+i")], menu: .insert, xmind: true),
            C(
                .label, "Label", .elements, keys: [k("shift+cmd+t")], hyper: k("hyper+l"), menu: .insert,
                note: "Resolves Xmind’s ⇧⌘L clash"),
            C(.toggleTodo, "To-Do", .elements, keys: [k("ctrl+0")], menu: .insert, note: "Strikes through when done"),
            C(.markerPicker, "Markers…", .elements, keys: [k("shift+cmd+m")], menu: .insert),
            C(.zone, "Zone", .elements, keys: [k("opt+cmd+z")], menu: .insert),
            C(.bringToFront, "Bring to Front", .elements, keys: [k("opt+cmd+]")], menu: .format),
            C(.sendToBack, "Send to Back", .elements, keys: [k("opt+cmd+[")], menu: .format),
        ]
        + (1...9).map { n in
            C(.priority(n), "Priority \(n)", .elements, keys: [k("ctrl+\(n)")], menu: .insert)
        }

    static let style: [C] =
        [
            C(.copyStyle, "Copy Style", .style, keys: [k("opt+cmd+c")], menu: .format, xmind: true),
            C(.pasteStyle, "Paste Style", .style, keys: [k("opt+cmd+v")], menu: .format, xmind: true),
            C(.resetStyle, "Reset Style", .style, keys: [k("opt+cmd+r")], menu: .format),
            C(.cycleNodeStyle, "Next Node Style", .style, keys: [k("opt+cmd+s")], menu: .format, note: "300 ms morph"),
            C(
                .smartColor, "Smart Color", .style, keys: [k("shift+cmd+r")], menu: .format,
                note: "Reshuffles branch colours"),
        ]
        + (1...8).map { n in
            C(.quickStyle(n), "Quick Style \(n)", .style, keys: [k("ctrl+opt+\(n)")], menu: .format)
        }

    static let view: [C] =
        [
            C(.zoomIn, "Zoom In", .view, scope: .global, keys: [k("cmd+=")], menu: .view, xmind: true),
            C(.zoomOut, "Zoom Out", .view, scope: .global, keys: [k("cmd+-")], menu: .view, xmind: true),
            C(.actualSize, "Actual Size", .view, scope: .global, keys: [k("cmd+0")], menu: .view, xmind: true),
            C(
                .fitToWindow, "Fit Map to Window", .view, scope: .global, keys: [k("shift+cmd+0")], menu: .view,
                xmind: true),
            C(
                .focusBranch, "Focus on Branch", .view, keys: [k("cmd+.")], hyper: k("hyper+f"), menu: .view,
                note: "Esc climbs out"),
            C(.zen, "ZEN Mode", .view, scope: .global, keys: [k("opt+cmd+f")], menu: .view, xmind: true),
            C(
                .toggleOutline, "Toggle Outline", .view, scope: .global, keys: [k("shift+cmd+o")], menu: .view,
                xmind: true),
            C(.showCanvas, "Canvas", .view, scope: .global, keys: [k("cmd+1")], menu: .view),
            C(.showOutline, "Outline", .view, scope: .global, keys: [k("cmd+2")], menu: .view),
            C(.showSplit, "Split", .view, scope: .global, keys: [k("cmd+3")], menu: .view),
            C(.inspector, "Format Panel", .view, keys: [k("cmd+i")], menu: .view, xmind: true),
            C(
                .nextPanel, "Move Focus to Next Panel", .view, scope: .global, keys: [k("f6")], menu: .view,
                note: "Canvas, tabs, Format panel, AI panel"),
            C(
                .previousPanel, "Move Focus to Previous Panel", .view, scope: .global, keys: [k("shift+f6")],
                menu: .view),
            C(.filterBar, "Filter…", .view, scope: .global, keys: [k("shift+cmd+f")], menu: .view),
            C(
                .present, "Present", .view, scope: .global, keys: [k("shift+cmd+p")], hyper: k("hyper+p"), menu: .view,
                xmind: true),
            C(
                .convert, "Convert Diagram Type…", .view, scope: .global, keys: [k("opt+cmd+t")], hyper: k("hyper+t"),
                menu: .format, note: "Live previews in the picker"),
        ]
        + zip(1...5, ["Search", "Outline", "Notes", "Tags", "To-dos"]).map { n, name in
            C(.navigationTab(n), "Navigation: \(name)", .view, scope: .global, keys: [k("ctrl+cmd+\(n)")], menu: .view)
        }

    static let ai: [C] = [
        C(
            .aiGhosts, "Suggest Ideas", .ai, keys: [k("opt+space")], hyper: k("hyper+space"), menu: .ai,
            note: "Ghost children; ⌃↩ accepts"),
        C(.aiAccept, "Accept Suggestion", .ai, keys: [k("ctrl+return")], menu: .ai),
        C(.aiAcceptAll, "Accept All Suggestions", .ai, keys: [k("ctrl+shift+return")], menu: .ai),
        C(.aiPrompt, "Ask AI…", .ai, scope: .global, keys: [k("shift+cmd+space")], hyper: k("hyper+a"), menu: .ai),
        C(.aiPanel, "AI Panel", .ai, scope: .global, keys: [k("shift+cmd+j")], hyper: k("hyper+j"), menu: .ai),
    ]

    static let file: [C] = [
        C(.newCanvas, "New Canvas", .file, scope: .global, keys: [k("cmd+t")], menu: .file),
        C(.newCanvasFromTopic, "New Canvas from Topic", .file, keys: [k("opt+cmd+n")], menu: .file),
        C(.export, "Export…", .file, scope: .global, keys: [k("shift+cmd+e")], menu: .file),
        C(.mapShot, "Map Shot", .file, scope: .global, keys: [k("ctrl+cmd+m")], menu: .file),
        C(.copyAsImage, "Copy as Image", .file, keys: [k("ctrl+cmd+c")], menu: .edit),
        C(.copyAsMarkdown, "Copy as Markdown", .file, menu: .edit),
        C(.home, "Home", .app, scope: .global, keys: [k("shift+cmd+h")], menu: .file, standardAction: "showHome:"),
        C(
            .newChooseType, "New Document of Type…", .file, scope: .global, menu: .file, note: "⇧⌘N on Home",
            standardAction: "newDocumentChooseType:"),
        C(.printDocument, "Print…", .file, scope: .global, keys: [k("cmd+p")], menu: .file, xmind: true),
        C(.printBranch, "Print Branch…", .file, menu: .file),
        C(
            .importFile, "Import…", .file, scope: .global, menu: .file,
            note: ".xmind, OPML, Markdown, Mermaid, draw.io …"),
        C(
            .mergeDocuments, "Merge Documents…", .file, scope: .global, menu: .file,
            note: "As canvases or into this canvas"),
        C(.setPassword, "Set Password…", .file, scope: .global, menu: .file),
        C(.recoverySnapshots, "Browse Recovery Snapshots…", .file, scope: .global, menu: .file),
        C(.exportBranchPNG, "Export Branch as PNG…", .file, menu: .file),
        C(.exportBranchSVG, "Export Branch as SVG…", .file, menu: .file),
        C(.exportBranchMarkdown, "Export Branch as Markdown…", .file, menu: .file),
        C(.exportZone, "Export Zone…", .file, menu: .file, note: "The selected zone and its contents"),
        C(.printZone, "Print Zone…", .file, menu: .file, note: "The selected zone and its contents"),
        C(.splitByBranch, "Export Split by Main Branch…", .file, scope: .global, menu: .file),
        C(.duplicateCanvas, "Duplicate Canvas", .file, scope: .global, menu: .file),
        C(.renameCanvas, "Rename Canvas…", .file, scope: .global, menu: .file),
        C(.deleteCanvas, "Delete Canvas…", .file, scope: .global, menu: .file),
        C(.copyCanvas, "Copy Canvas", .file, scope: .global, menu: .file),
        C(.pasteCanvas, "Paste Canvas", .file, scope: .global, menu: .file),
        C(.saveCanvasAsDocument, "Save Canvas as Document…", .file, scope: .global, menu: .file),
        C(.moveCanvasToWindow, "Move Canvas to New Window", .file, scope: .global, menu: .file),
        C(.cut, "Cut", .edit, keys: [k("cmd+x")], menu: .edit, xmind: true, standardAction: "cut:"),
        C(.copy, "Copy", .edit, keys: [k("cmd+c")], menu: .edit, xmind: true, standardAction: "copy:"),
        C(
            .paste, "Paste", .edit, keys: [k("cmd+v")], menu: .edit, xmind: true,
            note: "Markdown or indented text becomes a branch", standardAction: "paste:"),
        C(
            .pasteImageAsMap, "Paste Image as Map", .edit, keys: [k("shift+cmd+v")], menu: .edit,
            note: "Reads the text in a copied picture"),
        C(.quickCapture, "Quick Capture", .app, scope: .global, hyper: k("hyper+n"), note: "System-wide"),
    ]

    static let connect: [C] = [
        C(
            .connectConfirm, "Connect to Target", .elements, scope: .connect, keys: [k("return")],
            note: "Draws the edge and opens its label"),
        C(.connectCancel, "Cancel Connect", .elements, scope: .connect, keys: [k("esc")], note: "Nothing changes"),
    ]
}

extension KeyProfile {
    private static func k(_ spec: String) -> KeyChord { KeyChord(spec)! }

    /// Xmind-compatible defaults, plus the Xmind alias set (⌘R, ⌘⌫, ⌘;).
    public static let openNexus = KeyProfile(
        id: "opennexus", name: "OpenNexus",
        additions: [
            .connect: [k("cmd+r")],
            .deleteKeepChildren: [k("cmd+delete")],
            .focusBranch: [k("cmd+;")],
        ])

    public static let hyperFirst = KeyProfile(
        id: "hyper", name: "Hyper-first", additions: openNexus.additions,
        hyperFirst: true)

    /// Outliner-style: Tab indents and ⇧Tab outdents, as in an outline editor.
    public static let outliner = KeyProfile(
        id: "outliner", name: "Outliner",
        overrides: [
            .addChild: [k("opt+return")],
            .demote: [k("tab"), k("opt+cmd+right")],
        ])

    /// Vim-style: typing no longer replaces the selection, so letters become commands.
    public static let vim = KeyProfile(
        id: "vim", name: "Vim-style",
        additions: [
            .selectLeft: [k("h")], .selectDown: [k("j")], .selectUp: [k("k")], .selectRight: [k("l")],
            .extendLeft: [k("shift+h")], .extendDown: [k("shift+j")], .extendUp: [k("shift+k")],
            .extendRight: [k("shift+l")],
            .editKeepText: [k("i"), k("a")],
            .addSiblingAfter: [k("o")], .addSiblingBefore: [k("shift+o")],
            .delete: [k("x")], .fold: [k("z")], .selectRoot: [k("g")],
        ],
        typingReplacesSelection: false)

    public static let all: [KeyProfile] = [.openNexus, .hyperFirst, .outliner, .vim]
}
