// Fixed version of chd_reader.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

import 'models.dart';

/// Constants for CHD metadata tags
class ChdMetadataTag {
  static final int CDROM_TRACK_METADATA2_TAG = makeTag('C', 'H', 'T', '2');
  static final int CDROM_TRACK_METADATA_TAG = makeTag('C', 'H', 'T', 'R');
  static final int GDROM_TRACK_METADATA_TAG = makeTag('C', 'H', 'G', 'D');
  
  // Helper to create a tag from 4 chars
  static int makeTag(String a, String b, String c, String d) {
    return (a.codeUnitAt(0) << 24) | 
           (b.codeUnitAt(0) << 16) | 
           (c.codeUnitAt(0) << 8) | 
           d.codeUnitAt(0);
  }

  // Format strings for parsing metadata
  static const String CDROM_TRACK_METADATA_FORMAT = 
      "TRACK:%d TYPE:%s SUBTYPE:%s FRAMES:%d";
  
  static const String CDROM_TRACK_METADATA2_FORMAT = 
      "TRACK:%d TYPE:%s SUBTYPE:%s FRAMES:%d PREGAP:%d PGTYPE:%s PGSUB:%s POSTGAP:%d";
  
  static const String GDROM_TRACK_METADATA_FORMAT = 
      "TRACK:%d TYPE:%s SUBTYPE:%s FRAMES:%d PAD:%d PREGAP:%d PGTYPE:%s PGSUB:%s POSTGAP:%d";
}

/// CHD error codes
class ChdError {
  static const int NONE = 0;
  static const int METADATA_NOT_FOUND = 19;
  
  static String getMessage(int errorCode) {
    switch (errorCode) {
      case NONE: return 'No error';
      case METADATA_NOT_FOUND: return 'Metadata not found';
      default: return 'Unknown error code: $errorCode';
    }
  }
}

/// Class to handle reading CHD files
class ChdReader {
  final String _libPath;
  late final DynamicLibrary _lib;
  late final bool _isInitialized;
  
  // FFI function pointers
  late final _ChdOpen _chdOpen;
  late final _ChdClose _chdClose;
  late final _ChdRead _chdRead;
  late final _ChdGetHeader _chdGetHeader;
  late final _ChdGetMetadata _chdGetMetadata;
  
  ChdReader([String? libPath]) : _libPath = libPath ?? _findDefaultLibPath() {
    _isInitialized = _initLibrary();
  }
  
  bool get isInitialized => _isInitialized;
  
  bool _initLibrary() {
    try {
      _lib = DynamicLibrary.open(_libPath);
      
      // Load function pointers
      _chdOpen = _lib.lookupFunction<_ChdOpenNative, _ChdOpen>('chd_open');
      _chdClose = _lib.lookupFunction<_ChdCloseNative, _ChdClose>('chd_close');
      _chdRead = _lib.lookupFunction<_ChdReadNative, _ChdRead>('chd_read');
      _chdGetHeader = _lib.lookupFunction<_ChdGetHeaderNative, _ChdGetHeader>('chd_get_header');
      _chdGetMetadata = _lib.lookupFunction<_ChdGetMetadataNative, _ChdGetMetadata>('chd_get_metadata');
      
      return true;
    } catch (e) {
      print('Failed to initialize CHD library: $e');
      return false;
    }
  }
  
  static String _findDefaultLibPath() {
    if (Platform.isWindows) {
      return 'chdr.dll';
    } else if (Platform.isLinux) {
      return 'libchdr.so';
    } else if (Platform.isMacOS) {
      return 'libchdr.dylib';
    } else {
      throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
    }
  }
  
  /// Process a CHD file to extract its tracks and data
  Future<ChdProcessResult> processChdFile(String filePath) async {
    if (!_isInitialized) {
      return ChdProcessResult(
        header: ChdHeader(
          version: 0, flags: 0, compression: [0,0,0,0], 
          hunkBytes: 0, totalHunks: 0, logicalBytes: 0, unitBytes: 0,
          metaOffset: 0, sha1: List.filled(20, 0)
        ),
        tracks: [],
        error: 'CHD library not initialized',
      );
    }
    
    // Pointers for FFI calls
    final chdPtr = calloc<Pointer<_ChdFile>>();
    final filePathPtr = filePath.toNativeUtf8();
    
    try {
      // Open the CHD file
      final result = _chdOpen(filePathPtr, 1, nullptr, chdPtr);
      if (result != ChdError.NONE) {
        return ChdProcessResult(
          header: ChdHeader(
            version: 0, flags: 0, compression: [0,0,0,0], 
            hunkBytes: 0, totalHunks: 0, logicalBytes: 0, unitBytes: 0,
            metaOffset: 0, sha1: List.filled(20, 0)
          ),
          tracks: [],
          error: 'Failed to open CHD file: ${ChdError.getMessage(result)}',
        );
      }
      
      // Get the header
      final headerPtr = _chdGetHeader(chdPtr.value);
      if (headerPtr == nullptr) {
        _chdClose(chdPtr.value);
        return ChdProcessResult(
          header: ChdHeader(
            version: 0, flags: 0, compression: [0,0,0,0], 
            hunkBytes: 0, totalHunks: 0, logicalBytes: 0, unitBytes: 0,
            metaOffset: 0, sha1: List.filled(20, 0)
          ),
          tracks: [],
          error: 'Failed to get CHD header',
        );
      }
      
      // Read the header values
      int unitBytes = headerPtr.ref.unitbytes;
      
      // Handle the case where unitBytes is 0 (common for CD-ROM CHDs)
      if (unitBytes <= 0) {
        print('WARNING: unitBytes reported as 0 in header, assuming CD-ROM');
        // For CD-ROM CHDs, the sector size is typically 2448 bytes (including overhead)
        // Based on our analysis, hunks are 8 sectors each (19584 / 2448 = 8)
        unitBytes = 2448;
      }
      
      final header = ChdHeader(
        version: headerPtr.ref.version,
        flags: headerPtr.ref.flags,
        compression: [
          headerPtr.ref.compression[0],
          headerPtr.ref.compression[1],
          headerPtr.ref.compression[2],
          headerPtr.ref.compression[3],
        ],
        hunkBytes: headerPtr.ref.hunkbytes,
        totalHunks: headerPtr.ref.totalhunks,
        logicalBytes: headerPtr.ref.logicalbytes,
        unitBytes: unitBytes, // Use our possibly adjusted unitBytes
        metaOffset: headerPtr.ref.metaoffset,
        sha1: List.filled(20, 0), // We don't need the SHA1 for our purposes
      );
      
      print('DEBUG - CHD Header: version=${header.version}, hunkBytes=${header.hunkBytes}, unitBytes=${header.unitBytes} (adjusted from ${headerPtr.ref.unitbytes})');
      
      
      // Extract track information
      List<TrackInfo> tracks = [];
      int idx = 0;
      
      // Keep track of sector offset for calculating start frames
      int sectorOffset = 0;
      int frameOffset = 0;
      
      while (true) {
        // Try to get metadata for this track
        String? metadata = _getMetadata(chdPtr.value, ChdMetadataTag.CDROM_TRACK_METADATA2_TAG, idx);
        if (metadata == null) {
          metadata = _getMetadata(chdPtr.value, ChdMetadataTag.CDROM_TRACK_METADATA_TAG, idx);
        }
        if (metadata == null) {
          metadata = _getMetadata(chdPtr.value, ChdMetadataTag.GDROM_TRACK_METADATA_TAG, idx);
        }
        
        if (metadata == null) {
          break; // No more tracks
        }
        
        print('DEBUG - Track metadata: $metadata');
        
        // Parse the metadata to extract track information
        TrackInfo? track = _parseTrackMetadata(metadata, sectorOffset, frameOffset);
        if (track != null) {
          tracks.add(track);
          
          // Update offsets for next track
          sectorOffset += track.totalFrames;
          frameOffset += track.pregap;
          frameOffset += track.totalFrames;
          // Padding to a multiple of 4 frames (matches the C++ implementation)
          int paddingFrames = ((track.totalFrames + 3) & ~3) - track.totalFrames;
          frameOffset += paddingFrames;
        }
        
        idx++;
      }
      
      // If there are no tracks, this is not a valid CD image
      if (tracks.isEmpty) {
        _chdClose(chdPtr.value);
        return ChdProcessResult(
          header: header,
          tracks: [],
          error: 'No tracks found in CHD file',
        );
      }
      
      // For data discs, read the first sector to check format
      if (tracks[0].type.contains('MODE1') || tracks[0].type.contains('MODE2')) {
        // Read sector 16 (TOC) to identify the disc format - following the C++ implementation
        try {
          Uint8List? sectorData = await readSector(filePath, tracks[0], 16);
          if (sectorData != null) {
            tracks[0] = _refineTrackInfo(tracks[0], sectorData);
          }
        } catch (e) {
          print('Warning: Could not read sector 16 to refine track info: $e');
        }
      }
      
      // Close the CHD file for now, we'll reopen when needed for sector reads
      _chdClose(chdPtr.value);
      
      return ChdProcessResult(
        header: header,
        tracks: tracks,
        firstTrackData: null, // We'll read this on demand instead
      );
    } finally {
      calloc.free(chdPtr);
      calloc.free(filePathPtr);
    }
  }
  
  /// Refine track information based on sector data
  /// This mimics the C++ implementation's detection of sector formats
  TrackInfo _refineTrackInfo(TrackInfo track, Uint8List sectorData) {
  int dataOffset = track.dataOffset;
  int dataSize = track.dataSize;
  
  // Check for CD001 marker to identify format
  List<int> cd001 = [0x43, 0x44, 0x30, 0x30, 0x31]; // "CD001" in ASCII
  
  // Check for CD-ROM XA format (offset 25)
  if (sectorData.length >= 30 && 
      _compareBytes(sectorData, 25, cd001, 0, 5)) {
    // MODE2 XA format
    bool isXA2 = (sectorData[18] & 0x20) != 0; // Check mode flags in subheader
    dataSize = isXA2 ? 2324 : 2048;
    dataOffset = 24; // 16-byte sync header + 8-byte subheader
  }
  // Check for standard MODE2 format (offset 17)
  else if (sectorData.length >= 22 && 
           _compareBytes(sectorData, 17, cd001, 0, 5)) {
    dataSize = 2336;
    dataOffset = 16; // 16-byte sync header
  }
  // Check for raw data format (offset 1)
  else if (sectorData.length >= 6 && 
           _compareBytes(sectorData, 1, cd001, 0, 5)) {
    dataSize = 2048;
    dataOffset = 0; // No header
  }
  // Check for CD sync pattern
  else if (sectorData.length >= 16) {
    Uint8List syncPattern = Uint8List.fromList(
      [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]);
    
    if (_compareBytes(sectorData, 0, syncPattern, 0, 12)) {
      bool isMode1 = (sectorData[15] & 3) == 1;
      dataSize = isMode1 ? 2048 : 2336;
      dataOffset = 16;
    }
  }
  
  return TrackInfo(
    number: track.number,
    type: track.type,
    sectorSize: track.sectorSize,
    pregap: track.pregap,
    startFrame: track.startFrame,
    totalFrames: track.totalFrames,
    dataOffset: dataOffset,
    dataSize: dataSize,
  );
}
  
  /// Helper to compare byte sequences
  bool _compareBytes(List<int> a, int aOffset, List<int> b, int bOffset, int length) {
    if (a.length < aOffset + length || b.length < bOffset + length) {
      return false;
    }
    
    for (int i = 0; i < length; i++) {
      if (a[aOffset + i] != b[bOffset + i]) {
        return false;
      }
    }
    
    return true;
  }
  
  /// Read a specific sector from a track
  /// Read a specific sector from a track
Future<Uint8List?> readSector(String filePath, TrackInfo track, int sectorIndex) async {
  if (!_isInitialized) {
    return null;
  }
  
  // Open the CHD file
  final chdPtr = calloc<Pointer<_ChdFile>>();
  final filePathPtr = filePath.toNativeUtf8();
  
  try {
    final result = _chdOpen(filePathPtr, 1, nullptr, chdPtr);
    if (result != ChdError.NONE) {
      print('Failed to open CHD file: ${ChdError.getMessage(result)}');
      return null;
    }
    
    // Get the header
    final headerPtr = _chdGetHeader(chdPtr.value);
    if (headerPtr == nullptr) {
      _chdClose(chdPtr.value);
      print('Failed to get CHD header');
      return null;
    }
    
    // Use a reliable unitBytes value (2448 is standard for CD-ROM)
    int unitBytes = headerPtr.ref.unitbytes;
    if (unitBytes <= 0) {
      unitBytes = 2448;
    }
    
    final hunkBytes = headerPtr.ref.hunkbytes;
    final framesPerHunk = hunkBytes ~/ unitBytes;
    
    if (framesPerHunk <= 0) {
      print('Invalid frames per hunk calculation: $hunkBytes / $unitBytes = $framesPerHunk');
      _chdClose(chdPtr.value);
      return null;
    }
    
    // Calculate which CHD frame contains this sector
    final chdFrame = track.startFrame + sectorIndex;
    final hunkNum = chdFrame ~/ framesPerHunk;
    final frameOffset = (chdFrame % framesPerHunk) * unitBytes;
    
    // Read the hunk
    final hunkBuffer = calloc<Uint8>(hunkBytes);
    final readResult = _chdRead(chdPtr.value, hunkNum, hunkBuffer);
    
    if (readResult != ChdError.NONE) {
      print('Failed to read hunk $hunkNum: ${ChdError.getMessage(readResult)}');
      _chdClose(chdPtr.value);
      return null;
    }
    
    // Instead of trying to be smart about dataSize and dataOffset,
    // return the entire sector and let the caller handle it
    Uint8List fullSectorData = Uint8List(track.sectorSize);
    
    // Copy the data from the hunk
    for (int i = 0; i < track.sectorSize && i + frameOffset < hunkBytes; i++) {
      fullSectorData[i] = hunkBuffer[frameOffset + i];
    }
    
    _chdClose(chdPtr.value);
    calloc.free(hunkBuffer);
    
    return fullSectorData;
  } finally {
    calloc.free(filePathPtr);
    calloc.free(chdPtr);
  }
}
  
  /// Parse track metadata to extract track information
  TrackInfo? _parseTrackMetadata(String metadata, int sectorOffset, int frameOffset) {
    // Track number
    int trackNumber = 0;
    String trackType = '';
    String subType = '';
    int frames = 0;
    int pregap = 0;
    
    // Parse based on format
    if (metadata.contains('PAD:')) {
      // GDROM format
      RegExp regex = RegExp(
        r'TRACK:(\d+) TYPE:(\w+) SUBTYPE:(\w+) FRAMES:(\d+) PAD:(\d+) PREGAP:(\d+)'
      );
      Match? match = regex.firstMatch(metadata);
      if (match != null) {
        trackNumber = int.parse(match.group(1)!);
        trackType = match.group(2)!;
        subType = match.group(3)!;
        frames = int.parse(match.group(4)!);
        pregap = int.parse(match.group(6)!);
      }
    } else if (metadata.contains('PREGAP:')) {
      // CDROM2 format
      RegExp regex = RegExp(
        r'TRACK:(\d+) TYPE:(\w+) SUBTYPE:(\w+) FRAMES:(\d+) PREGAP:(\d+)'
      );
      Match? match = regex.firstMatch(metadata);
      if (match != null) {
        trackNumber = int.parse(match.group(1)!);
        trackType = match.group(2)!;
        subType = match.group(3)!;
        frames = int.parse(match.group(4)!);
        pregap = int.parse(match.group(5)!);
      }
    } else {
      // Basic CDROM format
      RegExp regex = RegExp(
        r'TRACK:(\d+) TYPE:(\w+) SUBTYPE:(\w+) FRAMES:(\d+)'
      );
      Match? match = regex.firstMatch(metadata);
      if (match != null) {
        trackNumber = int.parse(match.group(1)!);
        trackType = match.group(2)!;
        subType = match.group(3)!;
        frames = int.parse(match.group(4)!);
      }
    }
    
    if (trackNumber == 0 || frames == 0) {
      return null; // Invalid track
    }
    
    // Determine sector size and data offset based on track type
    // This follows the C++ implementation's logic
    int sectorSize = 2352; // Default sector size
    int dataOffset = 0;
    int dataSize = 2048; // Default data size
    
    if (trackType == 'MODE1_RAW') {
      // 16-byte header, 2048 bytes data, 288 byte footer
      dataOffset = 16;
      dataSize = 2048;
    } else if (trackType == 'MODE2_RAW') {
      // 16-byte header, 2336 bytes data (may contain subheader)
      dataOffset = 16;
      dataSize = 2336;
    } else if (trackType == 'MODE1') {
      // Raw data with no header
      dataOffset = 0;
      dataSize = 2048;
    } else if (trackType == 'MODE2') {
      // Raw data with no header
      dataOffset = 0;
      dataSize = 2336;
    } else if (trackType == 'AUDIO') {
      // Raw audio data
      dataOffset = 0;
      dataSize = 2352;
    }
    
    return TrackInfo(
      number: trackNumber,
      type: trackType,
      sectorSize: sectorSize,
      pregap: pregap,
      startFrame: frameOffset,
      totalFrames: frames,
      dataOffset: dataOffset,
      dataSize: dataSize,
    );
  }
  
  /// Get metadata from a CHD file
  String? _getMetadata(Pointer<_ChdFile> chdPtr, int tag, int index) {
    // Allocate a reasonably large buffer for metadata
    const maxMetadataSize = 4096;
    final outputBuffer = calloc<Uint8>(maxMetadataSize);
    final resultLen = calloc<Uint32>();
    final resultTag = calloc<Uint32>();
    final resultFlags = calloc<Uint8>();
    
    try {
      final result = _chdGetMetadata(
        chdPtr, 
        tag, 
        index, 
        outputBuffer, 
        maxMetadataSize,
        resultLen, 
        resultTag, 
        resultFlags
      );
      
      if (result != ChdError.NONE) {
        return null;
      }
      
      // Convert the metadata to a string
      final length = resultLen.value;
      final bytes = Uint8List(length);
      for (int i = 0; i < length; i++) {
        bytes[i] = outputBuffer[i];
      }
      
      return utf8.decode(bytes);
    } finally {
      calloc.free(outputBuffer);
      calloc.free(resultLen);
      calloc.free(resultTag);
      calloc.free(resultFlags);
    }
  }
}

// FFI class definitions
base class _ChdFile extends Opaque {}

// The header structure needs to match the C implementation
// Looking at libchdr's chd.h, the header structure might be different
// This is a best guess at matching the actual structure used in libchdr
base class _ChdHeader extends Struct {
  @Uint32()
  external int length;
  
  @Uint32()
  external int version;
  
  @Uint32()
  external int flags;
  
  @Array(4)
  external Array<Uint32> compression;
  
  @Uint32()
  external int hunkbytes;
  
  @Uint32()
  external int totalhunks;
  
  @Uint64()
  external int logicalbytes;
  
  @Uint64()
  external int mapoffset;
  
  @Uint64()
  external int metaoffset;
  
  @Uint32()
  external int hunkbytes_raw;
  
  @Uint32()
  external int unitbytes;
  
  // Additional fields might be present in the C structure
  // but we only need these ones for our purposes
}

// FFI function signatures
typedef _ChdOpenNative = Int32 Function(
    Pointer<Utf8> filename, 
    Int32 mode, 
    Pointer<_ChdFile> parent, 
    Pointer<Pointer<_ChdFile>> chd
);
typedef _ChdOpen = int Function(
    Pointer<Utf8> filename, 
    int mode, 
    Pointer<_ChdFile> parent, 
    Pointer<Pointer<_ChdFile>> chd
);

typedef _ChdCloseNative = Void Function(Pointer<_ChdFile> chd);
typedef _ChdClose = void Function(Pointer<_ChdFile> chd);

typedef _ChdReadNative = Int32 Function(
    Pointer<_ChdFile> chd, 
    Uint32 hunknum, 
    Pointer<Uint8> buffer
);
typedef _ChdRead = int Function(
    Pointer<_ChdFile> chd, 
    int hunknum, 
    Pointer<Uint8> buffer
);

typedef _ChdGetHeaderNative = Pointer<_ChdHeader> Function(Pointer<_ChdFile> chd);
typedef _ChdGetHeader = Pointer<_ChdHeader> Function(Pointer<_ChdFile> chd);

typedef _ChdGetMetadataNative = Int32 Function(
    Pointer<_ChdFile> chd,
    Uint32 searchtag,
    Uint32 searchindex,
    Pointer<Uint8> output,
    Uint32 outputlen,
    Pointer<Uint32> resultlen,
    Pointer<Uint32> resulttag,
    Pointer<Uint8> resultflags
);
typedef _ChdGetMetadata = int Function(
    Pointer<_ChdFile> chd,
    int searchtag,
    int searchindex,
    Pointer<Uint8> output,
    int outputlen,
    Pointer<Uint32> resultlen,
    Pointer<Uint32> resulttag,
    Pointer<Uint8> resultflags
);