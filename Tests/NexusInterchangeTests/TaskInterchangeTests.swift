import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// M11: Xmind task info imports as tasks; tasks export as CSV and ICS.
@Suite struct TaskInterchangeTests {
    let utc = TimeZone(identifier: "UTC")!
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    /// 2026-11-02T00:00 in Tokyo is 2026-11-01T15:00Z.
    static let tokyoMonday = 1_793_545_200_000.0

    func zen(_ topics: String) -> Data {
        var z = ZipWriter()
        z.add(
            "content.json",
            """
            [{"id": "s1", "title": "Plan", "rootTopic": {"id": "root", "title": "Release",
              "children": {"attached": [\(topics)]}}}]
            """)
        z.add("manifest.json", #"{"file-entries": {"content.json": {}}}"#)
        return z.finish()
    }

    func node(_ c: Canvas, _ text: String) -> Node { c.nodes.values.first { $0.text == text }! }
    func id(_ c: Canvas, _ text: String) -> NodeID { c.nodes.first { $0.value.text == text }!.key }

    @Test func zenTaskFieldsBecomeTasks() throws {
        let data = zen(
            """
            {"id": "a", "title": "Design", "extensions": [{"provider": "org.xmind.ui.task", "content":
              {"status": "done", "start": \(Self.tokyoMonday), "due": \(Self.tokyoMonday + 4 * 86_400_000),
               "assignee": "Ana", "priority": 2, "creator": "someone"}}]},
            {"id": "b", "title": "Code", "extensions": [{"provider": "org.xmind.ui.task", "content":
              {"progress": 0.4, "startDate": "2026-11-09T00:00:00+09:00", "dueDate": "2026-11-20",
               "assignees": [{"name": "Sam"}, {"name": "Lee"}],
               "dependencies": [{"id": "a", "type": "FS", "lag": 86400000}], "effort": 3}}]},
            {"id": "c", "title": "Docs", "extensions": [{"provider": "org.xmind.ui.task", "content":
              {"start": "1794787200000", "duration": 259200000, "assignees": ["Kim"],
               "dependencies": [{"id": "b", "type": "ss"}, {"id": "missing"}]}}]},
            {"id": "d", "title": "Launch", "extensions": [{"provider": "org.xmind.ui.task", "content":
              {"due": \(Self.tokyoMonday + 21 * 86_400_000), "dependencies": [{"id": "c", "type": "FF", "lag": 2}]}}]}
            """)
        let im = try XmindFormat.parse(data, name: "plan.xmind", timeZone: tokyo)
        let c = try #require(im.canvases.first)
        #expect(c.validate().isEmpty)
        let design = node(c, "Design").todo
        #expect(design?.done == true)
        #expect(design?.start == TaskDate("2026-11-02"), "epoch milliseconds become a day in the given zone")
        #expect(design?.due == TaskDate("2026-11-06"))
        #expect(design?.owner == "Ana")
        #expect(node(c, "Design").priority == 2)
        let code = node(c, "Code").todo
        #expect(code?.progress == 40)
        #expect(code?.start == TaskDate("2026-11-09"))
        #expect(code?.owner == "Sam, Lee")
        #expect(code?.after == [TaskDependency(task: id(c, "Design"), lag: 1)], "a lag in milliseconds is days")
        let docs = node(c, "Docs").todo
        #expect(docs?.start == TaskDate("2026-11-16"), "an epoch as a string")
        #expect(docs?.due == TaskDate("2026-11-18"), "duration fills in the due date")
        #expect(docs?.after == [TaskDependency(task: id(c, "Code"), type: .startToStart)])
        let launch = node(c, "Launch").todo
        #expect(launch?.start == nil && launch?.due == TaskDate("2026-11-23"))
        #expect(launch?.after == [TaskDependency(task: id(c, "Docs"), type: .finishToFinish, lag: 2)])
        #expect(im.report.tasks == 4 && im.report.dependencies == 3)
        let skipped = Dictionary(uniqueKeysWithValues: im.report.skipped.map { ($0.0, $0.1) })
        #expect(skipped["Task creator"] == 1)
        #expect(skipped["Task field “effort”"] == 1)
        #expect(skipped["Task dependency on a missing topic"] == 1)
        #expect(!im.report.text.contains("not in v1"))
        #expect(im.report.text.contains("4 tasks, 3 dependencies"))
    }

    @Test func loopsFromAFileAreBroken() throws {
        let data = zen(
            """
            {"id": "a", "title": "A", "extensions": [{"provider": "org.xmind.ui.task",
              "content": {"dependencies": [{"id": "b"}]}}]},
            {"id": "b", "title": "B", "extensions": [{"provider": "org.xmind.ui.task",
              "content": {"dependencies": [{"id": "a"}]}}]}
            """)
        let im = try XmindFormat.parse(data, name: "loop.xmind", timeZone: utc)
        let c = try #require(im.canvases.first)
        #expect(TaskSchedule(c).cycle.isEmpty)
        #expect(im.report.dependencies == 1)
        #expect(im.report.skipped.contains { $0.0 == "Task dependency that would make a loop" })
    }

    @Test func xmind8TaskInfo() throws {
        var z = ZipWriter()
        z.add(
            "content.xml",
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" version="2.0">
              <sheet id="s1"><title>Plan</title>
                <topic id="root"><title>Release</title>
                  <children><topics type="attached">
                    <topic id="a"><title>Design</title>
                      <extensions><extension provider="org.xmind.ui.taskInfo"><content>
                        <assigned-to>Ana</assigned-to><start-date>2026-11-02</start-date>
                        <end-date>2026-11-06</end-date><progress>0.5</progress>
                      </content></extension></extensions>
                    </topic>
                    <topic id="b"><title>Code</title>
                      <extensions><extension provider="org.xmind.ui.taskInfo"><content>
                        <start-date>2026-11-09</start-date><end-date>2026-11-13</end-date>
                        <dependencies><dependency id="a" type="FS" lag="1"/></dependencies>
                      </content></extension></extensions>
                    </topic>
                  </topics></children>
                </topic>
              </sheet>
            </xmap-content>
            """)
        let im = try XmindFormat.parse(z.finish(), name: "plan8.xmind", timeZone: utc)
        let c = try #require(im.canvases.first)
        #expect(node(c, "Design").todo?.owner == "Ana")
        #expect(node(c, "Design").todo?.progress == 50)
        #expect(node(c, "Design").todo?.due == TaskDate("2026-11-06"))
        #expect(node(c, "Code").todo?.after == [TaskDependency(task: id(c, "Design"), lag: 1)])
        #expect(im.report.tasks == 2)
    }

    // MARK: Export

    func plan() -> Canvas {
        var c = Canvas(id: "c1", title: "Release, 2.0", rootText: "Release")
        var u = UndoStack()
        c.edit("Plan", undo: &u) { e in
            let build = try! e.addChild(of: e.canvas.root, text: "Build")
            let design = try! e.addChild(of: build, text: "Design; UX")
            let code = try! e.addChild(of: build, text: "Code")
            let launch = try! e.addChild(of: e.canvas.root, text: "Launch")
            _ = try! e.addChild(of: e.canvas.root, text: "Ideas")
            e.updateTask(design) {
                $0.start = TaskDate("2026-11-02")
                $0.due = TaskDate("2026-11-06")
                $0.owner = "Ana"
                $0.done = true
            }
            e.updateTask(code) {
                $0.start = TaskDate("2026-11-09")
                $0.due = TaskDate("2026-11-20")
                $0.owner = "Sam, Lee"
                $0.progress = 40
            }
            e.update(code) {
                $0.labels = ["backend", "v2"]
                $0.note = Note(
                    text:
                        "Ship behind the flag.\nThen remove it, with a long explanation that runs past seventy-five octets so the line folds."
                )
                $0.priority = 1
            }
            e.updateTask(launch) { $0.due = TaskDate("2026-11-24") }
            try! e.addDependency(code, on: design)
            try! e.addDependency(launch, on: code, lag: 1)
        }
        return c
    }

    @Test func csvHasTaskColumns() {
        let c = plan()
        golden("export/tasks.csv", CSVFormat.export(c))
        let only = CSVFormat.export(c, tasksOnly: true)
        #expect(!only.contains("Ideas") && !only.contains("\nBuild,"))
        #expect(only.contains("Launch,Release,open,,,,2026-11-24,0,0%,Code (FS +1),,"))
    }

    @Test func icsFollowsRFC5545() throws {
        let c = plan()
        let ics = ICSFormat.export(c, now: Date(timeIntervalSince1970: 1_792_000_000))
        golden("export/tasks.ics", ics)
        #expect(ics.hasSuffix("END:VCALENDAR\r\n"))
        let lines = ics.components(separatedBy: "\r\n").dropLast()
        #expect(!ics.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line ends in CRLF")
        for l in lines { #expect(l.utf8.count <= 75, "folded: \(l)") }
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        #expect(unfolded.contains("SUMMARY:✓ Design\\; UX"))
        #expect(unfolded.contains("DTSTART;VALUE=DATE:20261109\r\nDTEND;VALUE=DATE:20261121"), "DTEND is exclusive")
        #expect(unfolded.contains("SUMMARY:◆ Launch"))
        #expect(unfolded.contains("CATEGORIES:backend,v2"))
        #expect(unfolded.contains("X-WR-CALNAME:Release\\, 2.0"))
        #expect(unfolded.components(separatedBy: "BEGIN:VEVENT").count == 4, "three dated tasks; Build is a summary")
        // UIDs stay put across exports.
        let again = ICSFormat.export(c, now: Date())
        let uids = { (s: String) in s.components(separatedBy: "\r\n").filter { $0.hasPrefix("UID:") } }
        #expect(uids(ics) == uids(again))
    }
}
