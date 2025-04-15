// models.dart - Data models for CHD reader and PSX filesystem
import 'dart:typed_data';

/// Represents a track in a CHD file
class TrackInfo {
  final int number;        // Track number
  final String type;       // Track type (e.g., MODE1/2352, MODE2/2352, AUDIO)
  final int sectorSize;    // Size of each sector in bytes
  final int pregap;        // Pregap for this track (in frames)
  final int startFrame;    // Starting frame for this track
  final int totalFrames;   // Total frames in this track
  final int dataOffset;    // Offset to data within a sector
  final int dataSize;      // Size of data within a sector

  TrackInfo({
    required this.number,
    required this.type,
    required this.sectorSize,
    this.pregap = 0,
    required this.startFrame,
    required this.totalFrames,
    required this.dataOffset,
    required this.dataSize,
  });

  @override
  String toString() {
    return 'Track $number: $type, $totalFrames frames, starting at $startFrame, ' +
           'sector size $sectorSize, data offset $dataOffset, data size $dataSize';
  }
}

/// Represents a CHD file header
class ChdHeader {
  final int version;
  final int flags;
  final List<int> compression;
  final int hunkBytes;
  final int totalHunks;
  final int logicalBytes;
  final int unitBytes;
  final int metaOffset;
  final List<int> sha1;

  ChdHeader({
    required this.version,
    required this.flags,
    required this.compression,
    required this.hunkBytes,
    required this.totalHunks,
    required this.logicalBytes,
    required this.unitBytes,
    required this.metaOffset,
    required this.sha1,
  });

  String get compressionName {
    switch (compression[0]) {
      case 0:
        return 'None';
      case 1:
        return 'ZLIB';
      case 2:
        return 'ZLIB+';
      case 3:
        return 'AV';
      case 0x636F6D70: // 'comp'
        return 'Custom';
      default:
        // Convert integer to tag characters
        String tag = '';
        int value = compression[0];
        tag += String.fromCharCode((value >> 24) & 0xFF);
        tag += String.fromCharCode((value >> 16) & 0xFF);
        tag += String.fromCharCode((value >> 8) & 0xFF);
        tag += String.fromCharCode(value & 0xFF);
        return tag;
    }
  }

  @override
  String toString() {
    return 'CHD v$version, $totalHunks hunks of $hunkBytes bytes, $logicalBytes logical bytes, ' +
           'compression: $compressionName';
  }
}

/// Information about a PlayStation executable
class PsxExecutableInfo {
  final String hash;          // The calculated MD5 hash
  final int lba;              // The sector (LBA) where the executable is located
  final int size;             // The size of the executable in bytes
  final String name;          // The filename of the executable
  final String path;          // The full path to the executable
  
  PsxExecutableInfo({
    required this.hash,
    required this.lba,
    required this.size,
    required this.name,
    required this.path,
  });
  
  @override
  String toString() {
    return '''
PlayStation Executable Information:
  Hash: $hash
  Sector (LBA): $lba
  Size: $size bytes
  Filename: $name
  Path: $path
''';
  }
}

/// Result of CHD file processing
class ChdProcessResult {
  final ChdHeader header;
  final List<TrackInfo> tracks;
  final Uint8List? firstTrackData;
  final String? error;

  ChdProcessResult({
    required this.header,
    required this.tracks,
    this.firstTrackData,
    this.error,
  });

  bool get isSuccess => error == null;
  bool get isDataDisc => tracks.isNotEmpty && 
    (tracks[0].type.contains('MODE1') || tracks[0].type.contains('MODE2'));
}

/// Information about a filesystem directory entry
class DirectoryEntry {
  final String name;
  final int lba;
  final int size;
  final bool isDirectory;
  
  DirectoryEntry({
    required this.name,
    required this.lba,
    required this.size,
    required this.isDirectory,
  });
}