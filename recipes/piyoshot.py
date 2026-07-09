"""Recipe for PiyoShot — binpatch distribution.

Patches the PiyoShogi main executable so that every PiyoShot hook site
BL's into a ``__TEXT`` cave that calls the dylib through
``g_piyoshot_hook_slot[N]``. The dylib gets injected via ``LC_LOAD_DYLIB``
so dyld loads it on app launch and ``BinpatchEntries.m``'s constructor
publishes each hook function pointer into its slot.

How the patch chain works (IPA-Patch shared binpatch shape):

  1. Add an ``LC_LOAD_DYLIB`` pointing at
     ``@executable_path/Frameworks/PiyoShot.dylib`` so dyld
     auto-loads the dylib on app launch.

  2. Reserve a ``PIYOSHOT_SLOT_COUNT``-entry table in ``__DATA,__bss``.
     The dylib constructor fills each slot with the right ``hook_*``
     function pointer. Writing to ``__DATA`` is CSM-safe on iOS 18.

  3. For every site listed in ``_SITES`` (one per ``PIYOSHOT_SLOT_*``
     enum), replace the prologue's first 4 bytes with ``B <cave>``.

  4. Each cave preserves caller registers, materialises the slot
     address into X16, loads the published hook function pointer,
     loads the slot index into W9, BLR's the pointer, restores
     registers, executes the displaced prologue instruction verbatim,
     then branches to ``orig + 4``.

Consumed by ``python3 -m tools.patch_macho --recipe recipes.piyoshot
<PiyoShogi>`` (driven from the Makefile's ``binpatch::`` / ``ipa::``
targets).

STATUS — TBD FIELDS
-------------------
Two constants below are placeholders (marked ``TBD`` in comments):
``CAVE_REGION`` and ``HOOK_SLOT_BASE_RVA``. Both need to be re-derived
against the decrypted PiyoShogi Mach-O before ``make ipa`` will
produce a runnable IPA. The two known ``_SITES`` (validator + parseSFEN)
have real RVAs and captured prologues; the layout of __TEXT / __bss on
PiyoShogi 5.7.5 (build 199) has not been walked yet.
"""

from __future__ import annotations

from tools.encode import (
    adrp,
    b_imm,
    blr_x,
    ldp_post_x,
    ldr_x_imm,
    movz_w_imm,
    ret_insn,
    stp_pre_x,
)

# arm64 NOP (HINT #0). encode.py does not export a helper for it because
# only this recipe needs it (for cave-payload padding); inline the encoding.
_NOP = b"\x1f\x20\x03\xd5"


# ---------------------------------------------------------------------------
# Target identification
# ---------------------------------------------------------------------------

TARGET_BASENAME = "PiyoShogi"
DYLIB_PATH = "@executable_path/Frameworks/PiyoShot.dylib"


# ---------------------------------------------------------------------------
# Code-cave region.
#
# PiyoShogi 5.7.5 (build 199) __TEXT ends at file offset 0xd20000, and
# the last real __TEXT section (``__oslogstring``) reaches only to
# 0xd1c00e. The 16368 bytes at [0xd1c010, 0xd20000) are zero-fill inside
# the same r-x mapping, so they are safe to populate with arm64 cave
# payloads and branch into without any segment edits.
#
# Sizing: PiyoShot currently defines 2 slots (validator + parseSFEN),
# 84 B per cave, so 168 B are needed. Plenty of headroom left for
# future hooks.
# ---------------------------------------------------------------------------

CAVE_REGION = (0xd1c010, 0xd20000)  # (start, end exclusive) — 16368 B available


# ---------------------------------------------------------------------------
# Hook slot base.
#
# 2 * 8-byte slots packed against the tail of __bss. PiyoShogi's __bss
# spans RVA [0xf52540, 0xfb6510); we place the slot table at
# 0xfb6510 - 2 * 8 = 0xfb6500.
#
# ``shared/tools/machoops.py::assert_slot_in_bss`` fires at patch time
# if this RVA is not inside the live binary's __bss range.
#
# Cave N does:
#
#     ADRP X16, page(SLOT_BASE + N*8)
#     LDR  X16, [X16, #lo12(SLOT_BASE + N*8)]
#     MOVZ W9,  #N
#     BLR  X16
#
# to dispatch through the slot.
# ---------------------------------------------------------------------------

PIYOSHOT_SLOT_COUNT = 2
HOOK_SLOT_BASE_RVA = 0xfb6500  # __bss tail on PiyoShogi 5.7.5 (build 199)


# ---------------------------------------------------------------------------
# Cave payload builder.
#
# Cave shape (21 insns = 84 B). Identical wall-clock cost regardless of
# slot index, so the same shape lands at every site for byte-level
# inspectability. ``PIYOSHOT_BINPATCH_CAVE_PAYLOAD_SIZE`` in
# ``Sources/PiyoShot/binpatch_sites.h`` is pinned to this number; if you
# change the shape, update the header too.
#
# The cave splits into three regions:
#
#   [cave .. cave+0x20)     : hook-entry trampoline (8 insns, see below)
#   [cave+0x20 .. cave+0x4C) : NOP padding (11 insns)
#   [cave+0x4C .. cave+0x54) : orig trampoline (2 insns)
#
# Hook-entry trampoline (replaces the site's first 4 B with `B <cave>`):
#
#     STP  X29, X30, [SP, #-0x10]!   ; save LR. X0..X7 (orig's args) untouched.
#     ADRP X16, page(SLOT_BASE + N*8)
#     LDR  X16, [X16, #lo12(SLOT_BASE + N*8)]
#     MOVZ W9,  #N                   ; slot index in W9 (callee may ignore)
#     BLR  X16                       ; X0 = hook(orig's args...) -> returned to caller
#     LDP  X29, X30, [SP], #0x10
#     RET                            ; hook's X0 propagates to the original caller
#     NOP                            ; one NOP completes the 8-insn entry block
#
# The hook function gets called with the same X0..X7 the caller passed
# to orig and its return value (X0) propagates straight back through
# RET — so a hook returning ``1`` for ``validator`` actually changes what
# the call site sees.
#
# Orig trampoline (callable via ``piyoshot_resolve_orig_trampoline``):
#
#     <displaced prologue insn>      ; cave + (PAYLOAD_SIZE - 8). Verbatim
#                                    ; orig[0]; must be PC-independent.
#     B    <orig + 4>                ; cave + (PAYLOAD_SIZE - 4). Resumes orig.
#
# A hook body that wants to chain back calls ``orig_X(args)`` against
# this 8-byte trampoline; the displaced insn runs once, then B reaches
# orig's second instruction.
# ---------------------------------------------------------------------------

CAVE_PAYLOAD_SIZE = 84  # 21 instructions

# Layout constants — keep these in sync with the diagram above.
_ENTRY_INSNS = 8
_TAIL_BYTES = 8  # displaced insn + B<orig+4>
_PAD_INSNS = (CAVE_PAYLOAD_SIZE - _ENTRY_INSNS * 4 - _TAIL_BYTES) // 4  # 11


def _build_entry_cave_payload(
    orig_va: int, slot_va: int, displaced_insn: bytes, slot_index: int
):
    """Return a ``build_payload(cave_va) -> bytes`` closure for one site.

    Parameters
    ----------
    orig_va : int
        File offset (== VA, since __TEXT starts at 0 in this Mach-O) of
        the prologue instruction that will be replaced with
        ``B <cave_va>``. The orig trampoline in the cave's tail
        branches back to ``orig_va + 4`` after executing the displaced
        prologue insn locally.
    slot_va : int
        VA of the 8-byte __bss slot for this site (SLOT_BASE +
        slot_index * 8). The dylib constructor publishes the hook
        function pointer here.
    displaced_insn : bytes
        The 4 prologue bytes about to be overwritten. Must be
        PC-independent (STP pre-index, SUB SP, LDR offset, MOV reg).
        Re-derive with ``xxd -s <orig_va> -l 4 <PiyoShogi>``
        against a clean PiyoShogi 5.7.5 (build 199) binary.
    slot_index : int
        ``PIYOSHOT_SLOT_*`` enum value. Loaded into W9 before BLR per the
        convention in ``Sources/PiyoShot/binpatch_sites.h``. Hooks that do
        not consume X9 ignore it.
    """
    if len(displaced_insn) != 4:
        raise ValueError(
            f"displaced_insn must be exactly 4 bytes; got {len(displaced_insn)}"
        )
    if not (0 <= slot_index < PIYOSHOT_SLOT_COUNT):
        raise ValueError(f"slot_index out of range: {slot_index}")

    def build(cave_va: int) -> bytes:
        out = bytearray()
        cur = cave_va

        def emit(insn: bytes) -> None:
            nonlocal cur
            out.extend(insn)
            cur += 4

        # --- entry trampoline (8 insns) ---
        # Save only LR; X0..X7 carry orig's args verbatim into the hook.
        emit(stp_pre_x(29, 30, 31, -0x10))
        # Materialize SLOT address; load published hook pointer.
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))
        # Pass slot index in W9 (callee may ignore).
        emit(movz_w_imm(9, slot_index))
        # Hand off — hook returns whatever it wants in X0; we propagate it.
        emit(blr_x(16))
        emit(ldp_post_x(29, 30, 31, 0x10))
        emit(ret_insn())
        # Round up to _ENTRY_INSNS for a clean boundary.
        emit(_NOP)

        # --- padding (never executed; RET above always returns) ---
        for _ in range(_PAD_INSNS):
            emit(_NOP)

        # --- orig trampoline at cave + (PAYLOAD_SIZE - 8) ---
        emit(displaced_insn)
        emit(b_imm(cur, orig_va + 4))

        if len(out) != CAVE_PAYLOAD_SIZE:
            raise AssertionError(
                f"cave payload wrong size: got {len(out)}, expected {CAVE_PAYLOAD_SIZE}"
            )
        return bytes(out)

    return build


# ---------------------------------------------------------------------------
# Site table.
#
# One row per PIYOSHOT_SLOT_* enum value in
# ``Sources/PiyoShot/binpatch_sites.h``. Slot indices MUST match the header's
# enum (the dylib publishes into ``g_piyoshot_hook_slot[index]`` from the
# same header, so any drift goes silently wrong at runtime).
#
# Columns:
#   slot_index     — PIYOSHOT_SLOT_* value (header)
#   site_off       — file offset of the prologue's first 4 bytes
#                    (== VA since __TEXT starts at 0)
#   prologue_hex   — expected 4-byte prologue, lowercase hex, little-endian.
#                    REQUIRED for caves.apply_patches() to verify the
#                    site is virgin before patching. Re-derive with
#                      xxd -s <site_off> -l 4 <PiyoShogi>
#                    against a clean PiyoShogi 5.7.5 (build 199) binary.
#   label          — short human-readable name for logs
#
# The prologue requirements:
#   - exactly 4 bytes
#   - PC-independent: STP pre-index, SUB SP, MOV, etc.  PC-relative
#     instructions (ADR, ADRP, B, BL, CBZ, LDR literal) WILL break when
#     relocated into the cave. Both known sites (validator, parseSFEN)
#     have been verified PC-independent below.
# ---------------------------------------------------------------------------

# Slot-index constants mirrored from Sources/PiyoShot/binpatch_sites.h. Kept
# inline so the recipe is self-contained for static analysis tooling.
PIYOSHOT_SLOT_VALIDATOR = 0
PIYOSHOT_SLOT_PARSE_SFEN = 1

# (slot_index, site_off, expected_prologue_hex, label)
#
# Prologues captured from clean PiyoShogi 5.7.5 (build 199) executable
# (assets/PiyoShogi-5.7.5.ipa, 2026-07-08).
#
#   validator @ 0x41270 : SUB SP, SP, #0x50  (PC-independent)
#   parseSFEN @ 0x43704 : STP X28, X27, [SP, #-0x60]!  (PC-independent)
_SITES: list[tuple[int, int, str, str]] = [
    (PIYOSHOT_SLOT_VALIDATOR,  0x41270, "ff4301d1", "validator"),
    (PIYOSHOT_SLOT_PARSE_SFEN, 0x43704, "fc6fbaa9", "parseSFEN"),
]


def _validate_sites() -> None:
    """Sanity-check the site table at recipe load time."""
    if len(_SITES) != PIYOSHOT_SLOT_COUNT:
        raise AssertionError(
            f"_SITES must have {PIYOSHOT_SLOT_COUNT} rows; got {len(_SITES)}"
        )
    slots_seen: set[int] = set()
    offs_seen: set[int] = set()
    for slot, off, prologue_hex, label in _SITES:
        if slot in slots_seen:
            raise AssertionError(f"duplicate slot index {slot} ({label})")
        if off in offs_seen:
            raise AssertionError(f"duplicate site offset 0x{off:X} ({label})")
        slots_seen.add(slot)
        offs_seen.add(off)
        if len(prologue_hex) != 8:
            raise AssertionError(
                f"prologue hex for {label} must be 8 chars (4 B), got "
                f"{len(prologue_hex)}: {prologue_hex!r}"
            )
        try:
            bytes.fromhex(prologue_hex)
        except ValueError as e:
            raise AssertionError(
                f"prologue hex for {label} is not valid hex: {prologue_hex!r}"
            ) from e


_validate_sites()


# ---------------------------------------------------------------------------
# PATCHES — inline single-instruction replacements.
#
# All PiyoShot behaviour change is hook-driven; no inline byte rewrites
# needed.
# ---------------------------------------------------------------------------

PATCHES: list = []


# ---------------------------------------------------------------------------
# CAVE_PATCHES — one entry per site, each redirected to its own cave.
# ---------------------------------------------------------------------------

CAVE_PATCHES: list = [
    (
        site_off,
        bytes.fromhex(prologue_hex),
        _build_entry_cave_payload(
            orig_va=site_off,
            slot_va=HOOK_SLOT_BASE_RVA + slot_index * 8,
            displaced_insn=bytes.fromhex(prologue_hex),
            slot_index=slot_index,
        ),
        f"slot[{slot_index:>2}] {label}",
    )
    for slot_index, site_off, prologue_hex, label in _SITES
]


# ---------------------------------------------------------------------------
# Info.plist additions for sandbox-Documents visibility through Files.app.
#
# The patched IPA pipeline reads this dict and writes each key into the
# bundle's Info.plist. Setting both flags is what makes
# "On My iPhone -> PiyoShogi" expose the sandbox so the operator can pull
# ``piyo_captures/*.png`` and ``piyocap.log`` off the device.
# ---------------------------------------------------------------------------

PLIST_KEYS: dict = {
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
}
