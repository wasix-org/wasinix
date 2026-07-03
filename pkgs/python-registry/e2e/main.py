"""End-to-end exercise of a python project installed from the static registry.

Run under wasmer by tests.nix (e2e-project) with PYTHONPATH pointing at a
`pip install --target` tree resolved from the registry. All checks run even
after a failure; E2E_ALL_OK is only printed if every one passed.
"""

import sys
import traceback

CHECKS = []


def check(fn):
    CHECKS.append(fn)
    return fn


@check
def stdlib():
    import asyncio
    import hashlib
    import os
    import tempfile

    assert (
        hashlib.sha256(b"wasix").hexdigest()
        == "b3aa2e295c5b1a5215bbb520f7dc33b20773cf7d08f659f441ee13fef67bb1b4"
    )

    async def seven():
        await asyncio.sleep(0)
        return 7

    assert asyncio.run(seven()) == 7

    path = os.path.join(tempfile.mkdtemp(), "roundtrip.txt")
    with open(path, "w") as f:
        f.write("wasix file io")
    with open(path) as f:
        assert f.read() == "wasix file io"


@check
def tzdata_zoneinfo():
    # The shipped python webc bakes a tzpath (selfMounts); the tzdata wheel must
    # still resolve and import, as the fallback when no tzpath is mounted.
    # Winter dates, so DST can't flake the conversions.
    import importlib.util
    from datetime import datetime, timezone
    from zoneinfo import ZoneInfo

    assert importlib.util.find_spec("tzdata") is not None

    noon_utc = datetime(2024, 1, 15, 12, 0, tzinfo=timezone.utc)
    assert noon_utc.astimezone(ZoneInfo("Europe/Berlin")).hour == 13
    assert noon_utc.astimezone(ZoneInfo("America/New_York")).hour == 7


@check
def numpy_math():
    import numpy as np

    rng = np.random.default_rng(42)
    a = rng.random((16, 16)) + 16 * np.eye(16)
    b = rng.random(16)
    x = np.linalg.solve(a, b)
    assert np.allclose(a @ x, b)

    signal = rng.random(64)
    assert np.allclose(np.fft.ifft(np.fft.fft(signal)).real, signal)


@check
def pandas_frames():
    import os
    import tempfile

    import pandas as pd

    df = pd.DataFrame({"g": list("aabb"), "v": [1, 2, 3, 4]})
    assert df.groupby("g")["v"].sum().to_dict() == {"a": 3, "b": 7}

    merged = df.merge(pd.DataFrame({"g": ["a", "b"], "w": [10, 20]}), on="g")
    assert merged["w"].tolist() == [10, 10, 20, 20]

    path = os.path.join(tempfile.mkdtemp(), "df.csv")
    df.to_csv(path, index=False)
    pd.testing.assert_frame_equal(pd.read_csv(path), df)


@check
def requests_offline():
    # No network (and no _ssl) in the guest: exercise the request-building
    # machinery, which still walks urllib3/idna/charset-normalizer.
    from requests import Request
    from requests.cookies import RequestsCookieJar

    prepared = Request(
        "POST",
        "https://example.invalid/search",
        params={"q": "wasix registry"},
        data={"page": "1"},
        headers={"X-Test": "e2e"},
    ).prepare()
    assert prepared.url == "https://example.invalid/search?q=wasix+registry"
    assert prepared.body == "page=1"
    assert prepared.headers["Content-Type"] == "application/x-www-form-urlencoded"
    assert prepared.headers["X-Test"] == "e2e"

    jar = RequestsCookieJar()
    jar.set("session", "tok123", domain="example.invalid", path="/")
    assert jar.get("session", domain="example.invalid") == "tok123"


@check
def markupsafe_escape():
    from markupsafe import Markup, escape

    assert str(escape('<b> & "quoted"')) == "&lt;b&gt; &amp; &#34;quoted&#34;"
    assert escape(Markup("<b>safe</b>")) == Markup("<b>safe</b>")


@check
def cryptography_fernet():
    from cryptography.fernet import Fernet, InvalidToken
    from cryptography.hazmat.primitives import hashes

    f = Fernet(Fernet.generate_key())
    token = f.encrypt(b"registry e2e secret")
    assert f.decrypt(token) == b"registry e2e secret"

    # a tampered token must be rejected, not decrypted to garbage
    tampered = bytearray(token)
    tampered[-1] ^= 0x01
    try:
        f.decrypt(bytes(tampered))
    except InvalidToken:
        pass
    else:
        raise AssertionError("tampered Fernet token was accepted")

    # cross-check the rust digest against stdlib hashlib
    import hashlib

    h = hashes.Hash(hashes.SHA256())
    h.update(b"wasix")
    assert h.finalize() == hashlib.sha256(b"wasix").digest()


@check
def orjson_roundtrip():
    import numpy as np
    import orjson

    doc = {"name": "wasix", "tags": ["wasm", "posix"], "nested": {"n": 42, "f": 1.5}}
    assert orjson.loads(orjson.dumps(doc)) == doc

    arr = np.arange(12, dtype=np.float64).reshape(3, 4)
    dumped = orjson.dumps({"m": arr}, option=orjson.OPT_SERIALIZE_NUMPY)
    assert orjson.loads(dumped)["m"] == arr.tolist()


@check
def pillow_png():
    import os
    import tempfile

    import numpy as np
    from PIL import Image

    # numpy -> PIL -> PNG on disk (zlib at work) -> PIL -> numpy, bit-exact
    rgb = np.zeros((32, 64, 3), dtype=np.uint8)
    rgb[..., 0] = np.arange(64, dtype=np.uint8) * 4
    rgb[..., 1] = np.arange(32, dtype=np.uint8)[:, None] * 8
    path = os.path.join(tempfile.mkdtemp(), "gradient.png")
    Image.fromarray(rgb).save(path)
    with Image.open(path) as reread:
        assert reread.size == (64, 32)
        assert np.array_equal(np.asarray(reread), rgb)


@check
def lxml_xpath_xslt():
    from lxml import etree

    root = etree.fromstring('<r><a x="1">one</a><a x="2">two</a></r>')
    assert [e.get("x") for e in root.xpath("//a")] == ["1", "2"]
    assert root.xpath("string(//a[@x='2'])") == "two"

    # a transform proves libxslt is linked and alive, not just libxml2
    xslt = etree.XSLT(
        etree.fromstring(
            '<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform">'
            '<xsl:template match="/"><got><xsl:value-of select="count(//a)"/></got></xsl:template>'
            "</xsl:stylesheet>"
        )
    )
    assert etree.tostring(xslt(root)) == b"<got>2</got>"


@check
def cross_package_chain():
    # pandas -> orjson -> cryptography -> orjson -> pandas/numpy: one payload
    # through four packages and back, compared for equality at the end.
    import numpy as np
    import orjson
    import pandas as pd
    from cryptography.fernet import Fernet

    df = pd.DataFrame({"pkg": ["numpy", "pandas", "orjson"], "tier": [1, 2, 3]})
    payload = orjson.dumps(
        {"records": df.to_dict("records"), "matrix": np.eye(3)},
        option=orjson.OPT_SERIALIZE_NUMPY,
    )
    f = Fernet(Fernet.generate_key())
    restored = orjson.loads(f.decrypt(f.encrypt(payload)))
    pd.testing.assert_frame_equal(pd.DataFrame(restored["records"]), df)
    assert np.array_equal(np.array(restored["matrix"]), np.eye(3))


def main():
    failed = 0
    for fn in CHECKS:
        try:
            fn()
        except Exception:
            failed += 1
            print(f"E2E_FAIL {fn.__name__}", flush=True)
            traceback.print_exc()
        else:
            print(f"E2E_OK {fn.__name__}", flush=True)
    if failed:
        sys.exit(f"{failed}/{len(CHECKS)} e2e checks failed")
    print(f"E2E_ALL_OK {len(CHECKS)} checks", flush=True)


if __name__ == "__main__":
    main()
