import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// M22: task fields and comments in Markdown, OPML, MindManager and Excel.
@Suite struct TaskFormatTests {
    func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }
    func node(_ c: Canvas, _ text: String) -> Node { c.nodes.values.first { $0.text == text }! }

    /// The launch plan with tasks, dependencies, comments, a second "Pricing" with a comment
    /// (so the appendix needs an anchor), and to-dos whose titles look like task tokens.
    func plan() -> Canvas {
        var c = launchPlan()
        var u = UndoStack()
        c.edit("Tasks", undo: &u) { e in
            let beta = id(e.canvas, "Beta · Nov")
            let ga = id(e.canvas, "GA · Jan")
            let pro = id(e.canvas, "Pro")
            let news = id(e.canvas, "Newsletter")
            let risks = id(e.canvas, "Risks")
            e.updateTask(beta) {
                $0.start = TaskDate("2026-11-02")
                $0.due = TaskDate("2026-11-06")
                $0.owner = "Ana"
                $0.progress = 40
            }
            e.updateTask(ga) {
                $0.due = TaskDate("2027-01-15")
                $0.owner = "Ana Lee"
            }
            try! e.addDependency(ga, on: beta)
            e.updateTask(pro) { $0.start = TaskDate("2026-11-09") }
            try! e.addDependency(pro, on: beta, type: .startToStart, lag: 2)
            e.updateTask(news) {
                $0.done = true
                $0.owner = "Sam"
            }
            let raise = try! e.addChild(of: risks, text: "Raise to 40%")
            e.update(raise) { $0.todo = Todo(done: false) }
            let mail = try! e.addChild(of: risks, text: "Email @Bob")
            e.update(mail) { $0.todo = Todo(done: true) }
            let other = try! e.addChild(of: risks, text: "Pricing")
            e.update(other) {
                $0.comments = [TopicComment(author: "Kim", date: "2026-10-22T08:15:00+02:00", text: "Which pricing?")]
            }
            e.update(id(e.canvas, "Free tier")) { $0.comments = [TopicComment(author: "Lee", date: "", text: "OK")] }
            let pricing = e.canvas.nodes.first { $0.value.text == "Pricing" && $0.key != other }!.key
            e.update(pricing) {
                $0.comments = [
                    TopicComment(
                        author: "Ana", date: "2026-10-20T14:03:00Z", text: "Drop the annual tier?\nOr discount it."),
                    TopicComment(author: "", date: "", text: "Agreed"),
                ]
            }
        }
        return c
    }

    /// Each topic in outline order with its task fields (dependencies by title), priority
    /// and comments.
    func summary(_ c: Canvas) -> [String] {
        var out: [String] = []
        c.walk { _, n, d in
            var s = String(repeating: ".", count: d) + n.text
            if let t = n.todo {
                s += " | done \(t.done) start \(t.start?.description ?? "-") due \(t.due?.description ?? "-")"
                s += " owner \(t.owner ?? "-") progress \(t.progress ?? 0)"
                s +=
                    " after "
                    + t.after.map { "\(c.nodes[$0.task]?.text ?? "?")/\($0.type.rawValue)/\($0.lag)" }
                    .joined(separator: ",")
            }
            if let p = n.priority { s += " | P\(p)" }
            for cm in n.comments { s += " | “\(cm.author)” “\(cm.date)” “\(cm.text)”" }
            out.append(s)
        }
        return out
    }

    func reimport(_ text: String, _ name: String) throws -> Imported {
        try Interchange.importFile(name: name, data: Data(text.utf8))
    }

    // MARK: Markdown

    @Test func markdownWritesReadableTaskTokens() {
        let c = plan()
        let md = MarkdownFormat.export(c)
        let beta = id(c, "Beta · Nov").rawValue
        #expect(md.contains("- [ ] Beta · Nov @Ana 2026-11-02→2026-11-06 40% ^\(beta)\n"))
        #expect(md.contains("- [ ] GA · Jan @[Ana Lee] →2027-01-15 after:^\(beta)\n"), "\(md)")
        #expect(md.contains("- [ ] Pro (P1) 2026-11-09→ after:^\(beta)(SS+2)\n"))
        #expect(md.contains("- [x] Newsletter @Sam\n"))
        #expect(md.contains("- [ ] Raise to \\40%\n"), "a title that reads as a token is escaped")
        #expect(md.contains("- [x] Email \\@Bob\n"))
        // The appendix keeps dates as written and names the second Pricing by its anchor.
        let other = c.nodes.first { $0.value.text == "Pricing" && !$0.value.comments.isEmpty && $0.value.note == nil }!
        #expect(md.contains("- **Pricing** ^\(other.key.rawValue) · Kim · 2026-10-22T08:15:00+02:00: Which pricing?"))
        #expect(md.contains("- **Free tier** · Lee: OK"))
        // A canvas without tasks or comments is written as before.
        #expect(!MarkdownFormat.export(launchPlan()).contains("^"))
    }

    @Test(arguments: [true, false]) func markdownRoundTripsTasksAndComments(headings: Bool) throws {
        let c = plan()
        var o = MarkdownFormat.Options()
        o.headings = headings
        let im = try reimport(MarkdownFormat.export(c, options: o), "plan.md")
        let back = try #require(im.canvases.first)
        #expect(summary(back) == summary(c))
        #expect(back.validate().isEmpty)
        #expect(im.report.tasks == 4 && im.report.dependencies == 2 && im.report.comments == 4)
        #expect(im.report.notConverted == 0, "\(im.report.lines)")
    }

    @Test func markdownReadsOtherToolsSpellings() throws {
        let md = """
            # Plan
            - [ ] Design @[Ana Lee] 2026-11-02->2026-11-06 25% ^d
            - [ ] Code @Sam after:^d(FF-1),^missing ^c
            - [ ] Ship →2026-12-01 after:^c
            - Not a task @Bob 50%
            - [ ] Broken 2026-13-40→
            """
        let im = try reimport(md, "other.md")
        let c = try #require(im.canvases.first)
        let design = node(c, "Design").todo
        #expect(design?.owner == "Ana Lee" && design?.progress == 25)
        #expect(design?.start == TaskDate("2026-11-02") && design?.due == TaskDate("2026-11-06"))
        #expect(node(c, "Code").todo?.after == [TaskDependency(task: id(c, "Design"), type: .finishToFinish, lag: -1)])
        #expect(node(c, "Ship").todo?.due == TaskDate("2026-12-01") && node(c, "Ship").todo?.start == nil)
        #expect(node(c, "Not a task @Bob 50%").todo == nil, "lines without a check box keep their text")
        #expect(node(c, "Broken 2026-13-40→").todo == Todo(done: false), "an impossible date stays text")
        #expect(im.report.skipped.contains { $0.0 == "Task dependency on a missing topic" })
    }

    @Test func aTopicCalledCommentsIsNotAnAppendix() throws {
        let md = """
            # Plan
            ## Comments
            - Collect feedback
            - **Bold** idea
            """
        let c = try #require(try reimport(md, "c.md").canvases.first)
        #expect(summary(c) == ["Plan", ".Comments", "..Collect feedback", "..Bold idea"])
    }

    /// The plan with two floating topics: a parking lot of tasks, one waiting on Beta and
    /// one that GA waits on, with a note and a comment; and a plain floating idea.
    func floatingPlan() -> Canvas {
        var c = plan()
        var u = UndoStack()
        c.edit("Floating", undo: &u) { e in
            let lot = e.addFloating(at: CanvasPoint(x: 400, y: 300), text: "Parking lot")
            e.update(lot) { $0.note = Note(text: "Ideas for after GA.") }
            let docs = try! e.addChild(of: lot, text: "Docs site")
            e.updateTask(docs) {
                $0.owner = "Kim"
                $0.start = TaskDate("2026-11-16")
                $0.progress = 10
            }
            try! e.addDependency(docs, on: id(e.canvas, "Beta · Nov"))
            let audit = try! e.addChild(of: lot, text: "Security audit")
            e.updateTask(audit) {
                $0.due = TaskDate("2026-12-18")
                $0.owner = "Ana Lee"
            }
            e.update(audit) {
                $0.markers = ["priority-2"]
                $0.comments = [TopicComment(author: "Sam", date: "2026-10-21T09:00:00Z", text: "Book it early")]
            }
            try! e.addDependency(id(e.canvas, "GA · Jan"), on: audit, type: .finishToFinish, lag: -1)
            let wiki = try! e.addChild(of: docs, text: "Wiki at 50%")
            e.update(wiki) { $0.todo = Todo(done: true) }
            e.addFloating(at: CanvasPoint(x: -300, y: 300), text: "Stray idea")
        }
        return c
    }

    /// Each floating topic's tree, summarised like the main tree.
    func floatingSummary(_ c: Canvas) -> [String] {
        c.floating.flatMap { f -> [String] in
            var sub = c
            sub.root = f
            return summary(sub)
        }
    }

    @Test(arguments: [true, false]) func markdownRoundTripsFloatingTasks(headings: Bool) throws {
        let c = floatingPlan()
        var o = MarkdownFormat.Options()
        o.headings = headings
        let md = MarkdownFormat.export(c, options: o)
        let audit = id(c, "Security audit").rawValue
        let beta = id(c, "Beta · Nov").rawValue
        #expect(md.contains("\n<!-- Floating topics -->\n\n- Parking lot\n  Ideas for after GA.\n"), "\(md)")
        #expect(md.contains("\n  - [ ] Docs site @Kim 2026-11-16→ 10% after:^\(beta)\n"))
        #expect(md.contains("\n  - [ ] Security audit (P2) @[Ana Lee] →2026-12-18 ^\(audit)\n"))
        #expect(md.contains("\n    - [x] Wiki at \\50%\n"), "a floating to-do's title is escaped too")
        #expect(md.contains(",^\(audit)(FF-1)\n"), "a main-tree task can wait on a floating one")
        #expect(md.contains("- **Security audit** ^\(audit) · Sam · 2026-10-21T09:00:00Z: Book it early"))

        let im = try reimport(md, "plan.md")
        let back = try #require(im.canvases.first)
        #expect(back.floating.count == 2)
        #expect(summary(back) == summary(c), "the main tree keeps none of the floating topics")
        #expect(floatingSummary(back) == floatingSummary(c))
        #expect(back.nodes[back.floating[0]]?.note?.text == "Ideas for after GA.")
        #expect(back.validate().isEmpty)
        #expect(im.report.tasks == 6 && im.report.dependencies == 4 && im.report.comments == 5)
        #expect(im.report.notConverted == 0, "\(im.report.lines)")
        // A branch export has no floating topics.
        #expect(!MarkdownFormat.export(c, from: id(c, "Pricing")).contains("Floating"))
    }

    @Test func floatingMarkerEndsAtAHeadingOrRule() throws {
        let md = """
            # Plan
            - Main
            <!-- floating topics -->
            - [ ] Loose @Ana
              - Child
            ---
            # Second
            - Point
            """
        let im = try reimport(md, "f.md")
        let c = try #require(im.canvases.first)
        #expect(c.floating.map { c.nodes[$0]!.text } == ["Loose"])
        #expect(node(c, "Loose").todo?.owner == "Ana" && node(c, "Loose").children.count == 1)
        #expect(summary(c) == ["f", ".Plan", "..Main", ".Second", "..Point"], "\(summary(c))")
    }

    // MARK: OPML

    @Test func opmlRoundTripsTasksAndComments() throws {
        let c = plan()
        let opml = OPMLFormat.export(c)
        #expect(opml.contains("<opml version=\"2.0\" xmlns:nexus=\"https://opennexus.app/ns/opml\">"))
        #expect(
            opml.contains(
                "nexus:start=\"2026-11-02\" nexus:due=\"2026-11-06\" nexus:owner=\"Ana\" nexus:progress=\"40\""))
        #expect(opml.contains("nexus:after=\"\(id(c, "Beta · Nov").rawValue)(SS+2)\""))
        #expect(try XMLDocument(data: Data(opml.utf8)).rootElement() != nil)
        let im = try reimport(opml, "plan.opml")
        let back = try #require(im.canvases.first)
        #expect(summary(back) == summary(c))
        #expect(im.report.tasks == 4 && im.report.dependencies == 2 && im.report.comments == 4)
        // No namespace without tasks or comments.
        #expect(!OPMLFormat.export(Canvas(id: "c1", title: "A", rootText: "A")).contains("xmlns:nexus"))
    }

    @Test func opmlReadsAnyPrefixAndSkipsBadValues() throws {
        let opml = """
            <?xml version="1.0"?>
            <opml version="2.0" xmlns:on="https://opennexus.app/ns/opml"><head><title>T</title></head><body>
            <outline text="Root">
              <outline text="A" _status="unchecked" on:id="a" on:due="2026-11-06" on:priority="3"/>
              <outline text="B" _status="checked" on:after="a(SS)" on:comments="[{&quot;author&quot;:&quot;Ana&quot;,&quot;text&quot;:&quot;Hi&quot;}]"/>
              <outline text="C" on:after="(" on:comments="nope"/>
            </outline></body></opml>
            """
        let im = try reimport(opml, "x.opml")
        let c = try #require(im.canvases.first)
        #expect(node(c, "A").todo?.due == TaskDate("2026-11-06") && node(c, "A").priority == 3)
        #expect(node(c, "B").todo?.after == [TaskDependency(task: id(c, "A"), type: .startToStart)])
        #expect(node(c, "B").todo?.done == true)
        #expect(node(c, "B").comments == [TopicComment(author: "Ana", date: "", text: "Hi")])
        #expect(im.report.skipped.map(\.0).contains("Unreadable comments"))
        #expect(im.report.skipped.map(\.0).contains("Unreadable task dependencies"))
    }

    // MARK: MindManager

    func mmap(_ topics: String, relationships: String = "") -> Data {
        var z = ZipWriter()
        z.add(
            "Document.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <ap:Map xmlns:ap="http://schemas.mindjet.com/MindManager/Application/2003">
            <ap:OneTopic><ap:Topic OId="root"><ap:Text PlainText="Release"/>
            <ap:SubTopics>\(topics)</ap:SubTopics></ap:Topic></ap:OneTopic>
            <ap:Relationships>\(relationships)</ap:Relationships>
            </ap:Map>
            """)
        return z.finish()
    }

    @Test func mindManagerTaskInfo() throws {
        let data = mmap(
            """
            <ap:Topic OId="a"><ap:Text PlainText="Design"/>
              <ap:Task TaskPercentage="40" TaskPriority="urn:mindjet:Prio2" StartDate="2026-11-02T08:00:00"
                DueDate="2026-11-06T17:00:00" Resources="Ana; Lee" Effort="12"/></ap:Topic>
            <ap:Topic OId="b"><ap:Text PlainText="Code"/>
              <ap:Task StartDate="2026-11-09T00:00:00Z" Duration="2" DurationUnit="week">
                <ap:Dependency OIdRef="a" Type="urn:mindjet:StartToStart" Lag="1"/></ap:Task></ap:Topic>
            <ap:Topic OId="c"><ap:Text PlainText="Ship"/>
              <ap:Task DueDate="2026-12-04" Duration="16" DurationUnit="hour"/></ap:Topic>
            <ap:Topic OId="d"><ap:Text PlainText="Done already"/><ap:Task TaskPercentage="100"/></ap:Topic>
            """,
            relationships: """
                <ap:Relationship><ap:ConnectionGroup Index="0"><ap:Connection><ap:ObjectReference OIdRef="b"/></ap:Connection></ap:ConnectionGroup>
                <ap:ConnectionGroup Index="1"><ap:Connection><ap:ObjectReference OIdRef="c"/></ap:Connection></ap:ConnectionGroup>
                <ap:Dependency Type="FinishToStart"/></ap:Relationship>
                <ap:Relationship><ap:ConnectionGroup Index="0"><ap:Connection><ap:ObjectReference OIdRef="a"/></ap:Connection></ap:ConnectionGroup>
                <ap:ConnectionGroup Index="1"><ap:Connection><ap:ObjectReference OIdRef="d"/></ap:Connection></ap:ConnectionGroup></ap:Relationship>
                """)
        var report = ImportReport(source: "plan.mmap", format: "MindManager")
        let ic = try MindManagerFormat.parse(
            data, name: "plan.mmap", timeZone: TimeZone(identifier: "UTC")!, report: &report)
        let c = CanvasBuilder.build(ic, id: "c1", report: &report)
        let design = node(c, "Design")
        #expect(design.todo?.progress == 40 && design.todo?.done == false && design.priority == 2)
        #expect(design.todo?.start == TaskDate("2026-11-02") && design.todo?.due == TaskDate("2026-11-06"))
        #expect(design.todo?.owner == "Ana, Lee")
        let code = node(c, "Code").todo
        #expect(
            code?.start == TaskDate("2026-11-09") && code?.due == TaskDate("2026-11-20"), "two weeks of working days")
        #expect(code?.after == [TaskDependency(task: id(c, "Design"), type: .startToStart, lag: 1)])
        let ship = node(c, "Ship").todo
        #expect(ship?.start == TaskDate("2026-12-03") && ship?.due == TaskDate("2026-12-04"), "16 hours is two days")
        #expect(ship?.after == [TaskDependency(task: id(c, "Code"))], "a dependency relationship")
        #expect(node(c, "Done already").todo == Todo(done: true), "only a percentage stays a plain to-do")
        #expect(c.relationships.count == 1, "the ordinary relationship stays one")
        #expect(report.tasks == 3 && report.dependencies == 2)
        #expect(report.skipped.contains { $0.0 == "Task field “Effort”" })
        #expect(c.validate().isEmpty)
    }

    // MARK: Excel

    @Test func excelTaskAndCommentColumns() throws {
        let c = plan()
        let rows = ExcelFormat.rows(c)
        #expect(rows[0] == ExcelFormat.columns + ExcelFormat.taskColumns + ExcelFormat.commentColumns)
        func row(_ text: String) -> [String] { rows.first { $0[2] == text }! }
        #expect(Array(row("Beta · Nov")[7...]) == ["Ana", "2026-11-02", "2026-11-06", "40%", "", ""])
        #expect(Array(row("Pro")[7...11]) == ["", "2026-11-09", "", "0%", "Beta · Nov (SS +2)"])
        #expect(row("GA · Jan")[11] == "Beta · Nov")
        #expect(row("Positioning")[7...11].allSatisfy { $0.isEmpty }, "topics that aren't tasks leave them empty")
        #expect(
            rows.first { $0[2] == "Pricing" && !$0[3].isEmpty }![12]
                == "Ana · 2026-10-20: Drop the annual tier?\nOr discount it.\nAgreed")
        #expect(row("Free tier")[12] == "Lee: OK")
        // The workbook wraps the comments and keeps the old columns' widths.
        let sheet = String(
            decoding: try Zip.read(ExcelFormat.export(DocumentModel(canvases: [c])))["xl/worksheets/sheet1.xml"]!,
            as: UTF8.self)
        #expect(sheet.contains("<col min=\"13\" max=\"13\" width=\"48\""))
        #expect(sheet.contains("<c r=\"M"), "the comments column is written")
        // Canvases without tasks or comments keep the old columns.
        #expect(ExcelFormat.rows(launchPlan())[0] == ExcelFormat.columns)
    }
}
