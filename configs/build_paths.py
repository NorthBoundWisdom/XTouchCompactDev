"""Keep generated writes within the repository build directory."""

from pathlib import Path


def build_path(repo_root: Path, relative: str) -> Path:
    """Reject symlinked ancestors before creating or replacing generated artifacts."""
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(part in {".", ".."} for part in parts):
        raise ValueError("Expected a relative build artifact path.")
    path = repo_root
    for part in ("build", *parts):
        path = path / part
        if path.is_symlink():
            raise ValueError(f"Refusing a symlinked build artifact path: {path}")
    return path
