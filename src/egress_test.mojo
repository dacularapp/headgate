"""egress-test — prove the EgressGuard actually blocks. `pixi run egress-test`.

The guard is headgate's confidentiality chokepoint. This is the test that makes
"confidential" true rather than nominal: a clean payload passes, but a payload
carrying a real-data fingerprint OR a canary token is blocked (the guard raises,
so transport aborts the send).
"""

from egress import EgressGuard


def _blocks(guard: EgressGuard, payload: String) -> Bool:
    try:
        _ = guard.check(payload)
        return False
    except:
        return True


def main() raises:
    var fps = List[String]()
    fps.append(String("123-45-6789"))        # a real SSN-shaped value
    fps.append(String("alice@example.com"))  # a real email value
    var canaries = List[String]()
    canaries.append(String("HG_CANARY_7f3a"))  # seeded ONLY into real data
    var guard = EgressGuard(fps^, canaries^)

    var all_ok = True

    var clean_passes = not _blocks(guard, String("Aggregate col_1 grouped by col_0."))
    print("[" + ("PASS" if clean_passes else "FAIL") + "] clean payload passes")
    all_ok = all_ok and clean_passes

    var fp_blocked = _blocks(guard, String("debug: offending row was 123-45-6789"))
    print("[" + ("PASS" if fp_blocked else "FAIL") + "] real-value fingerprint blocked")
    all_ok = all_ok and fp_blocked

    var canary_blocked = _blocks(guard, String("stack trace mentions HG_CANARY_7f3a here"))
    print("[" + ("PASS" if canary_blocked else "FAIL") + "] canary token blocked")
    all_ok = all_ok and canary_blocked

    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("egress-test: the guard failed to block a leak")
