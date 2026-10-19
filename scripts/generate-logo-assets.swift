import AppKit
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let root = project.appendingPathComponent("linger/Assets.xcassets")
let source = NSBitmapImageRep(data: try Data(contentsOf: project.appendingPathComponent("Design/resting-eye-master.png")))!
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh { for x in 0..<source.pixelsWide {
    if source.colorAt(x: x, y: y)!.alphaComponent > 0.05 { minX = min(minX,x); minY = min(minY,y); maxX = max(maxX,x); maxY = max(maxY,y) }
}}
let cropped = source.cgImage!.cropping(to: CGRect(x:minX,y:minY,width:maxX-minX+1,height:maxY-minY+1))!
let mark = NSImage(cgImage: cropped, size: NSSize(width: cropped.width,height: cropped.height))
func render(_ width:Int,_ height:Int,tile:Bool=false) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    if tile {
        NSColor(calibratedRed:0.98,green:0.97,blue:0.94,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:Double(width)*0.05,y:Double(height)*0.05,width:Double(width)*0.9,height:Double(height)*0.9),xRadius:Double(width)*0.2,yRadius:Double(height)*0.2).fill()
    }
    let w = Double(width) * (tile ? 0.64 : 1)
    let h = w * Double(cropped.height)/Double(cropped.width)
    mark.draw(in:NSRect(x:(Double(width)-w)/2,y:(Double(height)-h)/2,width:w,height:h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using:.png,properties:[:])!
}
func json(_ value:Any,_ url:URL) throws { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:url) }
let info:[String:Any] = ["author":"xcode","version":1]
let logo = root.appendingPathComponent("LingerMark.imageset")
try FileManager.default.createDirectory(at:logo,withIntermediateDirectories:true)
var images = [[String:String]]()
for scale in 1...3 { let name = "mark-\(scale)x.png"; try render(256*scale,120*scale).write(to:logo.appendingPathComponent(name)); images.append(["idiom":"universal","scale":"\(scale)x","filename":name]) }
try json(["images":images,"info":info,"properties":["template-rendering-intent":"template"]],logo.appendingPathComponent("Contents.json"))
images=[]
for size in [16,32,128,256,512] { for scale in 1...2 {
    let name = "icon-\(size)-\(scale)x.png"
    try render(size*scale,size*scale,tile:true).write(to:root.appendingPathComponent("AppIcon.appiconset/\(name)"))
    images.append(["idiom":"mac","size":"\(size)x\(size)","scale":"\(scale)x","filename":name])
}}
try json(["images":images,"info":info],root.appendingPathComponent("AppIcon.appiconset/Contents.json"))
print("Master \(source.pixelsWide)x\(source.pixelsHigh); mark bounds \(cropped.width)x\(cropped.height); exported all assets")
