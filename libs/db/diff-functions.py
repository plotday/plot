#!/usr/bin/env python3
import sys
import re
import argparse
from pathlib import Path


def normalize_whitespace(text):
    """Normalize whitespace for comparison, preserving structure"""
    # Remove leading/trailing whitespace from each line
    lines = [re.sub(r"\s+", " ", line.strip()) for line in text.split("\n")]
    # Remove empty lines and join with single spaces
    return " ".join(line for line in lines if line)


def extract_functions(sql_content):
    """Extract PostgreSQL functions from SQL content"""
    functions = {}

    # Pattern to match CREATE OR REPLACE FUNCTION ... $function$;
    pattern = r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+([^\s(]+).*?\$function\$;"

    matches = re.finditer(pattern, sql_content, re.IGNORECASE | re.DOTALL)

    for match in matches:
        function_name = match.group(1).strip()
        function_body = match.group(0)
        functions[function_name] = function_body

    return functions


def read_sql_files(directory_path):
    """Read all SQL files in directory and extract functions"""
    all_functions = {}

    directory = Path(directory_path)

    if not directory.exists():
        print(f"Error: Directory {directory_path} does not exist", file=sys.stderr)
        sys.exit(1)

    # Recursively find all .sql files
    for sql_file in directory.rglob("*.sql"):
        try:
            with open(sql_file, "r", encoding="utf-8") as f:
                content = f.read()
                functions = extract_functions(content)
                all_functions.update(functions)
        except Exception as e:
            print(f"Error reading {sql_file}: {e}", file=sys.stderr)

    return all_functions


def main():
    parser = argparse.ArgumentParser(
        description="Diff PostgreSQL functions between files and stdin"
    )
    parser.add_argument("directory", help="Path to directory containing SQL files")

    args = parser.parse_args()

    # Read functions from SQL files
    file_functions = read_sql_files(args.directory)

    # Read SQL from stdin
    stdin_content = sys.stdin.read()
    stdin_functions = extract_functions(stdin_content)

    # Compare functions and find differences
    different_functions = []

    for func_name, stdin_func in stdin_functions.items():
        if func_name in file_functions:
            # Normalize both versions for comparison
            stdin_normalized = normalize_whitespace(stdin_func)
            file_normalized = normalize_whitespace(file_functions[func_name])

            if stdin_normalized != file_normalized:
                different_functions.append(stdin_func)
        else:
            # Function not found in files, so it's different
            different_functions.append(stdin_func)

    # Output different functions
    for func in different_functions:
        print(func)
        print()  # Add blank line between functions


if __name__ == "__main__":
    main()

