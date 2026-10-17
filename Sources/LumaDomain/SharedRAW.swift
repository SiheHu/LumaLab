import Foundation
import CLumaRaw

package struct LinearRAW {
    package var width:Int
    package var height:Int
    package var rgb16:Data
    package var make:String
    package var model:String
    package var iso:Double
    package var shutter:Double
    package var aperture:Double
    package var focal:Double
}
package enum SharedRAWDecoder {
    package static var version:String {String(cString:luma_raw_version())}
    package struct Failure:LocalizedError {package var errorDescription:String?}
    /// Full demosaic to linear sRGB16 with camera WB and no automatic brightness.
    package static func decode(_ data:Data) throws -> LinearRAW {
        var raw=LumaRawImage();var error=[CChar](repeating:0,count:256)
        let status=data.withUnsafeBytes {luma_raw_decode($0.baseAddress,data.count,&raw,&error,error.count)}
        defer {luma_raw_free(&raw)}
        guard status==0,let pixels=raw.rgb,raw.width>0,raw.height>0 else {throw Failure(errorDescription:String(cString:error))}
        let make=withUnsafePointer(to:raw.make) {$0.withMemoryRebound(to:CChar.self,capacity:64){String(cString:$0)}}
        let model=withUnsafePointer(to:raw.model) {$0.withMemoryRebound(to:CChar.self,capacity:64){String(cString:$0)}}
        return LinearRAW(width:Int(raw.width),height:Int(raw.height),rgb16:Data(bytes:pixels,count:Int(raw.count)*2),make:make,model:model,iso:Double(raw.iso),shutter:Double(raw.shutter),aperture:Double(raw.aperture),focal:Double(raw.focal))
    }
}
