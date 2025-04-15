// main.dart - Main entry point for the CHD PlayStation hash calculator
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import 'chd_reader.dart';
import 'models.dart';
import 'psx_filesystem.dart';
import 'psx_hash.dart';

/// Main entry point for the application
Future<void> main(List<String> arguments) async {
  // Hardcoded paths
  String hardcodedLibPath = 'chdr.dll'; // DLL in the same folder
  String defaultChdPath = 'i:/test';
  
  // Parse command line arguments
  ArgParser parser = ArgParser()
    ..addOption('lib', help: 'Path to CHD library file', defaultsTo: hardcodedLibPath)
    ..addFlag('verbose', abbr: 'v', help: 'Enable verbose output', defaultsTo: false)
    ..addFlag('help', abbr: 'h', help: 'Show help', negatable: false);

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    print('Error parsing arguments: $e');
    _printUsage(parser);
    exit(1);
  }

  // Show help if requested
  if (args['help']) {
    _printUsage(parser);
    exit(0);
  }

  // Use hardcoded lib path
  String libPath = args['lib'];
  print('Using CHD library: $libPath');
  
  // Initialize the CHD reader
  ChdReader chdReader = ChdReader(libPath);

  if (!chdReader.isInitialized) {
    print('Error: Failed to initialize CHD library');
    print('The library should be named $hardcodedLibPath and in the same folder as the application');
    exit(1);
  }

  bool verbose = args['verbose'];
  
  // Get file paths: either from arguments or use default path
  List<String> filePaths;
  if (args.rest.isEmpty) {
    // If no files specified, scan the default directory
    print('No files specified, scanning directory: $defaultChdPath');
    filePaths = await _scanDirectoryForChd(defaultChdPath);
    
    if (filePaths.isEmpty) {
      print('No CHD files found in $defaultChdPath');
      exit(1);
    }
  } else {
    filePaths = args.rest;
  }
  
  // Process each file
  for (String filePath in filePaths) {
    await _processFile(filePath, chdReader, verbose);
  }
}

/// Scan a directory for CHD files
Future<List<String>> _scanDirectoryForChd(String directoryPath) async {
  List<String> chdFiles = [];
  
  try {
    Directory dir = Directory(directoryPath);
    if (!await dir.exists()) {
      print('Directory does not exist: $directoryPath');
      return chdFiles;
    }
    
    await for (FileSystemEntity entity in dir.list(recursive: false, followLinks: false)) {
      if (entity is File && path.extension(entity.path).toLowerCase() == '.chd') {
        chdFiles.add(entity.path);
      }
    }
  } catch (e) {
    print('Error scanning directory: $e');
  }
  
  return chdFiles;
}

/// Process a single CHD file
Future<void> _processFile(String filePath, ChdReader chdReader, bool verbose) async {
  print('\nProcessing file: ${path.basename(filePath)}');
  print('--------------------------------------------------');
  
  if (!await File(filePath).exists()) {
    print('Error: File does not exist');
    return;
  }
  
  try {
    // Step 1: Process the CHD file to extract its tracks
    print('Reading CHD file...');
    ChdProcessResult result = await chdReader.processChdFile(filePath);
    
    if (!result.isSuccess) {
      print('Error: ${result.error}');
      return;
    }
    
    if (verbose) {
      print('CHD Header: ${result.header}');
      print('Tracks found: ${result.tracks.length}');
      for (var track in result.tracks) {
        print('  $track');
      }
    } else {
      // Print minimal track info even in non-verbose mode for debugging
      print('Found ${result.tracks.length} tracks');
      print('First track: ${result.tracks[0]}');
    }
    
    // Check header values to ensure they're valid
    if (result.header.unitBytes == 0) {
      print('Error: CHD header has unitBytes=0, which will cause division by zero');
      return;
    }
    
    // Check if this is a data disc
    if (!result.isDataDisc) {
      print('Error: Not a data disc (first track is not MODE1/MODE2)');
      return;
    }
    
    // Step 2: Create a filesystem handler for the first data track
    print('Analyzing disc filesystem...');
    PsxFilesystem filesystem = PsxFilesystem(chdReader, filePath, result.tracks[0]);
    
    // Test filesystem access
    var rootDir = await filesystem.findRootDirectory();
    if (rootDir == null) {
      print('Error: Could not find root directory in filesystem');
      return;
    }
    
    if (verbose) {
      print('Root directory found at LBA ${rootDir['lba']} with size ${rootDir['size']}');
      
      // Try to list root directory
      var entries = await filesystem.listDirectory(rootDir['lba'], rootDir['size']);
      if (entries != null) {
        print('Root directory contains ${entries.length} entries:');
        for (var entry in entries.take(5)) {
          print('  ${entry.name} (${entry.isDirectory ? "DIR" : "FILE"}, LBA: ${entry.lba}, Size: ${entry.size})');
        }
        if (entries.length > 5) {
          print('  ... and ${entries.length - 5} more entries');
        }
      }
    }
    
    // Step 3: Create a hash calculator
    print('Calculating PlayStation hash...');
    PsxHashCalculator hashCalculator = PsxHashCalculator(chdReader, filesystem);
    
    // Step 4: Calculate the hash
    PsxExecutableInfo? execInfo = await hashCalculator.calculateHash();
    
    if (execInfo == null) {
      print('Error: Failed to calculate hash');
      return;
    }
    
    // Step 5: Output the results
    print('\nResults:');
    print(execInfo);
  } catch (e, stackTrace) {
    print('Error processing file: $e');
    if (verbose) {
      print('Stack trace:');
      print(stackTrace);
    }
  }
}

/// Print usage information
void _printUsage(ArgParser parser) {
  print('PlayStation CHD Hash Calculator\n');
  print('Usage: dart main.dart [options] <chd_file1> [chd_file2 ...]\n');
  print('Options:');
  print(parser.usage);
}