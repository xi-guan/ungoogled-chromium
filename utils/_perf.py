"""
Performance-optimized replacements for file traversal and hash verification.
Separated to minimize diffs in upstream-tracked files during sync.
"""

import hashlib
import os
import stat
from pathlib import Path


def walk_and_prune(path, should_keep=None):
    """Delete files and empty directories using os.walk instead of sorted rglob."""
    for dirpath, dirnames, filenames in os.walk(path, topdown=False):
        dir_path = Path(dirpath)
        for name in filenames:
            node = dir_path / name
            if should_keep and should_keep(node):
                continue
            try:
                node.unlink()
            except PermissionError:
                node.chmod(stat.S_IWRITE)
                node.unlink()
        for name in dirnames:
            node = dir_path / name
            if node.is_symlink():
                node.unlink()
            elif not any(node.iterdir()):
                try:
                    node.rmdir()
                except PermissionError:
                    node.chmod(stat.S_IWRITE)
                    node.rmdir()


def walk_and_clean(root_dir, should_delete):
    """Walk directory tree and delete matching files, skipping .git dirs."""
    for dirpath, dirnames, filenames in os.walk(root_dir, topdown=False):
        dir_path = Path(dirpath)
        if '.git' in dir_path.parts:
            continue
        for name in filenames:
            fpath = dir_path / name
            if should_delete(fpath):
                try:
                    fpath.unlink()
                except PermissionError:
                    fpath.chmod(stat.S_IWRITE)
                    fpath.unlink()
        for name in dirnames:
            dpath = dir_path / name
            if not dpath.is_symlink() and not any(dpath.iterdir()):
                try:
                    dpath.rmdir()
                except PermissionError:
                    dpath.chmod(stat.S_IWRITE)
                    dpath.rmdir()


def verify_hashes(file_path, hash_pairs, chunk_bytes=262144):
    """Verify multiple hashes in a single file read pass.
    Returns the name of the first failing hash, or None if all pass."""
    if not hash_pairs:
        return None
    hashers = [(name, expected, hashlib.new(name)) for name, expected in hash_pairs]
    with file_path.open('rb') as handle:
        while True:
            chunk = handle.read(chunk_bytes)
            if not chunk:
                break
            for _, _, hasher in hashers:
                hasher.update(chunk)
    for name, expected, hasher in hashers:
        if hasher.hexdigest().lower() != expected.lower():
            return name
    return None
