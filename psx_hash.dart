// psx_hash.dart - PlayStation hash calculation
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'chd_reader.dart';
import 'models.dart';
import 'psx_filesystem.dart';

/// Class to handle PlayStation-specific hash calculation
class PsxHashCalculator {
  final ChdReader _chdReader;
  final PsxFilesystem _filesystem;
  
  PsxHashCalculator(this._chdReader, this._filesystem);
  
  /// Calculate the PlayStation hash for a CHD file
  Future<PsxExecutableInfo?> calculateHash() async {
  try {
    // Step 1: Find the primary executable path from SYSTEM.CNF
    String? execPath = await _filesystem.findExecutablePath();
    if (execPath == null) {
      print('Failed to find executable path in SYSTEM.CNF');
      
      // Try finding PSX.EXE directly in the root directory as a fallback
      print('Trying to find PSX.EXE in root directory');
      DirectoryEntry? psx = await _filesystem.findFileInRoot('PSX.EXE');
      if (psx != null) {
        print('Found PSX.EXE, using it as executable');
        execPath = 'PSX.EXE';
      } else {
        print('PSX.EXE not found either, looking for SLUS, SLES or SCUS files');
        // Try to find any executable with standard PlayStation identifiers
        Map<String, dynamic>? rootDir = await _filesystem.findRootDirectory();
        if (rootDir != null) {
          List<DirectoryEntry>? entries = await _filesystem.listDirectory(rootDir['lba'], rootDir['size']);
          if (entries != null) {
            for (var entry in entries) {
              if (!entry.isDirectory && 
                  (entry.name.startsWith('SLUS') || 
                   entry.name.startsWith('SLES') || 
                   entry.name.startsWith('SCUS'))) {
                print('Found potential executable: ${entry.name}');
                execPath = entry.name;
                break;
              }
            }
          }
        }
        
        if (execPath == null) {
          return null;
        }
      }
    }
    
    print('Using executable path: $execPath');
    
    // Step 2: Find the executable file
    DirectoryEntry? execFile = await _filesystem.findFile(execPath);
    if (execFile == null) {
      print('Executable file not found: $execPath');
      return null;
    }
    
    print('Found executable file (${execFile.size} bytes) at LBA ${execFile.lba}');
    
    // Step 3: Read the executable file with proper error handling
    Uint8List? execData = await _filesystem.readFile(execFile);
    if (execData == null) {
      print('Failed to read executable file');
      return null;
    }
    if (execData.length >= 8 && String.fromCharCodes(execData.sublist(0, 8)) == "PS-X EXE") {
  // Extract size from header (stored at offset 28)
  int exeDataSize = execData[28] | 
                   (execData[29] << 8) | 
                   (execData[30] << 16) | 
                   (execData[31] << 24);
  // Add 2048 bytes for the header
  int adjustedSize = exeDataSize + 2048;
  print('PS-X EXE marker found, adjusted size from ${execData.length} to $adjustedSize bytes');
  
  // Adjust our executable content if needed
  if (adjustedSize != execData.length) {
    if (adjustedSize < execData.length) {
      execData = execData.sublist(0, adjustedSize);
    } else {
      print('Warning: Calculated size is larger than actual file');
    }
  }
}
    
    // Step 4: Calculate the hash
    // For the hash, we want to include:
    // 1. The subfolder and filename (if in a subfolder)
    // 2. The version number (if present)
    
    // Start with the normalized path (without cdrom: prefix)
    String pathForHash = execPath;
    
    // Remove cdrom: prefix if present
    if (pathForHash.toLowerCase().startsWith('cdrom:')) {
      pathForHash = pathForHash.substring(6);
    }
    
    // Ensure we're using backslash for consistency
    pathForHash = pathForHash.replaceAll('/', '\\');
    
    // Remove leading slash if present
    while (pathForHash.startsWith('\\')) {
      pathForHash = pathForHash.substring(1);
    }
    
    // Make sure the version number is included if it was in the original path
    if (!pathForHash.contains(';') && execPath.contains(';')) {
      int versionIndex = execPath.lastIndexOf(';');
      String versionPart = execPath.substring(versionIndex);
      pathForHash += versionPart;
    }
    
    print('Using path for hash: $pathForHash');
    
    // Calculate hash from both path and executable data
    List<int> pathBytes = ascii.encode(pathForHash);
    BytesBuilder buffer = BytesBuilder();
    buffer.add(pathBytes);
    buffer.add(execData);
    
    String hash = md5.convert(buffer.toBytes()).toString();
    print('Calculated hash: $hash');
    
    // Extract just the filename part (without path and version) for display purposes
    String filename = execPath;
    if (execPath.contains('\\')) {
      filename = execPath.substring(execPath.lastIndexOf('\\') + 1);
    } else if (execPath.contains('/')) {
      filename = execPath.substring(execPath.lastIndexOf('/') + 1);
    }
    
    // Remove version number for display
    int displayVersionIndex = filename.lastIndexOf(';');
    if (displayVersionIndex > 0) {
      filename = filename.substring(0, displayVersionIndex);
    }
    
    // Step 5: Return the executable information
    return PsxExecutableInfo(
      hash: hash,
      lba: execFile.lba,
      size: execFile.size,
      name: filename,
      path: execPath,
    );
  } catch (e, stackTrace) {
    print('Error calculating PlayStation hash: $e');
    print('Stack trace: $stackTrace');
    return null;
  }
}
}