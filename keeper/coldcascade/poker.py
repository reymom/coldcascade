"""BookCache.poke() on a cadence. The fallback read path if nested STATICCALL fails, and the
Booked series the markouts need either way. Anyone can run this — poke is permissionless.

**The running implementation is `script/poke-cadence.sh`**, on a one-minute cron. It is a shell
script rather than this module because it has to survive cron's PATH, share a send lock with the
other two cadences, and fall back from the poster's keystore to the taker's; none of that is
Python's to do. These functions are the in-process version and are not what is writing the series.
"""

from .chain import Deployment


def poke_once(dep: Deployment, perp_index: int, account: str, dry_run: bool = True) -> str | None:
    raise NotImplementedError("todo")


def run(dep: Deployment, perp_index: int, account: str, interval_s: int) -> None:
    raise NotImplementedError("todo")
