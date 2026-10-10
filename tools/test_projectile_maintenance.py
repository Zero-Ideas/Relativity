"""Run source-backed regressions without Studio; no place/build artifacts.

Roblox services, geometry values and Actor delivery are deterministic test doubles.
The production registry, rewind, Store, dispatch and ApplyPass code runs unchanged.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MODULES = {
    "FilterRegistry": "src/server/Projectile/FilterRegistry.luau",
    "Math": "src/server/Projectile/Math.luau",
    "RewindHit": "src/server/Projectile/RewindHit.luau",
    "Store": "src/server/Projectile/Store.luau",
    "Sweep": "src/server/Projectile/Sweep.luau",
    "ApplyPass": "src/server/Projectile/ApplyPass.luau",
    "Parallel": "src/server/Projectile/Parallel.luau",
    "Quota": "src/server/ProjectileQuota.luau",
    "VisualOffload": "src/shared/VisualOffload.luau",
}


def main():
    source = (ROOT / "tests/ProjectileMaintenanceRegression.luau").read_text()
    for name, path in MODULES.items():
        module = (ROOT / path).read_text()
        source = source.replace(
            f"-- LOAD {name}",
            f"local {name} = (function()\n{module}\nend)()\ndeps.{name} = {name}",
        )
    native_regression = (ROOT / "tests/ProjectileApplyPassRegression.luau").read_text()
    native_regression = native_regression.replace(
        "local P = require(game.ServerScriptService.Server.Projectile.ApplyPass)",
        "local P = ApplyPass",
    )
    source += "\ndo\n" + native_regression + "\nend\n"
    with tempfile.TemporaryDirectory(prefix="projectile-regression-") as scratch:
        fixture = Path(scratch) / "regression.luau"
        fixture.write_text(source)
        subprocess.run([str(ROOT / "logs/luau/luau.exe"), str(fixture)], check=True)


if __name__ == "__main__":
    main()
