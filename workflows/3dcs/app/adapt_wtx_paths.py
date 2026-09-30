#!/usr/bin/env python3
"""Rewrite the file references of a 3DCS model (.wtx) to the files downloaded next to it.

3DCS resolves the paths between angle brackets relative to its working directory
(DCSWORK). The workers and the merge run one level below the model directory
(job_dir_<n>/, merge/), so every referenced file found under the current directory
is rewritten as ..\\<its relative path, Windows style>. The file is read and written
back in the first encoding that decodes it.

Usage: adapt_wtx_paths.py <model.wtx>   (run from the directory holding the model)
"""
import os
import sys

ENCODINGS = ["utf-8", "shift_jis", "euc-jp", "iso-2022-jp", "latin-1"]


def replace_between_angle_brackets(line, replacement):
    left = line.split(">")[0]
    right = line.split("<")[-1]
    return left + ">" + replacement + "<" + right


def read_lines(path):
    for encoding in ENCODINGS:
        try:
            with open(path, "r", encoding=encoding) as f:
                return f.readlines(), encoding
        except UnicodeDecodeError as e:
            print(f"Failed to decode {path} with encoding {encoding}: {e}")
    raise ValueError(f"Unable to decode {path} with any of {ENCODINGS}")


def find_files():
    files = []
    for root, _, names in os.walk("."):
        for name in names:
            files.append(os.path.relpath(os.path.join(root, name)))
    return files


def main():
    wtx_path = sys.argv[1]
    files = find_files()
    lines, encoding = read_lines(wtx_path)
    new_lines = []
    for line in lines:
        for path in files:
            if os.path.basename(path) in line:
                line = replace_between_angle_brackets(line, "..\\" + path.replace("/", "\\"))
        new_lines.append(line)
    with open(wtx_path, "w", encoding=encoding) as f:
        f.writelines(new_lines)


if __name__ == "__main__":
    main()
