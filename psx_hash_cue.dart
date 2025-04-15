// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

/// Main entry point for the PlayStation BIN/CUE hasher
/// This tool generates a unique hash for PlayStation disc images by 
/// processing their BIN/CUE files in a specific way that matches 
/// established hashing standards for PlayStation games
Future<void> main() async {
  try {
    // Path to folder containing bin/cue files - change this to your folder path
    String folderPath = 'i:/test';
    
    // Process all bin files in the folder
    await processBinFilesInFolder(folderPath);
  } catch (e) {
    print('Error in main execution: $e');
    print(e.toString());
  }
}

/// Processes all valid BIN/CUE pairs in the specified folder
/// 
/// This function:
/// 1. Scans the provided directory for BIN and CUE files
/// 2. Maps CUE files to their referenced BIN files
/// 3. For each valid pair, processes the BIN file using track info from the CUE
Future<void> processBinFilesInFolder(String folderPath) async {
  final directory = Directory(folderPath);
  
  if (!await directory.exists()) {
    print('Error: Directory does not exist: $folderPath');
    return;
  }
  
  print('Scanning directory: $folderPath');
  print('-------------------------------------------');
  
  // First, collect all bin and cue files
  Map<String, String> binToCueMap = {};
  List<FileSystemEntity> allFiles = await directory.list().toList();
  
  // Find all cue files and map them to their bin files
  for (var fileEntity in allFiles) {
    if (fileEntity is File && path.extension(fileEntity.path).toLowerCase() == '.cue') {
      String content = await File(fileEntity.path).readAsString();
      // Extract the BIN filename from the CUE file
      RegExp fileRegex = RegExp(r'FILE\s+"([^"]+)"\s+BINARY', caseSensitive: false);
      Match? match = fileRegex.firstMatch(content);
      
      if (match != null && match.groupCount >= 1) {
        String binFileName = match.group(1)!;
        String binFilePath = path.join(folderPath, binFileName);
        
        if (await File(binFilePath).exists()) {
          binToCueMap[binFilePath] = fileEntity.path;
        }
      }
    }
  }
  
  if (binToCueMap.isEmpty) {
    print('No valid bin/cue pairs found in the directory.');
    return;
  }
  
  // Process each bin file with its corresponding cue file
  for (var binFilePath in binToCueMap.keys) {
    String fileName = path.basename(binFilePath);
    String cuePath = binToCueMap[binFilePath]!;
    
    print('Processing file: $fileName');
    print('Using CUE file: ${path.basename(cuePath)}');
    
    try {
      // Parse CUE file to get track information
      List<TrackInfo> tracks = await parseTrackInfo(cuePath);
      
      if (tracks.isEmpty) {
        print('Warning: No tracks found in the CUE file.');
        continue;
      }
      
      print('Found data track: Track ${tracks[0].number}, Type: ${tracks[0].type}');
      
      // Calculate the PlayStation hash 
      String hash = await calculatePlayStationHash(binFilePath, tracks);
      print('PlayStation Hash: $hash');
    } catch (e) {
      print('Error processing $fileName: $e');
    }
    
    print('-------------------------------------------');
  }
}

/// Represents information about a track in a CUE file
class TrackInfo {
  final int number;        // Track number
  final String type;       // Track type (e.g., MODE1/2352, MODE2/2352, AUDIO)
  final int sectorSize;    // Size of each sector in bytes
  final int startSector;   // Starting sector for this track
  
  TrackInfo(this.number, this.type, this.sectorSize, this.startSector);
}

/// Parses the CUE file to extract track information
/// 
/// CUE files contain metadata about the disc structure, including:
/// - Track numbers and types
/// - Track indices and positions
/// - Sector types and sizes
///
/// This function extracts the essential information for hashing
Future<List<TrackInfo>> parseTrackInfo(String cuePath) async {
  List<TrackInfo> tracks = [];
  String content = await File(cuePath).readAsString();
  
  // Regular expressions to extract track and index information
  RegExp trackRegex = RegExp(r'TRACK\s+(\d+)\s+(\w+\/\d+|\w+)', caseSensitive: false);
  RegExp indexRegex = RegExp(r'INDEX\s+01\s+(\d+):(\d+):(\d+)', caseSensitive: false);
  
  List<String> lines = content.split('\n');
  
  int currentTrack = 0;
  String currentType = '';
  int currentSectorSize = 0;
  
  for (int i = 0; i < lines.length; i++) {
    String line = lines[i].trim();
    
    // Parse track info
    Match? trackMatch = trackRegex.firstMatch(line);
    if (trackMatch != null && trackMatch.groupCount >= 2) {
      currentTrack = int.parse(trackMatch.group(1)!);
      currentType = trackMatch.group(2)!.toUpperCase();
      
      // Determine sector size from track type
      // Different track types have different sector sizes and structures
      if (currentType == 'MODE1/2048') {
        currentSectorSize = 2048;  // Raw data sectors
      } else if (currentType == 'MODE1/2352') {
        currentSectorSize = 2352;  // Full sectors with 16-byte header
      } else if (currentType == 'MODE2/2048') {
        currentSectorSize = 2048;  // Raw data sectors
      } else if (currentType == 'MODE2/2352') {
        currentSectorSize = 2352;  // Full sectors with 24-byte header
      } else if (currentType == 'AUDIO') {
        currentSectorSize = 2352;  // Audio sectors (no headers, just audio data)
      } else {
        // Default if unknown
        currentSectorSize = 2352;
      }
      
      continue;
    }
    
    // Parse index info for the current track
    Match? indexMatch = indexRegex.firstMatch(line);
    if (indexMatch != null && indexMatch.groupCount >= 3 && currentTrack > 0) {
      int minutes = int.parse(indexMatch.group(1)!);
      int seconds = int.parse(indexMatch.group(2)!);
      int frames = int.parse(indexMatch.group(3)!);
      
      // Calculate starting sector (1 second = 75 frames in CD format)
      // This formula converts the MM:SS:FF time format to sector number
      int startSector = (minutes * 60 * 75) + (seconds * 75) + frames;
      
      tracks.add(TrackInfo(currentTrack, currentType, currentSectorSize, startSector));
    }
  }
  
  return tracks;
}

/// Determines the data offset within a sector based on track type
/// 
/// Different track types store data at different offsets within a sector:
/// - MODE1/2048: No header, just raw data
/// - MODE1/2352: 16-byte header
/// - MODE2/2048: No header, just raw data
/// - MODE2/2352: 24-byte header
int getDataOffset(String trackType) {
  switch (trackType) {
    case 'MODE1/2048':
      return 0;   // No header, just raw data
    case 'MODE1/2352':
      return 16;  // 16-byte header
    case 'MODE2/2048':
      return 0;   // No header, just raw data
    case 'MODE2/2352':
      return 24;  // 24-byte header
    default:
      return 0;   // Default, no offset
  }
}

/// Calculates the PlayStation hash for a BIN file
/// 
/// This is the core function that implements the official hashing algorithm.
/// The algorithm works as follows:
/// 1. Finds the SYSTEM.CNF file in the disc image
/// 2. Extracts the path to the main executable
/// 3. Extracts just the filename of the executable
/// 4. Finds and reads the executable file
/// 5. Creates a hash by combining:
///    - The filename (as ASCII bytes)
///    - The executable data processed by extracting data from each sector
///
/// This approach matches the official hashing algorithm used for PlayStation games
Future<String> calculatePlayStationHash(String binFilePath, List<TrackInfo> tracks) async {
  final file = File(binFilePath);
  final RandomAccessFile binFile = await file.open(mode: FileMode.read);
  
  try {
    // Check if we have track info
    if (tracks.isEmpty) {
      throw Exception('No track information available');
    }
    
    // Get the first data track info (usually track 1)
    TrackInfo dataTrack = tracks[0];
    int sectorSize = dataTrack.sectorSize;
    int dataOffset = getDataOffset(dataTrack.type);
    
    print('Using sector size: $sectorSize, data offset: $dataOffset');
    
    // The ISO 9660 volume descriptor typically starts at sector 16
    // This is standard for CD-ROM formats including PlayStation
    int vdSector = 16;
    await binFile.setPosition((vdSector * sectorSize) + dataOffset);
    
    // Read the volume descriptor to find the root directory
    Uint8List sectorBuffer = Uint8List(2048);
    await binFile.readInto(sectorBuffer);
    
    // Verify this is a volume descriptor
    if (sectorBuffer[0] != 1) {
      throw Exception('Primary volume descriptor not found at expected location');
    }
    
    // Extract root directory information from the volume descriptor
    // These offsets are defined by the ISO 9660 standard
    int rootDirLBA = sectorBuffer[158] | (sectorBuffer[159] << 8) | 
                    (sectorBuffer[160] << 16) | (sectorBuffer[161] << 24);
    int rootDirSize = sectorBuffer[166] | (sectorBuffer[167] << 8) | 
                     (sectorBuffer[168] << 16) | (sectorBuffer[169] << 24);
    
    print('Root directory found at sector $rootDirLBA with size $rootDirSize bytes');
    
    // Find SYSTEM.CNF in the root directory
    // SYSTEM.CNF is a PlayStation-specific file that contains boot information
    Uint8List? systemCnfContent = await findFileInDir(
      binFile, rootDirLBA, rootDirSize, 'SYSTEM.CNF', sectorSize, dataOffset
    );
    
    String? execPath;
    
    if (systemCnfContent == null) {
      print('SYSTEM.CNF not found in the disc image, trying fallback methods');
      
      // Try finding PSX.EXE directly in the root directory as a fallback
      print('Trying to find PSX.EXE in root directory');
      Uint8List? psxExeContent = await findFileInDir(
        binFile, rootDirLBA, rootDirSize, 'PSX.EXE', sectorSize, dataOffset
      );
      
      if (psxExeContent != null) {
        print('Found PSX.EXE, using it as executable');
        execPath = 'PSX.EXE';
      } else {
        print('PSX.EXE not found either, looking for SLUS, SLES or SCUS files');
        
        // Try to find any executable with standard PlayStation identifiers
        // This requires scanning all files in the root directory
        
        // Scan files in root directory looking for executables
        int currentPos = rootDirLBA * sectorSize + dataOffset;
        int bytesRead = 0;
        int currentSector = rootDirLBA;
        
        await binFile.setPosition(currentPos);
        
        while (bytesRead < rootDirSize) {
          // Read record length
          Uint8List recordLenBuffer = Uint8List(1);
          int bytesReadNow = await binFile.readInto(recordLenBuffer);
          
          if (bytesReadNow == 0 || recordLenBuffer[0] == 0) {
            // End of sector or padding, move to next sector
            currentSector++;
            currentPos = (currentSector * sectorSize) + dataOffset;
            await binFile.setPosition(currentPos);
            bytesRead = (currentSector - rootDirLBA) * (sectorSize - dataOffset);
            continue;
          }
          
          int recordLen = recordLenBuffer[0];
          
          // Read directory record
          Uint8List recordBuffer = Uint8List(recordLen - 1);
          await binFile.readInto(recordBuffer);
          
          bytesRead += recordLen;
          
          // Extract file information
          int fileFlags = recordBuffer[24];
          int fileNameLen = recordBuffer[31];
          
          // Skip if this is a directory (and not a file)
          bool isDirectory = (fileFlags & 0x02) == 0x02;
          
          if (fileNameLen > 0 && !isDirectory) {
            // Get the filename
            Uint8List nameBuffer = recordBuffer.sublist(32, 32 + fileNameLen);
            String entryName = String.fromCharCodes(nameBuffer).toUpperCase();
            
            // Remove version number if present
            int versionIndex = entryName.lastIndexOf(';');
            if (versionIndex > 0) {
              entryName = entryName.substring(0, versionIndex);
            }
            
            // Check if it matches PlayStation's standard executable patterns
            if (entryName.startsWith('SLUS') || 
                entryName.startsWith('SLES') || 
                entryName.startsWith('SCUS')) {
              print('Found potential executable: $entryName');
              execPath = entryName;
              break;
            }
          }
        }
      }
      
      if (execPath == null) {
        throw Exception('Could not find PlayStation executable');
      }
    } else {
      // Parse SYSTEM.CNF content to extract boot path
      execPath = extractExecutablePath(systemCnfContent);
      
      if (execPath == null) {
        throw Exception('Primary executable path not found in SYSTEM.CNF');
      }
    }
    
    print('Found primary executable path: $execPath');
    
    // For the hash, we want to include:
    // 1. The subfolder and filename (if in a subfolder)
    // 2. The version number (if present)
    
    // Start with the full path (preserving original case and structure)
    String pathForHash = execPath;
    
    // Remove cdrom: prefix if present
    if (pathForHash.toLowerCase().startsWith('cdrom:')) {
      pathForHash = pathForHash.substring(6);
    }
    
    // Ensure we're using backslash for consistency
    pathForHash = pathForHash.replaceAll('/', '\\');
    
    // Remove all leading slashes
  while (pathForHash.startsWith('\\')) {
  pathForHash = pathForHash.substring(1);
  }
    
    print('Using path for hash: $pathForHash');
    
    // Normalize the path for lookup in the ISO filesystem
    String normalizedPath = normalizeExecutablePath(execPath);
    
    // Find and read the primary executable file
    Uint8List? execContent = await findFile(
      binFile, rootDirLBA, rootDirSize, normalizedPath, sectorSize, dataOffset
    );
    
    if (execContent == null) {
      throw Exception('Primary executable file not found: $normalizedPath');
    }
    
    print('Found executable file (${execContent.length} bytes)');
    
  if (execContent.length >= 8 && 
    String.fromCharCodes(execContent.sublist(0, 8)) == "PS-X EXE") {
  // Extract size from header (stored at offset 28)
  int exeDataSize = execContent[28] | 
                    (execContent[29] << 8) | 
                    (execContent[30] << 16) | 
                    (execContent[31] << 24);
  // Add 2048 bytes for the header
  int adjustedSize = exeDataSize + 2048;
  print('PS-X EXE marker found, adjusted size from ${execContent.length} to $adjustedSize bytes');
  
  // In the C implementation, we don't actually expand the executable
  // Just provide a warning if the size is larger than what we have
  if (adjustedSize > execContent.length) {
    print('Warning: Calculated size is larger than actual file');
    // The C code continues with what it has - it doesn't attempt to 
    // pad with zeros or read more data than is available
  } else if (adjustedSize < execContent.length) {
    // Truncate if we have more data than needed
    execContent = execContent.sublist(0, adjustedSize);
  }
}



    // Find the file entity again to get its LBA (Logical Block Address)
    int? executableLBA = await findFileLBA(
      binFile, rootDirLBA, rootDirSize, normalizedPath, sectorSize, dataOffset
    );
    
    if (executableLBA == null) {
      throw Exception('Could not find LBA for executable');
    }
    
    print('Executable LBA: $executableLBA');
    
    // Calculate number of sectors needed for the executable
    int execSectors = (execContent.length + 2048 - 1) ~/ 2048; // Ceiling division
    
    // The hash combines:
    // 1. The full path including subfolder (using pathForHash)
    // 2. The executable data processed sector by sector
    
    // First, encode the path to ASCII bytes
    List<int> pathBytes = ascii.encode(pathForHash);
    BytesBuilder buffer = BytesBuilder();
    buffer.add(pathBytes);
    
    // Then read the executable by processing each sector individually
    // This is crucial for the correct hash calculation
    Uint8List processedExec = await readFileByProcessingSectors(
      binFile, 
      executableLBA, 
      execSectors,
      sectorSize,
      dataOffset
    );
    
    // Add the processed executable data to the buffer
    buffer.add(processedExec);
    print('Final path string for hash: "$pathForHash"');
    // Calculate the MD5 hash of the combined data
    String hash = md5.convert(buffer.toBytes()).toString();
    
    return hash;
  } finally {
    await binFile.close();
  }
}

/// Reads file sectors in a specific way that processes each sector individually
/// 
/// This is critical for the PlayStation hash algorithm:
/// 1. Each sector is read starting at its specific offset
/// 2. Only the data portion (2048 bytes) is extracted from each sector
/// 3. These data portions are combined in sequence
///
/// This approach handles the sector structure of PlayStation discs correctly
Future<Uint8List> readFileByProcessingSectors(
  RandomAccessFile file,
  int startSector,
  int sectorCount,
  int sectorSize,
  int dataOffset
) async {
  BytesBuilder builder = BytesBuilder();
  
  for (int i = 0; i < sectorCount; i++) {
    // Calculate the position of this sector in the file
    int sectorPosition = (startSector + i) * sectorSize;
    
    // Skip the header (dataOffset bytes) to get to the actual data
    await file.setPosition(sectorPosition + dataOffset);
    
    // Read 2048 bytes of data from each sector
    Uint8List sectorData = Uint8List(2048);
    int bytesRead = await file.readInto(sectorData);
    
    // If we couldn't read any data, we're at the end of the file
    // This matches C implementation which stops reading when no more data
    if (bytesRead == 0) {
      break;
    }
    
    // Add this sector's data to our buffer
    builder.add(sectorData);
  }
  
  return builder.toBytes();
}

/// Normalizes a PlayStation executable path for lookup purposes
/// 
/// PlayStation paths can come in various formats:
/// - With "cdrom:" prefix
/// - With backslashes or forward slashes
/// - With version numbers (;1)
///
/// This function standardizes the path to find it in the ISO filesystem
String normalizeExecutablePath(String path) {
  String result = path;
  
  // Remove cdrom: prefix
  // In normalizeExecutablePath, update to handle extra slashes more flexibly:
if (result.toLowerCase().startsWith('cdrom:')) {
  result = result.substring(6);
  // Remove ANY number of leading slashes after the cdrom: prefix
  while (result.startsWith('/') || result.startsWith('\\')) {
    result = result.substring(1);
  }
}
  
  // Standardize slashes
  result = result.replaceAll('\\', '/');
  
  // Remove leading slash if present
  if (result.startsWith('/')) {
    result = result.substring(1);
  }
  
  // Remove version number if present
  int versionIndex = result.lastIndexOf(';');
  if (versionIndex > 0) {
    result = result.substring(0, versionIndex);
  }
  
  return result.trim();
}

/// Extracts the primary executable path from the SYSTEM.CNF file
/// 
/// SYSTEM.CNF contains a line like:
/// BOOT = cdrom:\SLUS_123.45;1
///
/// This function extracts the path portion
String? extractExecutablePath(Uint8List systemCnfContent) {
  // Convert the raw bytes to a string
  String content = ascii.decode(systemCnfContent, allowInvalid: true);
  
  // Parse to extract the primary executable path from the BOOT= line
  RegExp bootRegExp = RegExp(r'BOOT\s*=\s*(.+?)(?:\s|;|$)', caseSensitive: false);
  Match? match = bootRegExp.firstMatch(content);
  
  if (match != null && match.groupCount >= 1) {
    return match.group(1)?.trim();
  }
  
  return null;
}

/// Finds the Logical Block Address (LBA) of a file in the ISO filesystem
/// 
/// The LBA is the starting sector number of the file and is needed
/// to properly read the file sector by sector
Future<int?> findFileLBA(
  RandomAccessFile file,
  int dirSector,
  int dirSize,
  String fileName,
  int sectorSize,
  int dataOffset
) async {
  // Convert filename to uppercase for case-insensitive comparison
  // ISO 9660 filenames are typically uppercase
  fileName = fileName.toUpperCase();
  
  int currentPos = dirSector * sectorSize + dataOffset;
  int bytesRead = 0;
  int currentSector = dirSector;
  
  await file.setPosition(currentPos);
  
  while (bytesRead < dirSize) {
    // Read the length of the directory record
    Uint8List recordLenBuffer = Uint8List(1);
    int bytesReadNow = await file.readInto(recordLenBuffer);
    
    if (bytesReadNow == 0 || recordLenBuffer[0] == 0) {
      // End of sector or padding, move to next sector
      currentSector++;
      currentPos = (currentSector * sectorSize) + dataOffset;
      await file.setPosition(currentPos);
      bytesRead = (currentSector - dirSector) * (sectorSize - dataOffset);
      continue;
    }
    
    int recordLen = recordLenBuffer[0];
    
    // Read the rest of the directory record
    Uint8List recordBuffer = Uint8List(recordLen - 1);
    await file.readInto(recordBuffer);
    
    bytesRead += recordLen;
    
    // Extract file information from the record
    // These offsets are defined by the ISO 9660 standard
    int fileLBA = recordBuffer[1] | (recordBuffer[2] << 8) | 
                 (recordBuffer[3] << 16) | (recordBuffer[4] << 24);
    int fileSize = recordBuffer[9] | (recordBuffer[10] << 8) | 
                  (recordBuffer[11] << 16) | (recordBuffer[12] << 24);
    int fileFlags = recordBuffer[24];
    int fileNameLen = recordBuffer[31];
    
    // Skip if this is a directory (and not a file)
    bool isDirectory = (fileFlags & 0x02) == 0x02;
    
    if (fileNameLen > 0) {
      // Get the filename from the record
      Uint8List nameBuffer = recordBuffer.sublist(32, 32 + fileNameLen);
      String entryName = String.fromCharCodes(nameBuffer).toUpperCase();
      
      // Remove version number if present for comparison
      int versionIndex = entryName.lastIndexOf(';');
      if (versionIndex > 0) {
        entryName = entryName.substring(0, versionIndex);
      }
      
      // If this is the file we're looking for, return its LBA
      if (!isDirectory && entryName == fileName) {
        return fileLBA;
      }
    }
  }
  
  return null;
}

/// Finds and reads a file in a directory of the ISO filesystem
Future<Uint8List?> findFileInDir(
  RandomAccessFile file,
  int dirSector,
  int dirSize,
  String fileName,
  int sectorSize,
  int dataOffset
) async {
  // Convert filename to uppercase for case-insensitive comparison
  fileName = fileName.toUpperCase();
  
  int currentPos = dirSector * sectorSize + dataOffset;
  int bytesRead = 0;
  int currentSector = dirSector;
  
  await file.setPosition(currentPos);
  
  while (bytesRead < dirSize) {
    // Read record length
    Uint8List recordLenBuffer = Uint8List(1);
    int bytesReadNow = await file.readInto(recordLenBuffer);
    
    if (bytesReadNow == 0 || recordLenBuffer[0] == 0) {
      // End of sector or padding, move to next sector
      currentSector++;
      currentPos = (currentSector * sectorSize) + dataOffset;
      await file.setPosition(currentPos);
      bytesRead = (currentSector - dirSector) * (sectorSize - dataOffset);
      continue;
    }
    
    int recordLen = recordLenBuffer[0];
    
    // Read directory record
    Uint8List recordBuffer = Uint8List(recordLen - 1);
    await file.readInto(recordBuffer);
    
    bytesRead += recordLen;
    
    // Extract file information
    int fileLBA = recordBuffer[1] | (recordBuffer[2] << 8) | 
                 (recordBuffer[3] << 16) | (recordBuffer[4] << 24);
    int fileSize = recordBuffer[9] | (recordBuffer[10] << 8) | 
                  (recordBuffer[11] << 16) | (recordBuffer[12] << 24);
    int fileFlags = recordBuffer[24];
    int fileNameLen = recordBuffer[31];
    
    // Skip if this is a directory (and not a file)
    bool isDirectory = (fileFlags & 0x02) == 0x02;
    
    if (fileNameLen > 0) {
      Uint8List nameBuffer = recordBuffer.sublist(32, 32 + fileNameLen);
      String entryName = String.fromCharCodes(nameBuffer).toUpperCase();
      
      // Remove version number if present for comparison
      int versionIndex = entryName.lastIndexOf(';');
      if (versionIndex > 0) {
        entryName = entryName.substring(0, versionIndex);
      }
      
      // If this is the file we're looking for
      if (!isDirectory && entryName == fileName) {
        // Read the file data sector by sector, handling sector boundaries
        await file.setPosition(fileLBA * sectorSize + dataOffset);
        Uint8List fileContent = Uint8List(fileSize);
        
        int remainingBytes = fileSize;
        int bufferOffset = 0;
        int currentFileSector = fileLBA;
        
        while (remainingBytes > 0) {
          // Calculate how many bytes to read from this sector
          int bytesToRead = remainingBytes > (sectorSize - dataOffset) 
              ? (sectorSize - dataOffset) 
              : remainingBytes;
          
          Uint8List sectorData = Uint8List(bytesToRead);
          await file.readInto(sectorData);
          
          // Copy this sector's data to the file content buffer
          fileContent.setRange(bufferOffset, bufferOffset + bytesToRead, sectorData);
          
          bufferOffset += bytesToRead;
          remainingBytes -= bytesToRead;
          
          if (remainingBytes > 0) {
            // Move to next sector, accounting for the data offset
            currentFileSector++;
            await file.setPosition(currentFileSector * sectorSize + dataOffset);
          }
        }
        
        return fileContent;
      }
    }
  }
  
  return null;
}

/// Finds and reads a file at a specific path in the ISO filesystem
///
/// This handles multi-level paths, navigating through directories
/// to find the specified file
Future<Uint8List?> findFile(
  RandomAccessFile file,
  int rootDirSector,
  int rootDirSize,
  String filePath,
  int sectorSize,
  int dataOffset
) async {
  // Split the path into parts
  List<String> pathParts = filePath.split('/');
  
  // If it's just a file in the root directory
  if (pathParts.length == 1) {
    return findFileInDir(file, rootDirSector, rootDirSize, pathParts[0], sectorSize, dataOffset);
  }
  
  // Handle directories in the path
  int currentDirSector = rootDirSector;
  int currentDirSize = rootDirSize;
  
  // Navigate through each directory in the path
  for (int i = 0; i < pathParts.length - 1; i++) {
    // Find directory entry
    String dirName = pathParts[i].toUpperCase();
    
    // Skip empty path segments
    if (dirName.isEmpty) continue;
    
    bool found = false;
    int bytesRead = 0;
    int currentPos = currentDirSector * sectorSize + dataOffset;
    int currentSector = currentDirSector;
    
    await file.setPosition(currentPos);
    
    while (bytesRead < currentDirSize) {
      // Read record length
      Uint8List recordLenBuffer = Uint8List(1);
      await file.readInto(recordLenBuffer);
      
      if (recordLenBuffer[0] == 0) {
        // End of sector or padding, move to next sector
        currentSector++;
        currentPos = (currentSector * sectorSize) + dataOffset;
        await file.setPosition(currentPos);
        bytesRead = (currentSector - currentDirSector) * (sectorSize - dataOffset);
        continue;
      }
      
      int recordLen = recordLenBuffer[0];
      
      // Read directory record
      Uint8List recordBuffer = Uint8List(recordLen - 1);
      await file.readInto(recordBuffer);
      
      bytesRead += recordLen;
      
      // Extract file information
      int entryLBA = recordBuffer[1] | (recordBuffer[2] << 8) | 
                    (recordBuffer[3] << 16) | (recordBuffer[4] << 24);
      int entrySize = recordBuffer[9] | (recordBuffer[10] << 8) | 
                     (recordBuffer[11] << 16) | (recordBuffer[12] << 24);
      int entryFlags = recordBuffer[24];
      int entryNameLen = recordBuffer[31];
      
      // Only process directories
      bool isDirectory = (entryFlags & 0x02) == 0x02;
      
      if (entryNameLen > 0 && isDirectory) {
        Uint8List nameBuffer = recordBuffer.sublist(32, 32 + entryNameLen);
        String entryName = String.fromCharCodes(nameBuffer).toUpperCase();
        
        // Skip . and .. entries (represented by special characters in ISO 9660)
        if (entryName == '\u0000' || entryName == '\u0001') continue;
        
        // Remove version number if present
        int versionIndex = entryName.lastIndexOf(';');
        if (versionIndex > 0) {
          entryName = entryName.substring(0, versionIndex);
        }
        
        if (entryName == dirName) {
          // Found the directory, update current position for next iteration
          currentDirSector = entryLBA;
          currentDirSize = entrySize;
          found = true;
          break;
        }
      }
    }
    
    if (!found) {
      return null;  // Directory not found
    }
  }
  
  // Find the file in the final directory
  return findFileInDir(
      file, 
      currentDirSector, 
      currentDirSize, 
      pathParts.last, 
      sectorSize, 
      dataOffset
  );
}