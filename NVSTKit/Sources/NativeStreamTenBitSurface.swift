import CoreVideo

/// 10-bit surface helpers the NVST decoder relies on (`NvstVideoToolboxDecoder` checks
/// `preserves444`). Copied from OpenNOW iOS `NativeStreamHDRMetal.swift` (MIT) at upstream commit
/// 9ce50090f08b83e3695dba6e6f74d58688562383; the name is kept so the vendored decoder is unchanged.
enum NativeStreamTenBitSurface {
	static func chroma(_ format: OSType) -> String? {
		switch format {
		case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "4:2:0"
		case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: return "4:2:2"
		case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange: return "4:4:4"
		default: return nil
		}
	}

	static func isFullRange(_ format: OSType) -> Bool {
		[kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
		 kCVPixelFormatType_444YpCbCr10BiPlanarFullRange].contains(format)
	}

	static func preserves444(_ buffer: CVPixelBuffer) -> Bool {
		chroma(CVPixelBufferGetPixelFormatType(buffer)) == "4:4:4"
			&& CVPixelBufferGetPlaneCount(buffer) == 2
			&& CVPixelBufferGetWidthOfPlane(buffer, 0) == CVPixelBufferGetWidthOfPlane(buffer, 1)
			&& CVPixelBufferGetHeightOfPlane(buffer, 0) == CVPixelBufferGetHeightOfPlane(buffer, 1)
	}

	static func hasValidPlanes(_ buffer: CVPixelBuffer) -> Bool {
		guard let chroma = chroma(CVPixelBufferGetPixelFormatType(buffer)),
			  CVPixelBufferGetPlaneCount(buffer) == 2 else { return false }
		let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
		let horizontal = chroma == "4:4:4" ? 1 : 2
		let vertical = chroma == "4:2:0" ? 2 : 1
		return width > 0 && height > 0
			&& CVPixelBufferGetWidthOfPlane(buffer, 0) == width
			&& CVPixelBufferGetHeightOfPlane(buffer, 0) == height
			&& CVPixelBufferGetWidthOfPlane(buffer, 1) == (width + horizontal - 1) / horizontal
			&& CVPixelBufferGetHeightOfPlane(buffer, 1) == (height + vertical - 1) / vertical
	}
}
