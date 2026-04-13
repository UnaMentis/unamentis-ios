#!/usr/bin/env python3
"""
Script to add test files to the UnaMentisTests target in Xcode.
"""

import os
import re
import uuid
import sys

PROJECT_FILE = "UnaMentis.xcodeproj/project.pbxproj"

def generate_uuid():
    """Generate a 24-character hex UUID like Xcode uses."""
    return uuid.uuid4().hex[:24].upper()

def read_project():
    with open(PROJECT_FILE, 'r') as f:
        return f.read()

def write_project(content):
    with open(PROJECT_FILE, 'w') as f:
        f.write(content)

def add_test_file(content, filename, group_pattern):
    """Add a test file to the project."""
    # Check if file already in project
    if filename in content:
        print(f"  {filename} - already in project")
        return content

    file_uuid = generate_uuid()
    build_uuid = generate_uuid()

    # 1. Add PBXFileReference
    file_ref = f'\t\t{file_uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {filename}; sourceTree = "<group>"; }};\n'

    # Find position after existing file references (before "End PBXFileReference section")
    file_ref_end = content.find('/* End PBXFileReference section */')
    if file_ref_end == -1:
        print(f"  ERROR: Could not find PBXFileReference section")
        return content

    content = content[:file_ref_end] + file_ref + content[file_ref_end:]

    # 2. Add PBXBuildFile entry for test target
    build_file = f'\t\t{build_uuid} /* {filename} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_uuid} /* {filename} */; }};\n'

    build_file_end = content.find('/* End PBXBuildFile section */')
    if build_file_end == -1:
        print(f"  ERROR: Could not find PBXBuildFile section")
        return content

    content = content[:build_file_end] + build_file + content[build_file_end:]

    # 3. Add to Unit group (find the Unit group and add the file reference)
    # Look for the Unit group children array
    unit_group_match = re.search(
        r'(/\*\s*Unit\s*\*/\s*=\s*\{[^}]*children\s*=\s*\()([^)]*)\)',
        content,
        re.DOTALL
    )
    if unit_group_match:
        children_start = unit_group_match.start(2)
        children_end = unit_group_match.end(2)
        new_child = f'\n\t\t\t\t{file_uuid} /* {filename} */,'
        content = content[:children_end] + new_child + content[children_end:]

    # 4. Add to test target's Sources build phase
    # Find the test target's sources build phase
    # Look for PBXSourcesBuildPhase associated with UnaMentisTests
    test_sources_match = re.search(
        r'([A-F0-9]{24})\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*isa\s*=\s*PBXSourcesBuildPhase[^}]*files\s*=\s*\(([^)]*)\)',
        content,
        re.DOTALL
    )

    if test_sources_match:
        # We need to find the correct Sources build phase for the test target
        # Look for it near UnaMentisTests entries
        pass

    # Alternative: Find all Sources build phases and add to the one that contains test files
    sources_phases = list(re.finditer(
        r'([A-F0-9]{24})\s*/\*\s*Sources\s*\*/\s*=\s*\{[^}]*isa\s*=\s*PBXSourcesBuildPhase[^}]*files\s*=\s*\(([^)]*)\)',
        content,
        re.DOTALL
    ))

    for match in sources_phases:
        files_section = match.group(2)
        # Check if this is the test target's sources phase (contains test files)
        if 'Tests' in files_section or 'MockServices.swift' in files_section:
            files_end = match.end(2)
            new_file = f'\n\t\t\t\t{build_uuid} /* {filename} in Sources */,'
            content = content[:files_end] + new_file + content[files_end:]
            break

    print(f"  {filename} - added to project")
    return content

def main():
    if not os.path.exists(PROJECT_FILE):
        print(f"Error: {PROJECT_FILE} not found")
        sys.exit(1)

    print("Reading Xcode project...")
    content = read_project()

    # Add test files
    test_files = [
        "PersistenceControllerTests.swift",
        "UMCFParserTests.swift",
    ]

    print("\nAdding test files to UnaMentisTests/Unit:")
    for filename in test_files:
        content = add_test_file(content, filename, "Unit")

    print("\nSaving project...")
    write_project(content)
    print("Done!")

if __name__ == "__main__":
    main()
