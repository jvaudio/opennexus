import AVFoundation
import AppKit
import NexusCore
import NexusFormat
import NexusTheme

/// Renders a canvas's slides offscreen and writes PDF, PowerPoint (.pptx; Keynote opens
/// the same file) or H.264 video (D74).
@MainActor
public enum SlideExporter {
    public static let size = CGSize(width: 1920, height: 1080)

    /// One image per playing slide (skipped slides are left out), with kicker and title,
    /// the task line, the corner legend and Timeline charts (M21). `prefs` and `today`
    /// default to the app's.
    public static func renderSlides(
        _ model: DocumentModel, canvas id: CanvasID, size: CGSize = size, prefs: Preferences? = nil,
        today: TaskDate? = nil
    ) -> [CGImage] {
        let store = DocumentStore(model: model)
        let controller = CanvasController(store: store)
        if let prefs { controller.prefs = prefs }
        controller.today = today
        controller.rendersThemeAsNamed = true
        controller.switchCanvas(to: id)
        let view = CanvasView(controller: controller)
        view.reduceMotionOverride = true
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        let slides = controller.slides
        var out: [CGImage] = []
        controller.startPresent()
        for (i, s) in slides.enumerated() where !s.skipped {
            controller.present?.index = i
            controller.present?.stageOnly = true
            controller.showSlide()
            view.layoutSubtreeIfNeeded()
            if let img = render(view, controller, size: size, slide: s) {
                out.append(img)
            }
        }
        controller.endPresent()
        window.contentView = nil
        return out
    }

    static func render(_ view: CanvasView, _ controller: CanvasController, size: CGSize, slide: Slide) -> CGImage? {
        let theme = controller.scene.theme
        let canvas = controller.scene.canvasColor
        let w = Int(size.width)
        let h = Int(size.height)
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return nil }
        ctx.setFillColor(canvas.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        let root = view.sceneLayer
        root.isGeometryFlipped = true
        root.layoutIfNeeded()
        func redraw(_ l: CALayer) {
            if l is TextLayer || l is DecorLayer {
                l.setNeedsDisplay()
                l.displayIfNeeded()
            }
            l.sublayers?.forEach(redraw)
        }
        redraw(root)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        root.render(in: ctx)
        // Kicker and title, as on screen (artboard 32).
        let ink = NSColor(cgColor: theme.ink.cgColor) ?? .labelColor
        NSAttributedString(
            string: slide.kicker,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .medium),
                .foregroundColor: ink.withAlphaComponent(0.6),
                .kern: 2.4,
            ]
        ).draw(at: CGPoint(x: 84, y: 56))
        let title = NSAttributedString(
            string: controller.slideTitle(slide),
            attributes: [.font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: ink])
        let titleBox = CGRect(x: 84, y: 92, width: size.width - 168, height: 160)
        title.draw(with: titleBox, options: [.usesLineFragmentOrigin])
        let titleHeight = min(
            ceil(title.boundingRect(with: titleBox.size, options: [.usesLineFragmentOrigin]).height), titleBox.height)
        drawExtras(controller, slide: slide, size: size, titleBottom: titleBox.minY + titleHeight)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return ctx.makeImage()
    }

    // MARK: PDF

    public static func pdf(_ images: [CGImage]) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let ctx = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return Data() }
        for img in images {
            ctx.beginPDFPage(nil)
            ctx.draw(img, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    // MARK: PowerPoint (.pptx)

    static func png(_ img: CGImage) -> Data {
        NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) ?? Data()
    }

    /// A minimal Office Open XML deck: one full-bleed picture per slide, notes as alt text.
    public static func pptx(_ images: [CGImage], titles: [String]) -> Data {
        let cx = 12_192_000
        let cy = 6_858_000
        var z = ZipWriter()
        let n = images.count
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let ns =
            #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        var types =
            xml
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
        for i in 1...max(n, 1) where n > 0 {
            types +=
                #"<Override PartName="/ppt/slides/slide\#(i).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
        }
        types += "</Types>"
        z.add("[Content_Types].xml", types)
        z.add(
            "_rels/.rels",
            xml
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#
        )
        var sldIds = ""
        var presRels =
            #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>"#
        for i in 0..<n {
            sldIds += #"<p:sldId id="\#(256 + i)" r:id="rId\#(i + 10)"/>"#
            presRels +=
                #"<Relationship Id="rId\#(i + 10)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(i + 1).xml"/>"#
        }
        z.add(
            "ppt/presentation.xml",
            xml
                + #"<p:presentation \#(ns)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\#(sldIds)</p:sldIdLst><p:sldSz cx="\#(cx)" cy="\#(cy)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
        )
        z.add(
            "ppt/_rels/presentation.xml.rels",
            xml
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\#(presRels)</Relationships>"#
        )
        let emptyTree =
            #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
        z.add(
            "ppt/slideMasters/slideMaster1.xml",
            xml
                + #"<p:sldMaster \#(ns)>\#(emptyTree)<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>"#
        )
        z.add(
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            xml
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>"#
        )
        z.add(
            "ppt/slideLayouts/slideLayout1.xml",
            xml + #"<p:sldLayout \#(ns) type="blank">\#(emptyTree)</p:sldLayout>"#)
        z.add(
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            xml
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>"#
        )
        z.add("ppt/theme/theme1.xml", xml + themeXML)
        for (i, img) in images.enumerated() {
            let k = i + 1
            z.add("ppt/media/image\(k).png", png(img))
            let title = i < titles.count ? esc(titles[i]) : ""
            z.add(
                "ppt/slides/slide\(k).xml",
                xml
                    + #"<p:sld \#(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:pic><p:nvPicPr><p:cNvPr id="2" name="Slide \#(k)" descr="\#(title)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld></p:sld>"#
            )
            z.add(
                "ppt/slides/_rels/slide\(k).xml.rels",
                xml
                    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image\#(k).png"/></Relationships>"#
            )
        }
        return z.finish()
    }

    static let themeXML =
        #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="OpenNexus"><a:themeElements><a:clrScheme name="OpenNexus"><a:dk1><a:srgbClr val="17171C"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="2B2B33"/></a:dk2><a:lt2><a:srgbClr val="F5F5F2"/></a:lt2><a:accent1><a:srgbClr val="5850EC"/></a:accent1><a:accent2><a:srgbClr val="E5484D"/></a:accent2><a:accent3><a:srgbClr val="12A594"/></a:accent3><a:accent4><a:srgbClr val="E0A100"/></a:accent4><a:accent5><a:srgbClr val="7A4CC2"/></a:accent5><a:accent6><a:srgbClr val="1E6FB8"/></a:accent6><a:hlink><a:srgbClr val="5850EC"/></a:hlink><a:folHlink><a:srgbClr val="7A4CC2"/></a:folHlink></a:clrScheme><a:fontScheme name="OpenNexus"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="OpenNexus"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"#

    // MARK: Video (.mp4, H.264)

    /// 1920 × 1080 at 30 fps: each slide holds 3 s, with 0.6 s cross-fades.
    public static func video(_ images: [CGImage], to url: URL, hold: Double = 3, fade: Double = 0.6) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let fps = 30
        var frame = 0
        func append(_ draw: (CGContext) -> Void) async {
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { return }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            {
                draw(ctx)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            frame += 1
        }
        let box = CGRect(origin: .zero, size: size)
        for (i, img) in images.enumerated() {
            for _ in 0..<Int(hold * Double(fps)) { await append { $0.draw(img, in: box) } }
            if i + 1 < images.count {
                let n = Int(fade * Double(fps))
                for f in 0..<n {
                    let t = CGFloat(f + 1) / CGFloat(n + 1)
                    await append { ctx in
                        ctx.draw(img, in: box)
                        ctx.setAlpha(t)
                        ctx.draw(images[i + 1], in: box)
                    }
                }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed, let e = writer.error { throw e }
    }
}
