#!/usr/bin/env python3
"""Sparkle EdDSA (Ed25519) keys and signatures, with the standard library only.

  sparkle_ed.py generate <private-key-file>        new throwaway key pair (CI's packaging dry run);
                                                   writes the private key, prints the public key
  sparkle_ed.py public-key <private-key-file|->    the public key (SUPublicEDKey) for a private key
  sparkle_ed.py verify <file> <signature> <public-key>
                                                   checks a sparkle:edSignature against SUPublicEDKey

Keys use Sparkle's format: the private key is the base64 32-byte seed that `generate_keys -x`
exports (the older 96-byte form is read too), the public key is base64 of 32 bytes. Signatures
come from Sparkle's own `sign_update`; this file only verifies them, so a release can't publish an
update that copies of Ladle would refuse. Ed25519 follows RFC 8032's reference implementation.
"""

import base64
import hashlib
import os
import sys

P = 2**255 - 19
Q = 2**252 + 27742317777372353535851937790883648493
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)


def _inv(x):
    return pow(x, P - 2, P)


def _add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    e = (y1 - x1) * (y2 - x2) % P
    f = (y1 + x1) * (y2 + x2) % P
    g = 2 * t1 * t2 * D % P
    h = 2 * z1 * z2 % P
    e, f, g, h = f - e, h - g, h + g, f + e
    return (e * f % P, g * h % P, f * g % P, e * h % P)


def _mul(scalar, point):
    result = (0, 1, 1, 0)
    while scalar > 0:
        if scalar & 1:
            result = _add(result, point)
        point = _add(point, point)
        scalar >>= 1
    return result


def _equal(a, b):
    return (a[0] * b[2] - b[0] * a[2]) % P == 0 and (a[1] * b[2] - b[1] * a[2]) % P == 0


def _recover_x(y, sign):
    if y >= P:
        return None
    x2 = (y * y - 1) * _inv(D * y * y + 1) % P
    if x2 == 0:
        return None if sign else 0
    x = pow(x2, (P + 3) // 8, P)
    if (x * x - x2) % P != 0:
        x = x * SQRT_M1 % P
    if (x * x - x2) % P != 0:
        return None
    if (x & 1) != sign:
        x = P - x
    return x


_GY = 4 * _inv(5) % P
_GX = _recover_x(_GY, 0)
G = (_GX, _GY, 1, _GX * _GY % P)


def _compress(point):
    zinv = _inv(point[2])
    x = point[0] * zinv % P
    y = point[1] * zinv % P
    return int.to_bytes(y | ((x & 1) << 255), 32, "little")


def _decompress(data):
    if len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    x = _recover_x(y, sign)
    if x is None:
        return None
    return (x, y, 1, x * y % P)


def _expand(seed):
    digest = hashlib.sha512(seed).digest()
    a = int.from_bytes(digest[:32], "little")
    a &= (1 << 254) - 8
    a |= 1 << 254
    return a, digest[32:]


def public_key(seed):
    """The 32-byte public key for a 32-byte seed."""
    if len(seed) != 32:
        raise ValueError("an Ed25519 seed is 32 bytes")
    return _compress(_mul(_expand(seed)[0], G))


def sign(seed, message):
    """Signs bytes. Used by the tests; releases are signed with Sparkle's sign_update."""
    a, prefix = _expand(seed)
    public = _compress(_mul(a, G))
    r = int.from_bytes(hashlib.sha512(prefix + message).digest(), "little") % Q
    encoded_r = _compress(_mul(r, G))
    h = int.from_bytes(hashlib.sha512(encoded_r + public + message).digest(), "little") % Q
    return encoded_r + int.to_bytes((r + h * a) % Q, 32, "little")


def verify_chunks(public, chunks, signature):
    """Verifies a signature over the concatenation of `chunks` (so files needn't fit in memory)."""
    if len(public) != 32 or len(signature) != 64:
        return False
    a = _decompress(public)
    r = _decompress(signature[:32])
    if a is None or r is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= Q:
        return False
    hasher = hashlib.sha512(signature[:32] + public)
    for chunk in chunks:
        hasher.update(chunk)
    h = int.from_bytes(hasher.digest(), "little") % Q
    return _equal(_mul(s, G), _add(r, _mul(h, a)))


def verify(public, message, signature):
    return verify_chunks(public, [message], signature)


def _file_chunks(path):
    with open(path, "rb") as handle:
        while True:
            chunk = handle.read(1 << 20)
            if not chunk:
                return
            yield chunk


def decode_private_key(text):
    """The seed from Sparkle's private key text (base64 of 32 bytes)."""
    data = base64.b64decode(text.strip(), validate=True)
    if len(data) == 32:
        return data
    raise ValueError("expected Sparkle's base64 private key (32 bytes once decoded), got %d bytes" % len(data))


def decode_public_key(text):
    data = base64.b64decode(text.strip(), validate=True)
    if len(data) != 32:
        raise ValueError("SUPublicEDKey must be base64 of 32 bytes, got %d bytes" % len(data))
    return data


def _read(path):
    if path == "-":
        return sys.stdin.read()
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "generate":
            seed = os.urandom(32)
            descriptor = os.open(argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as handle:
                handle.write(base64.b64encode(seed).decode() + "\n")
            print(base64.b64encode(public_key(seed)).decode())
            return 0
        if len(argv) == 2 and argv[0] == "public-key":
            text = _read(argv[1])
            if len(base64.b64decode(text.strip(), validate=True)) == 96:
                # Sparkle's older keys: private key followed by the public key.
                print(base64.b64encode(base64.b64decode(text.strip())[64:]).decode())
            else:
                print(base64.b64encode(public_key(decode_private_key(text))).decode())
            return 0
        if len(argv) == 4 and argv[0] == "verify":
            signature = base64.b64decode(argv[2].strip(), validate=True)
            public = decode_public_key(argv[3])
            if verify_chunks(public, _file_chunks(argv[1]), signature):
                print("EdDSA signature verified with %s" % argv[3].strip())
                return 0
            print("error: the EdDSA signature doesn't match %s with that public key" % argv[1], file=sys.stderr)
            return 1
    except (OSError, ValueError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
