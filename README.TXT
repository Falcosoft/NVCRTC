NVCRTC 1.0
==========

NVCRTC is a pair of DOS utilities that restores VBE 3.0 custom refresh-rate
control on NVIDIA GeForce 6 and GeForce 7 series video cards (NV4x/Curie)
whose video BIOS reports the feature but does not actually apply the requested
CRTC timing.

The package contains two versions:

  NVCRTC.COM  - for plain real-mode DOS.
  NVCRTCD.COM - for V86 environments such as JEMM386/JEMMEX with a resident
                32-bit DPMI host such as HDPMI32.


COMMON BEHAVIOR
---------------

Both versions fix the same standard VBE 3.0 interface. Programs that already
use VBE 3.0 custom CRTC mode setting can use the fix directly. Older VBE 1.x
or 2.x programs can also benefit when a utility such as UniRefresh intercepts
their mode changes and issues VBE 3.0 refresh requests for them.

NVCRTC/NVCRTCD does not add new VESA resolutions. The requested resolution
must already exist in the video BIOS mode list. The utilities only apply
custom timing and refresh-rate information to that mode.

Current scope:

  - NVIDIA GeForce 6/7 series cards (NV4x/Curie chipsets in the 40h..4Fh
    family).
  - Analog VGA output and CRT displays.
  - Standard VBE 3.0 custom CRTC requests through INT 10h Function 4F02h.
  - Direct VBE 3.0 applications and UniRefresh-style compatibility for older
    VBE programs.

Only use refresh rates and timings that are safe for the connected monitor.
Digital DVI/HDMI output is outside the scope of these utilities.

Do not load NVCRTC and NVCRTCD at the same time. Choose the version that
matches the DOS environment.

Using UniRefresh
----------------

Load NVCRTC or NVCRTCD BEFORE UniRefresh:

  NVCRTC
  UNIRFRSH

or in a V86/DPMI environment:

  NVCRTCD
  UNIRFRSH


NVCRTC - PLAIN REAL-MODE DOS
----------------------------

Use NVCRTC when EMM386/JEMM386 is not active and DOS is running in normal
real mode. HIMEM/XMS must be available when NVCRTC is installed.

Install:

  NVCRTC

Show detailed status:

  NVCRTC /S

Unload:

  NVCRTC /U

NVCRTC can be physically unloaded, but it must still be the newest handler on
the interrupts it uses. If UniRefresh or another TSR was loaded after NVCRTC,
unload that later TSR first.


NVCRTCD - JEMM386/JEMMEX + HDPMI32
----------------------------------

Use NVCRTCD when a V86 memory manager is active. It requires a resident 32-bit
DPMI host. The intended setup is JEMM386/JEMMEX together with HDPMI32.

A typical startup order is:

  JEMMEX.EXE
  HDPMI32.EXE -R
  JEMMEX.EXE NOVCPI
  NVCRTCD

The exact JEMM configuration may differ on individual systems. The important
point is that the 32-bit DPMI host must already be resident before NVCRTCD
starts.

Install, or show the short resident state if already installed:

  NVCRTCD

Show detailed status:

  NVCRTCD /S

Temporarily disable correction:

  NVCRTCD /D

or:

  NVCRTCD /U

For NVCRTCD, /U is intentionally the same as /D: it disables correction but
does not physically remove the resident DPMI client. A reboot is required for
complete removal.

Re-enable correction:

  NVCRTCD /E

Show command help:

  NVCRTCD /?


CHOOSING THE CORRECT VERSION
----------------------------

Use NVCRTC for plain DOS without EMM386/JEMM386. Use NVCRTCD when
JEMM386/JEMMEX or another V86 environment is active and HDPMI32 is available.


BUILDING FROM SOURCE
--------------------

The sources are written for Borland TASM/TLINK. BUILD.BAT builds both versions.
Equivalent commands are:

  TASM /m9 NVCRTC.ASM
  TLINK /t NVCRTC.OBJ
  TASM /m9 NVCRTCD.ASM
  TLINK /t NVCRTCD.OBJ

The resulting files are NVCRTC.COM and NVCRTCD.COM.


LICENSE
-------

NVCRTC is released under the MIT License. See LICENSE.
