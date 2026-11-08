; NVCRTC.ASM - NVIDIA NV4x VBE 3.0 custom CRTC compatibility TSR
; Version 1.0
;
; Repairs VBE 3.0 custom CRTC mode setting on NVIDIA NV4x/Curie BIOSes
; that advertise the interface but do not apply the requested timing.
;
; The original video BIOS still performs the normal VBE mode setup.  For a
; successful AX=4F02h request with BX bit 11 set, NVCRTC applies the supplied
; CRTCInfoBlock to the active analog VGA CRTC and VPLL.
;
; Intended for plain real-mode DOS.  Load before UniRefresh or another TSR
; that issues VBE 3.0 custom CRTC requests.
;
; Build:
;   TASM /m9 NVCRTC.ASM
;   TLINK /t NVCRTC.OBJ
;
; Commands:
;   NVCRTC       install
;   NVCRTC /S    show resident status
;   NVCRTC /U    unload (later INT 10h/INT 2Fh TSRs must be removed first)
;
; Requirements:
;   - 80386+
;   - plain real-mode DOS
;   - HIMEM/XMS available during installation
;   - NVIDIA NV4x/Curie chipset 40h..4Fh
;   - analog VGA output
;
.model tiny
.386p
.code
org 100h

; Real-mode protected-MMIO selector constants and instruction encodings.

SEL_CODE16 equ 08h
SEL_DATA16 equ 10h
SEL_FLAT   equ 18h

MMIO_READ_EAX_ESI macro
        db      067h,066h,08Bh,006h      ; mov eax,[esi]
endm

MMIO_WRITE_EAX_ESI macro
        db      067h,066h,089h,006h      ; mov [esi],eax
endm

NV_VENDOR               equ 10DEh
PCI_CLASS_VGA           equ 00030000h

PMC_BOOT0               equ 00000000h
PEXTDEV_BOOT0           equ 00101000h
PLL_COEFF_SELECT        equ 0068050Ch
VPLL0_COEFF             equ 00680508h
VPLL1_COEFF             equ 00680520h
VPLL0_COEFF_B           equ 00680578h
VPLL1_COEFF_B           equ 0068057Ch
PRAMDAC_DACCLK_A        equ 0068052Ch

VBE_MODE_MASK           equ 01FFh
VBE_CUSTOM_CRTC         equ 0800h

VBE_MI_ATTR             equ 00h
VBE_MI_XRES             equ 12h
VBE_MI_YRES             equ 14h
VBE_MI_MAXCLOCK         equ 3Eh

CRTCF_DBLSCAN           equ 01h
CRTCF_INTERLACE         equ 02h
CRTCF_NHSYNC            equ 04h
CRTCF_NVSYNC            equ 08h

; Extended NVIDIA CRTC registers used by Nouveau's NV04/NV4x mode builder.
NV_CIO_SR_LOCK          equ 1Fh
NV_CIO_SR_UNLOCK        equ 57h
NV_CIO_SR_LOCKED        equ 99h
NV_CIO_CRE_LSR          equ 25h
NV_CIO_CRE_HEB          equ 2Dh
NV_CIO_CRE_ILACE        equ 39h
NV_CIO_CRE_EBR          equ 41h
NV_CIO_CRE_OWNER        equ 44h

; INT 2Fh multiplex IDs.  Kept distinct from ASPECT's FEC0/FEC1 pair.
MUX_PRESENT             equ 0FEC4h
MUX_PRESENT_REPLY       equ 0C4FEh
MUX_INFO                equ 0FEC5h
MUX_INFO_REPLY          equ 0C5FEh

; LastResult values printed by /S.
RES_NONE                equ 0
RES_APPLIED             equ 1
RES_BIOS_FAILED         equ 2
RES_VM86                equ 3
RES_MODEINFO            equ 4
RES_MODE_UNSUPPORTED    equ 5
RES_BAD_TIMING          equ 6
RES_PLL_FAILED          equ 7

start:
        mov ax,cs
        mov ds,ax
        mov es,ax

        call GetCommand
        cmp al,'U'
        je Uninstall
        cmp al,'S'
        je ShowStatus

        mov dx,offset MsgTitle
        call PrintZ

        ; Refuse a second installation.
        mov ax,MUX_PRESENT
        int 2Fh
        cmp ax,MUX_PRESENT_REPLY
        je AlreadyInstalled

        ; PCI BIOS presence.
        mov ax,0B101h
        int 1Ah
        jc NoPci
        cmp edx,20494350h              ; 'PCI '
        jne NoPci

        call FindNvidiaVga
        jc NoDevice

        ; PCI memory decode must be enabled.
        mov ax,0B109h
        mov bx,[PciBdf]
        mov di,04h
        int 1Ah
        jc PciFail
        test cl,02h
        jz NoMemDecode

        ; Read BAR0.
        mov ax,0B10Ah
        mov bx,[PciBdf]
        mov di,10h
        int 1Ah
        jc PciFail
        test cl,01h
        jnz BadBar
        mov eax,ecx
        and eax,0FFFFFFF0h
        test eax,eax
        jz BadBar
        cmp eax,0FFFFFFF0h
        je BadBar
        mov [MmioBase],eax

        ; Require VBE 3.0.
        mov ax,cs
        mov es,ax
        mov di,offset VbeInfo
        mov ax,4F00h
        int 10h
        push ax
        push cs
        pop ds
        push cs
        pop es
        pop ax
        cmp ax,004Fh
        jne NoVbe3
        cmp word ptr [VbeInfo+4],0300h
        jb NoVbe3

        ; ASPECT convention: XMS global A20 enable once at installation.
        mov ax,4300h
        int 2Fh
        cmp al,80h
        jne NoXms
        mov ax,4310h
        int 2Fh
        mov word ptr [XmsEntry],bx
        mov word ptr [XmsEntry+2],es
        push ds
        pop es
        mov ah,03h
        call dword ptr cs:[XmsEntry]
        or ax,ax
        jz A20Fail

        call PrepareProtectedMode
        call ReadNvBasicsForeground
        call DecodeNv4x
        jc NotNv4x
        call DetectCrystal

        ; Save resident environment block for safe /U cleanup.
        mov ax,word ptr cs:[2Ch]
        mov [ResidentEnvironment],ax

        ; Save old vectors.
        mov ax,3510h
        int 21h
        mov word ptr [OldInt10],bx
        mov word ptr [OldInt10+2],es

        mov ax,352Fh
        int 21h
        mov word ptr [OldInt2F],bx
        mov word ptr [OldInt2F+2],es

        ; Install INT 10h and INT 2Fh hooks.
        push ds
        mov ax,cs
        mov ds,ax
        mov dx,offset NewInt10
        mov ax,2510h
        int 21h
        mov dx,offset NewInt2F
        mov ax,252Fh
        int 21h
        pop ds

        call PrintInstallInfo
        mov dx,offset MsgInstalled
        call PrintZ

        mov dx,offset ResidentEnd
        add dx,15
        mov cl,4
        shr dx,cl
        mov ax,3100h
        int 21h

AlreadyInstalled:
        mov dx,offset MsgAlready
        call PrintZ
        mov ax,4C01h
        int 21h
NoPci:
        mov dx,offset MsgNoPci
        jmp ExitError
NoDevice:
        mov dx,offset MsgNoDevice
        jmp ExitError
PciFail:
        mov dx,offset MsgPciFail
        jmp ExitError
NoMemDecode:
        mov dx,offset MsgNoMemDecode
        jmp ExitError
BadBar:
        mov dx,offset MsgBadBar
        jmp ExitError
NoVbe3:
        mov dx,offset MsgNoVbe3
        jmp ExitError
NoXms:
        mov dx,offset MsgNoXms
        jmp ExitError
A20Fail:
        mov dx,offset MsgA20Fail
        jmp ExitError
NotNv4x:
        mov ah,04h
        call dword ptr cs:[XmsEntry]
        mov dx,offset MsgNotNv4x
ExitError:
        call PrintZ
        mov ax,4C01h
        int 21h

; ----------------------------------------------------------------------
; /S - resident status.
; ----------------------------------------------------------------------
ShowStatus:
        mov dx,offset MsgTitle
        call PrintZ
        mov ax,MUX_INFO
        int 2Fh
        cmp ax,MUX_INFO_REPLY
        jne StatusNotInstalled

        mov dx,offset MsgStatusHeader
        call PrintZ

        mov dx,offset MsgBar
        call PrintZ
        mov eax,dword ptr es:[di+RI_BAR]
        call PrintHex32
        call PrintCRLF

        mov dx,offset MsgChipset
        call PrintZ
        mov al,byte ptr es:[di+RI_CHIPSET]
        call PrintHex8
        call PrintCRLF

        mov dx,offset MsgCrystal
        call PrintZ
        mov eax,dword ptr es:[di+RI_CRYSTAL]
        call PrintDec32
        mov dx,offset MsgKHz
        call PrintZ

        mov dx,offset MsgReqCount
        call PrintZ
        mov ax,word ptr es:[di+RI_REQUESTS]
        call PrintDec16
        call PrintCRLF

        mov dx,offset MsgAppliedCount
        call PrintZ
        mov ax,word ptr es:[di+RI_APPLIED]
        call PrintDec16
        call PrintCRLF

        mov dx,offset MsgFailedCount
        call PrintZ
        mov ax,word ptr es:[di+RI_FAILED]
        call PrintDec16
        call PrintCRLF

        mov dx,offset MsgLastBx
        call PrintZ
        mov ax,word ptr es:[di+RI_LASTBX]
        call PrintHex16
        call PrintCRLF

        mov dx,offset MsgLastBios
        call PrintZ
        mov ax,word ptr es:[di+RI_LASTBIOS]
        call PrintHex16
        call PrintCRLF

        mov dx,offset MsgLastResult
        call PrintZ
        mov al,byte ptr es:[di+RI_LASTRESULT]
        call PrintHex8
        call PrintCRLF

        mov dx,offset MsgLastHead
        call PrintZ
        mov al,byte ptr es:[di+RI_LASTHEAD]
        call PrintHex8
        call PrintCRLF

        mov dx,offset MsgLastH
        call PrintZ
        mov ax,word ptr es:[di+RI_HTOTAL]
        call PrintDec16
        mov dl,'/'
        call PutCh
        mov ax,word ptr es:[di+RI_HSTART]
        call PrintDec16
        mov dl,'/'
        call PutCh
        mov ax,word ptr es:[di+RI_HEND]
        call PrintDec16
        call PrintCRLF

        mov dx,offset MsgLastV
        call PrintZ
        mov ax,word ptr es:[di+RI_VTOTAL]
        call PrintDec16
        mov dl,'/'
        call PutCh
        mov ax,word ptr es:[di+RI_VSTART]
        call PrintDec16
        mov dl,'/'
        call PutCh
        mov ax,word ptr es:[di+RI_VEND]
        call PrintDec16
        call PrintCRLF

        mov dx,offset MsgLastFlags
        call PrintZ
        mov al,byte ptr es:[di+RI_CRTCFLAGS]
        call PrintHex8
        call PrintCRLF

        mov dx,offset MsgLastPixel
        call PrintZ
        mov eax,dword ptr es:[di+RI_PIXELCLOCK]
        call PrintDec32
        mov dx,offset MsgHz
        call PrintZ

        mov dx,offset MsgLastReqRefresh
        call PrintZ
        movzx eax,word ptr es:[di+RI_REFRESH]
        call PrintRefresh100
        mov dx,offset MsgHz
        call PrintZ

        mov dx,offset MsgLastActRefresh
        call PrintZ
        mov eax,dword ptr es:[di+RI_ACTREFRESH]
        call PrintRefresh100
        mov dx,offset MsgHz
        call PrintZ

        mov dx,offset MsgLastClock
        call PrintZ
        mov eax,dword ptr es:[di+RI_ACTUALKHZ]
        call PrintDec32
        mov dx,offset MsgKHz
        call PrintZ

        mov ax,4C00h
        int 21h
StatusNotInstalled:
        mov dx,offset MsgNotInstalled
        call PrintZ
        mov ax,4C01h
        int 21h

; ----------------------------------------------------------------------
; /U - safe removal.  UniRefresh (or another later INT 10h hook) must be
; unloaded first, otherwise vector restoration would break the chain.
; ----------------------------------------------------------------------
Uninstall:
        mov dx,offset MsgTitle
        call PrintZ

        mov ax,MUX_INFO
        int 2Fh
        cmp ax,MUX_INFO_REPLY
        jne UninstallNotInstalled

        mov ax,es
        mov [ResidentSegment],ax

        mov ax,word ptr es:[di+RI_OLD10]
        mov word ptr [SavedOldInt10],ax
        mov ax,word ptr es:[di+RI_OLD10+2]
        mov word ptr [SavedOldInt10+2],ax
        mov ax,word ptr es:[di+RI_OLD2F]
        mov word ptr [SavedOldInt2F],ax
        mov ax,word ptr es:[di+RI_OLD2F+2]
        mov word ptr [SavedOldInt2F+2],ax
        mov ax,word ptr es:[di+RI_XMS]
        mov word ptr [SavedXmsEntry],ax
        mov ax,word ptr es:[di+RI_XMS+2]
        mov word ptr [SavedXmsEntry+2],ax
        mov ax,word ptr es:[di+RI_ENV]
        mov [SavedEnvironment],ax

        mov ax,3510h
        int 21h
        cmp bx,offset NewInt10
        jne UninstallUnsafe
        mov ax,es
        cmp ax,[ResidentSegment]
        jne UninstallUnsafe

        mov ax,352Fh
        int 21h
        cmp bx,offset NewInt2F
        jne UninstallUnsafe
        mov ax,es
        cmp ax,[ResidentSegment]
        jne UninstallUnsafe

        push ds
        mov ax,word ptr [SavedOldInt10+2]
        mov ds,ax
        mov dx,word ptr cs:[SavedOldInt10]
        mov ax,2510h
        int 21h
        pop ds

        push ds
        mov ax,word ptr [SavedOldInt2F+2]
        mov ds,ax
        mov dx,word ptr cs:[SavedOldInt2F]
        mov ax,252Fh
        int 21h
        pop ds

        mov ah,04h
        call dword ptr cs:[SavedXmsEntry]

        mov ax,[SavedEnvironment]
        or ax,ax
        jz UninstallFreePsp
        mov es,ax
        mov ah,49h
        int 21h

UninstallFreePsp:
        mov ax,[ResidentSegment]
        mov es,ax
        mov ah,49h
        int 21h
        jc UninstallFreeFailed

        mov dx,offset MsgUninstalled
        call PrintZ
        mov ax,4C00h
        int 21h

UninstallNotInstalled:
        mov dx,offset MsgNotInstalled
        call PrintZ
        mov ax,4C01h
        int 21h
UninstallUnsafe:
        mov dx,offset MsgUnsafeUnload
        call PrintZ
        mov ax,4C01h
        int 21h
UninstallFreeFailed:
        mov dx,offset MsgFreeFailed
        call PrintZ
        mov ax,4C01h
        int 21h

; ----------------------------------------------------------------------
; INT 2Fh multiplex API.
; ----------------------------------------------------------------------
NewInt2F proc far
        cmp ax,MUX_PRESENT
        je MuxPresent
        cmp ax,MUX_INFO
        je MuxInfo
        jmp dword ptr cs:[OldInt2F]
MuxPresent:
        mov ax,MUX_PRESENT_REPLY
        iret
MuxInfo:
        mov ax,MUX_INFO_REPLY
        push cs
        pop es
        mov di,offset ResidentInfo
        iret
NewInt2F endp

; ----------------------------------------------------------------------
; INT 10h hook.
; Only standard VBE 3.0 custom-CRTC mode-set requests are modified.
; Everything else chains directly to the previous handler.
; ----------------------------------------------------------------------
NewInt10 proc far
        cmp ax,4F02h
        jne HookChain
        test bx,VBE_CUSTOM_CRTC
        jz HookChain

        ; Copy the 19-byte meaningful CRTCInfoBlock and BX before calling the
        ; NVIDIA BIOS.  Preserve every caller register/flag for the BIOS call.
        pushfd
        pushad
        push ds
        push es
        push fs
        push gs

        mov word ptr cs:[LastBx],bx
        mov ax,word ptr es:[di+00h]
        mov word ptr cs:[LastHTotal],ax
        mov ax,word ptr es:[di+02h]
        mov word ptr cs:[LastHStart],ax
        mov ax,word ptr es:[di+04h]
        mov word ptr cs:[LastHEnd],ax
        mov ax,word ptr es:[di+06h]
        mov word ptr cs:[LastVTotal],ax
        mov ax,word ptr es:[di+08h]
        mov word ptr cs:[LastVStart],ax
        mov ax,word ptr es:[di+0Ah]
        mov word ptr cs:[LastVEnd],ax
        mov al,byte ptr es:[di+0Ch]
        mov byte ptr cs:[LastCrtcFlags],al
        mov eax,dword ptr es:[di+0Dh]
        mov dword ptr cs:[LastPixelClock],eax
        mov ax,word ptr es:[di+11h]
        mov word ptr cs:[LastRefresh],ax
        inc word ptr cs:[RequestCount]
        mov byte ptr cs:[ForceFail],0
        mov byte ptr cs:[LastResult],RES_NONE
        mov byte ptr cs:[LastHead],0FFh
        mov dword ptr cs:[LastActualKHz],0
        mov dword ptr cs:[LastActualRefresh],0

        pop gs
        pop fs
        pop es
        pop ds
        popad
        popfd

        ; Let NVIDIA's BIOS perform all normal mode setup first.
        pushf
        call dword ptr cs:[OldInt10]
        mov word ptr cs:[LastBiosAx],ax

        ; Preserve the complete BIOS return state while doing our repair.
        pushfd
        pushad
        push ds
        push es
        push fs
        push gs

        cmp ax,004Fh
        jne HookBiosFailed

        ; The real-mode version does not attempt privileged protected-mode
        ; transitions if invoked in V86 mode.
        pushfd
        pop eax
        test eax,00020000h
        jnz HookVm86

        cmp byte ptr cs:[Busy],0
        jne HookRestore
        mov byte ptr cs:[Busy],1

        call ApplyCustomFromHook
        jc HookApplyFailed

        inc word ptr cs:[AppliedCount]
        mov byte ptr cs:[LastResult],RES_APPLIED
        jmp short HookClearBusy

HookApplyFailed:
        inc word ptr cs:[FailedCount]
        mov byte ptr cs:[ForceFail],1
HookClearBusy:
        mov byte ptr cs:[Busy],0
        jmp short HookRestore

HookBiosFailed:
        mov byte ptr cs:[LastResult],RES_BIOS_FAILED
        inc word ptr cs:[FailedCount]
        jmp short HookRestore

HookVm86:
        mov byte ptr cs:[LastResult],RES_VM86
        inc word ptr cs:[FailedCount]
        mov byte ptr cs:[ForceFail],1

HookRestore:
        pop gs
        pop fs
        pop es
        pop ds
        popad
        popfd
        cmp byte ptr cs:[ForceFail],0
        je HookIret
        mov ax,014Fh                    ; VBE call failed
HookIret:
        iret

HookChain:
        jmp dword ptr cs:[OldInt10]
NewInt10 endp

; ----------------------------------------------------------------------
; Hook wrapper: use a resident stack before BIOS helper calls and protected
; mode transitions.  Caller return state is already saved on caller's stack.
; ----------------------------------------------------------------------
ApplyCustomFromHook proc near
        mov ax,ss
        mov word ptr cs:[CallerSS],ax
        mov word ptr cs:[CallerSP],sp

        cli
        mov ax,cs
        mov ss,ax
        mov sp,offset LocalStackTop
        ; Keep interrupts disabled exactly as ASPECT does inside INT 10h.

        call ApplyCustomCore
        mov byte ptr cs:[CoreCarry],0
        jnc AcfhRestore
        mov byte ptr cs:[CoreCarry],1

AcfhRestore:
        cli
        mov ax,word ptr cs:[CallerSS]
        mov ss,ax
        mov sp,word ptr cs:[CallerSP]
        cmp byte ptr cs:[CoreCarry],0
        jne AcfhFail
        clc
        ret
AcfhFail:
        stc
        ret
ApplyCustomFromHook endp

; ----------------------------------------------------------------------
; Full custom CRTC repair path.
; ----------------------------------------------------------------------
ApplyCustomCore proc near
        ; Query base mode information through the original BIOS.
        mov ax,cs
        mov es,ax
        mov di,offset ModeInfo
        mov cx,word ptr cs:[LastBx]
        and cx,VBE_MODE_MASK
        mov ax,4F01h
        pushf
        call dword ptr cs:[OldInt10]
        cmp ax,004Fh
        jne AccModeInfoFail

        call ValidateAndBuildTiming
        jc AccFail

        ; Read routing + current PLL state after the BIOS mode set.  The BIOS's
        ; default mode is close to the requested refresh, so preserving its
        ; second VPLL stage is both safer and more portable across NV4x parts.
        call ReadNvBasicsCore
        call SelectActivePll
        mov al,byte ptr cs:[ActiveHead]
        mov byte ptr cs:[LastHead],al

        mov eax,dword ptr cs:[LastPixelClock]
        add eax,500
        xor edx,edx
        mov ebx,1000
        div ebx
        mov dword ptr cs:[TargetClockKHz],eax

        call CalcTargetPll
        jc AccPllFail

        call ProgramCrtcTiming
        call WriteActiveVpll
        mov eax,dword ptr cs:[BestClockKHz]
        mov dword ptr cs:[LastActualKHz],eax

        ; Actual vertical frequency in 0.01 Hz units:
        ;   clock_kHz * 100000 / (HTotal_pixels * VTotal_lines)
        mov ebx,100000
        mul ebx                         ; EDX:EAX = 64-bit numerator
        movzx ebx,word ptr cs:[LastHTotal]
        movzx ecx,word ptr cs:[LastVTotal]
        imul ebx,ecx
        test ebx,ebx
        jz AccRefreshZero
        div ebx
        mov dword ptr cs:[LastActualRefresh],eax
        jmp short AccRefreshDone
AccRefreshZero:
        mov dword ptr cs:[LastActualRefresh],0
AccRefreshDone:
        clc
        ret

AccModeInfoFail:
        mov byte ptr cs:[LastResult],RES_MODEINFO
        stc
        ret
AccPllFail:
        mov byte ptr cs:[LastResult],RES_PLL_FAILED
AccFail:
        stc
        ret
ApplyCustomCore endp

; ----------------------------------------------------------------------
; Validate CRTCInfoBlock against the actual mode and derive VGA/NVIDIA CRTC
; counter values.  The VBE block uses pixels/lines; horizontal hardware values
; use 8-pixel character clocks.
; ----------------------------------------------------------------------
ValidateAndBuildTiming proc near
        pushad

        mov ax,word ptr cs:[ModeInfo+VBE_MI_ATTR]
        test ax,0001h                    ; mode available
        jz VbtUnsupported
        test ax,0010h                    ; graphics mode
        jz VbtUnsupported
        test ax,0020h                    ; D5=1 means NOT VGA compatible
        jnz VbtUnsupported

        mov al,byte ptr cs:[LastCrtcFlags]
        test al,0F0h
        jnz VbtBad

        ; Respect VBE mode capability bits for doublescan/interlace.
        test al,CRTCF_DBLSCAN
        jz VbtNoDblCheck
        test word ptr cs:[ModeInfo+VBE_MI_ATTR],0100h
        jz VbtUnsupported
VbtNoDblCheck:
        test al,CRTCF_INTERLACE
        jz VbtNoIntCheck
        test word ptr cs:[ModeInfo+VBE_MI_ATTR],0200h
        jz VbtUnsupported
VbtNoIntCheck:

        mov ax,word ptr cs:[ModeInfo+VBE_MI_XRES]
        mov word ptr cs:[ModeX],ax
        mov ax,word ptr cs:[ModeInfo+VBE_MI_YRES]
        mov word ptr cs:[ModeY],ax
        cmp word ptr cs:[ModeX],0
        je VbtBad
        cmp word ptr cs:[ModeY],0
        je VbtBad

        ; NV04/NV4x VGA timing generator is character-clock based horizontally.
        mov ax,word ptr cs:[ModeX]
        test ax,7
        jnz VbtBad
        mov ax,word ptr cs:[LastHTotal]
        test ax,7
        jnz VbtBad
        mov ax,word ptr cs:[LastHStart]
        test ax,7
        jnz VbtBad
        mov ax,word ptr cs:[LastHEnd]
        test ax,7
        jnz VbtBad

        ; Basic horizontal ordering.
        mov ax,word ptr cs:[ModeX]
        cmp word ptr cs:[LastHStart],ax
        jb VbtBad
        mov ax,word ptr cs:[LastHStart]
        cmp word ptr cs:[LastHEnd],ax
        jbe VbtBad
        mov ax,word ptr cs:[LastHEnd]
        cmp word ptr cs:[LastHTotal],ax
        jbe VbtBad

        ; Effective displayed vertical lines.  VBE doublescan timings are
        ; normalized to twice the logical resolution.
        mov ax,word ptr cs:[ModeY]
        test byte ptr cs:[LastCrtcFlags],CRTCF_DBLSCAN
        jz VbtDisplayReady
        shl ax,1
        jc VbtBad
VbtDisplayReady:
        mov word ptr cs:[EffectiveY],ax
        cmp word ptr cs:[LastVStart],ax
        jb VbtBad
        mov ax,word ptr cs:[LastVStart]
        cmp word ptr cs:[LastVEnd],ax
        jbe VbtBad
        mov ax,word ptr cs:[LastVEnd]
        cmp word ptr cs:[LastVTotal],ax
        jbe VbtBad

        ; Hardware counter ranges: horizontal 9-bit extended values, vertical
        ; 12-bit extended values.
        mov ax,word ptr cs:[LastHTotal]
        shr ax,3
        cmp ax,516                       ; (HTotal/8 - 5) <= 511
        ja VbtBad
        mov ax,word ptr cs:[ModeX]
        shr ax,3
        cmp ax,512
        ja VbtBad
        mov ax,word ptr cs:[LastHStart]
        shr ax,3
        inc ax
        cmp ax,511
        ja VbtBad

        cmp word ptr cs:[LastVTotal],4097 ; VTotal-2 <= 4095
        ja VbtBad
        cmp word ptr cs:[EffectiveY],4096
        ja VbtBad
        cmp word ptr cs:[LastVStart],4096
        ja VbtBad

        mov eax,dword ptr cs:[LastPixelClock]
        test eax,eax
        jz VbtBad
        cmp eax,10000000                 ; conservative 10 MHz floor
        jb VbtBad
        cmp eax,400000000                ; conservative NV4x analog ceiling
        ja VbtBad
        mov edx,dword ptr cs:[ModeInfo+VBE_MI_MAXCLOCK]
        test edx,edx
        jz VbtClockOk
        cmp eax,edx
        ja VbtBad
VbtClockOk:

        ; Horizontal derived counters.
        mov ax,word ptr cs:[ModeX]
        shr ax,3
        dec ax
        mov word ptr cs:[HDisplay],ax
        mov word ptr cs:[HBlankStart],ax

        mov ax,word ptr cs:[LastHStart]
        shr ax,3
        inc ax
        mov word ptr cs:[HSyncStart],ax

        mov ax,word ptr cs:[LastHEnd]
        shr ax,3
        inc ax
        mov word ptr cs:[HSyncEnd],ax

        mov ax,word ptr cs:[LastHTotal]
        shr ax,3
        mov bx,ax
        sub ax,5
        mov word ptr cs:[HTotalCount],ax
        mov ax,bx
        dec ax
        mov word ptr cs:[HBlankEnd],ax

        ; Vertical derived counters.
        mov ax,word ptr cs:[EffectiveY]
        dec ax
        mov word ptr cs:[VDisplay],ax
        mov word ptr cs:[VBlankStart],ax

        mov ax,word ptr cs:[LastVStart]
        dec ax
        mov word ptr cs:[VSyncStart],ax
        mov ax,word ptr cs:[LastVEnd]
        dec ax
        mov word ptr cs:[VSyncEnd],ax
        mov ax,word ptr cs:[LastVTotal]
        sub ax,2
        test byte ptr cs:[LastCrtcFlags],CRTCF_INTERLACE
        jz VbtNoOddInterlace
        or ax,1
VbtNoOddInterlace:
        mov word ptr cs:[VTotalCount],ax
        mov ax,word ptr cs:[LastVTotal]
        dec ax
        mov word ptr cs:[VBlankEnd],ax

        popad
        clc
        ret

VbtUnsupported:
        mov byte ptr cs:[LastResult],RES_MODE_UNSUPPORTED
        popad
        stc
        ret
VbtBad:
        mov byte ptr cs:[LastResult],RES_BAD_TIMING
        popad
        stc
        ret
ValidateAndBuildTiming endp

; ----------------------------------------------------------------------
; Program standard VGA timing registers plus NV extended overflow bits.
; The BIOS already configured framebuffer format/pitch/arbitration for the
; requested resolution, so those unrelated registers are intentionally left
; untouched.
; ----------------------------------------------------------------------
ProgramCrtcTiming proc near
        pushad

        call GetCrtcPort

        ; Unlock NVIDIA extended CRTC registers globally.
        mov al,NV_CIO_SR_LOCK
        call ReadCrtcReg
        mov byte ptr cs:[SavedExtLock],al
        mov ax,571Fh
        call WriteCrtcReg

        ; Save CR44 and select the CRTC feeding analog DAC A.
        mov al,NV_CIO_CRE_OWNER
        call ReadCrtcReg
        mov byte ptr cs:[SavedOwner],al
        mov ah,0
        cmp byte ptr cs:[ActiveHead],0
        je PctOwnerReady
        mov ah,3
PctOwnerReady:
        mov al,NV_CIO_CRE_OWNER
        call WriteCrtcReg

        ; Screen off while timing/PLL state is inconsistent.
        mov dx,03C4h
        mov al,01h
        out dx,al
        inc dx
        in al,dx
        mov byte ptr cs:[SavedSeq1],al
        or al,20h
        out dx,al

        call GetCrtcPort

        ; Unlock standard VGA CRTC 00h..07h.
        mov al,11h
        call ReadCrtcReg
        mov byte ptr cs:[SavedCr11],al
        and al,7Fh
        mov ah,al
        mov al,11h
        call WriteCrtcReg

        ; Sync polarity: preserve miscellaneous non-polarity bits.
        mov dx,03CCh
        in al,dx
        and al,3Fh
        test byte ptr cs:[LastCrtcFlags],CRTCF_NHSYNC
        jz PctNoNH
        or al,40h
PctNoNH:
        test byte ptr cs:[LastCrtcFlags],CRTCF_NVSYNC
        jz PctNoNV
        or al,80h
PctNoNV:
        mov dx,03C2h
        out dx,al

        call GetCrtcPort

        ; Standard horizontal CRTC.
        mov ax,word ptr cs:[HTotalCount]
        mov ah,al
        mov al,00h
        call WriteCrtcReg
        mov ax,word ptr cs:[HDisplay]
        mov ah,al
        mov al,01h
        call WriteCrtcReg
        mov ax,word ptr cs:[HBlankStart]
        mov ah,al
        mov al,02h
        call WriteCrtcReg

        mov ax,word ptr cs:[HBlankEnd]
        and al,1Fh
        or al,80h
        mov ah,al
        mov al,03h
        call WriteCrtcReg

        mov ax,word ptr cs:[HSyncStart]
        mov ah,al
        mov al,04h
        call WriteCrtcReg

        mov bx,word ptr cs:[HBlankEnd]
        mov ax,word ptr cs:[HSyncEnd]
        and al,1Fh
        test bx,0020h
        jz PctHbe5Done
        or al,80h
PctHbe5Done:
        mov ah,al
        mov al,05h
        call WriteCrtcReg

        ; Standard vertical CRTC.
        mov ax,word ptr cs:[VTotalCount]
        mov ah,al
        mov al,06h
        call WriteCrtcReg

        xor bx,bx
        ; CR07: VTotal8,VDisplay8,VSync8,VBlank8,bit4=1,VTotal9,VDisplay9,VSync9
        test word ptr cs:[VTotalCount],0100h
        jz PctOv1
        or bl,01h
PctOv1:
        test word ptr cs:[VDisplay],0100h
        jz PctOv2
        or bl,02h
PctOv2:
        test word ptr cs:[VSyncStart],0100h
        jz PctOv3
        or bl,04h
PctOv3:
        test word ptr cs:[VBlankStart],0100h
        jz PctOv4
        or bl,08h
PctOv4:
        or bl,10h
        test word ptr cs:[VTotalCount],0200h
        jz PctOv5
        or bl,20h
PctOv5:
        test word ptr cs:[VDisplay],0200h
        jz PctOv6
        or bl,40h
PctOv6:
        test word ptr cs:[VSyncStart],0200h
        jz PctOv7
        or bl,80h
PctOv7:
        mov ah,bl
        mov al,07h
        call WriteCrtcReg

        ; CR09: bit6 retained as conventional VGA line-scan value, bit5 VBS9,
        ; bit7 doublescan according to VBE CRTC flag.
        mov bl,40h
        test word ptr cs:[VBlankStart],0200h
        jz PctCr09NoVbs9
        or bl,20h
PctCr09NoVbs9:
        test byte ptr cs:[LastCrtcFlags],CRTCF_DBLSCAN
        jz PctCr09NoDbl
        or bl,80h
PctCr09NoDbl:
        mov ah,bl
        mov al,09h
        call WriteCrtcReg

        mov ax,word ptr cs:[VSyncStart]
        mov ah,al
        mov al,10h
        call WriteCrtcReg

        mov ax,word ptr cs:[VDisplay]
        mov ah,al
        mov al,12h
        call WriteCrtcReg

        mov ax,word ptr cs:[VBlankStart]
        mov ah,al
        mov al,15h
        call WriteCrtcReg

        mov ax,word ptr cs:[VBlankEnd]
        mov ah,al
        mov al,16h
        call WriteCrtcReg

        ; CR11 low nibble = VSyncEnd.  Preserve BIOS high nibble/lock policy.
        mov ah,byte ptr cs:[SavedCr11]
        and ah,0F0h
        mov al,byte ptr cs:[VSyncEnd]
        and al,0Fh
        or ah,al
        mov al,11h
        call WriteCrtcReg

        ; NVIDIA CR25: VTotal10,VDisplay10,VSync10,VBlank10,HBlankEnd6.
        xor bl,bl
        test word ptr cs:[VTotalCount],0400h
        jz Pct25a
        or bl,01h
Pct25a:
        test word ptr cs:[VDisplay],0400h
        jz Pct25b
        or bl,02h
Pct25b:
        test word ptr cs:[VSyncStart],0400h
        jz Pct25c
        or bl,04h
Pct25c:
        test word ptr cs:[VBlankStart],0400h
        jz Pct25d
        or bl,08h
Pct25d:
        test word ptr cs:[HBlankEnd],0040h
        jz Pct25e
        or bl,10h
Pct25e:
        mov ah,bl
        mov al,NV_CIO_CRE_LSR
        call WriteCrtcReg

        ; NVIDIA CR2D: HTotal8,HDisplay8,HBlankStart8,HSyncStart8,
        ; plus interlace horizontal bit8 in bit4.
        xor bl,bl
        test word ptr cs:[HTotalCount],0100h
        jz Pct2da
        or bl,01h
Pct2da:
        test word ptr cs:[HDisplay],0100h
        jz Pct2db
        or bl,02h
Pct2db:
        test word ptr cs:[HBlankStart],0100h
        jz Pct2dc
        or bl,04h
Pct2dc:
        test word ptr cs:[HSyncStart],0100h
        jz Pct2dd
        or bl,08h
Pct2dd:
        mov word ptr cs:[InterlaceH],0
        test byte ptr cs:[LastCrtcFlags],CRTCF_INTERLACE
        jz Pct2dNoInt
        mov ax,word ptr cs:[HTotalCount]
        shr ax,1
        and ax,0FFFEh
        mov word ptr cs:[InterlaceH],ax
        test ax,0100h
        jz Pct2dNoInt
        or bl,10h
Pct2dNoInt:
        mov ah,bl
        mov al,NV_CIO_CRE_HEB
        call WriteCrtcReg

        ; NVIDIA CR41: vertical bit11 overflow.
        xor bl,bl
        test word ptr cs:[VTotalCount],0800h
        jz Pct41a
        or bl,01h
Pct41a:
        test word ptr cs:[VDisplay],0800h
        jz Pct41b
        or bl,04h
Pct41b:
        test word ptr cs:[VSyncStart],0800h
        jz Pct41c
        or bl,10h
Pct41c:
        test word ptr cs:[VBlankStart],0800h
        jz Pct41d
        or bl,40h
Pct41d:
        mov ah,bl
        mov al,NV_CIO_CRE_EBR
        call WriteCrtcReg

        ; NVIDIA CR39 interlace register.  FFh disables interlace.
        test byte ptr cs:[LastCrtcFlags],CRTCF_INTERLACE
        jz PctNoInterlace
        mov ax,word ptr cs:[InterlaceH]
        mov ah,al
        mov al,NV_CIO_CRE_ILACE
        call WriteCrtcReg
        jmp short PctInterlaceDone
PctNoInterlace:
        mov ax,0FF39h
        call WriteCrtcReg
PctInterlaceDone:

        ; Program the active VPLL only after all timing registers are ready.
        call WriteActiveVpll

        ; Restore owner selection before relocking extended registers.
        call GetCrtcPort
        mov ah,byte ptr cs:[SavedOwner]
        mov al,NV_CIO_CRE_OWNER
        call WriteCrtcReg

        cmp byte ptr cs:[SavedExtLock],0
        jne PctRestoreExtValue
        mov ax,991Fh
        call WriteCrtcReg
        jmp short PctExtRestored
PctRestoreExtValue:
        mov ah,byte ptr cs:[SavedExtLock]
        mov al,NV_CIO_SR_LOCK
        call WriteCrtcReg
PctExtRestored:

        ; Unblank with the exact BIOS sequencer value.
        mov dx,03C4h
        mov al,01h
        out dx,al
        inc dx
        mov al,byte ptr cs:[SavedSeq1]
        and al,0DFh
        out dx,al

        popad
        ret
ProgramCrtcTiming endp

; ----------------------------------------------------------------------
; Read NV4x registers required for routing/PLL calculations.
; ----------------------------------------------------------------------
ReadNvBasicsForeground proc near
        pushfd
        pushad
        push ds
        push es
        push fs
        push gs
        call ReadNvBasicsCore
        pop gs
        pop fs
        pop es
        pop ds
        popad
        popfd
        ret
ReadNvBasicsForeground endp

ReadNvBasicsCore proc near
        pushf
        pop word ptr cs:[SavedFlags]
        cli
        in al,70h
        mov byte ptr cs:[SavedPort70],al
        or al,80h
        out 70h,al

        lgdt fword ptr cs:[Gdtr]
        mov eax,cr0
        or al,1
        mov cr0,eax
        db 0EAh
        dw offset RnbPmEntry
        dw SEL_CODE16

RnbPmEntry:
        mov ax,SEL_DATA16
        mov ss,ax
        mov es,ax
        mov ax,SEL_FLAT
        mov ds,ax

        mov esi,dword ptr es:[MmioBase]
        MMIO_READ_EAX_ESI
        mov dword ptr es:[PmcBoot0],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,PEXTDEV_BOOT0
        MMIO_READ_EAX_ESI
        mov dword ptr es:[Pextdev0],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,PLL_COEFF_SELECT
        MMIO_READ_EAX_ESI
        mov dword ptr es:[PllSelect],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,VPLL0_COEFF
        MMIO_READ_EAX_ESI
        mov dword ptr es:[Vpll0],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,VPLL0_COEFF_B
        MMIO_READ_EAX_ESI
        mov dword ptr es:[Vpll0B],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,VPLL1_COEFF
        MMIO_READ_EAX_ESI
        mov dword ptr es:[Vpll1],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,VPLL1_COEFF_B
        MMIO_READ_EAX_ESI
        mov dword ptr es:[Vpll1B],eax

        mov esi,dword ptr es:[MmioBase]
        add esi,PRAMDAC_DACCLK_A
        MMIO_READ_EAX_ESI
        mov dword ptr es:[DacClkA],eax

        mov ax,SEL_DATA16
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov eax,cr0
        and al,0FEh
        mov cr0,eax
        db 0EAh
        dw offset RnbRmReturn
        dw 0000h
RnbReturnSegment equ ($-2)

RnbRmReturn:
        mov ax,cs
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov al,byte ptr cs:[SavedPort70]
        out 70h,al
        push word ptr cs:[SavedFlags]
        popf
        ret
ReadNvBasicsCore endp

DecodeNv4x proc near
        mov eax,dword ptr cs:[PmcBoot0]
        shr eax,20
        and al,0FFh
        mov byte ptr cs:[Chipset],al
        mov ah,al
        and ah,0F0h
        cmp ah,040h
        jne DnvBad
        clc
        ret
DnvBad:
        stc
        ret
DecodeNv4x endp

SelectActivePll proc near
        mov eax,dword ptr cs:[DacClkA]
        test eax,00000100h
        jnz SapHead1
        mov byte ptr cs:[ActiveHead],0
        mov eax,dword ptr cs:[Vpll0]
        mov dword ptr cs:[CurrentVpll],eax
        mov eax,dword ptr cs:[Vpll0B]
        mov dword ptr cs:[CurrentVpllB],eax
        mov dword ptr cs:[ActiveVpllOffset],VPLL0_COEFF
        mov dword ptr cs:[ActiveVpllBOffset],VPLL0_COEFF_B
        ret
SapHead1:
        mov byte ptr cs:[ActiveHead],1
        mov eax,dword ptr cs:[Vpll1]
        mov dword ptr cs:[CurrentVpll],eax
        mov eax,dword ptr cs:[Vpll1B]
        mov dword ptr cs:[CurrentVpllB],eax
        mov dword ptr cs:[ActiveVpllOffset],VPLL1_COEFF
        mov dword ptr cs:[ActiveVpllBOffset],VPLL1_COEFF_B
        ret
SelectActivePll endp

DetectCrystal proc near
        mov eax,dword ptr cs:[Pextdev0]
        test eax,00400000h
        jz DcNot27
        mov dword ptr cs:[CrystalKHz],27000
        ret
DcNot27:
        test eax,00000040h
        jz Dc135
        mov dword ptr cs:[CrystalKHz],14318
        ret
Dc135:
        mov dword ptr cs:[CrystalKHz],13500
        ret
DetectCrystal endp

; ----------------------------------------------------------------------
; Adaptive NV4x VPLL search.  The BIOS-programmed second stage is kept.
; Searches only first-stage
; M/N/P values for the requested pixel clock.
; ----------------------------------------------------------------------
CalcTargetPll proc near
        pushad

        mov dword ptr cs:[BestDelta],0FFFFFFFFh
        mov dword ptr cs:[BestPll],0
        mov dword ptr cs:[BestClockKHz],0

        mov eax,dword ptr cs:[CurrentVpllB]
        test eax,80000000h
        jz CtpSingle
        mov bl,al
        mov bh,ah
        test bl,bl
        jz CtpSingle
        test bh,bh
        jz CtpSingle
        mov byte ptr cs:[PllMB],bl
        mov byte ptr cs:[PllNB],bh
        mov byte ptr cs:[TwoStage],1
        jmp short CtpStart
CtpSingle:
        mov byte ptr cs:[PllMB],1
        mov byte ptr cs:[PllNB],1
        mov byte ptr cs:[TwoStage],0

CtpStart:
        mov byte ptr cs:[TmpP],0
CtpPLoop:
        mov word ptr cs:[TmpM],1
CtpMLoop:
        cmp byte ptr cs:[TwoStage],0
        je CtpNInitSingle
        mov word ptr cs:[TmpN],5
        jmp short CtpNLoop
CtpNInitSingle:
        mov word ptr cs:[TmpN],1

CtpNLoop:
        mov eax,dword ptr cs:[CrystalKHz]
        movzx ebx,word ptr cs:[TmpN]
        mul ebx
        movzx ebx,word ptr cs:[TmpM]
        xor edx,edx
        div ebx

        cmp byte ptr cs:[TwoStage],0
        je CtpHavePre
        movzx ebx,byte ptr cs:[PllNB]
        mul ebx
        movzx ebx,byte ptr cs:[PllMB]
        xor edx,edx
        div ebx

CtpHavePre:
        mov dword ptr cs:[TmpPreClock],eax
        cmp byte ptr cs:[TwoStage],0
        je CtpSingleRange
        cmp eax,400000
        jb CtpNextN
        cmp eax,1000000
        ja CtpNextN
        jmp short CtpPostDivide
CtpSingleRange:
        cmp eax,128000
        jb CtpNextN
        cmp eax,350000
        ja CtpNextN

CtpPostDivide:
        mov cl,byte ptr cs:[TmpP]
        shr eax,cl
        mov dword ptr cs:[TmpClock],eax

        mov edx,eax
        sub edx,dword ptr cs:[TargetClockKHz]
        jns CtpDeltaReady
        neg edx
CtpDeltaReady:
        cmp edx,dword ptr cs:[BestDelta]
        jae CtpNextN
        mov dword ptr cs:[BestDelta],edx
        mov dword ptr cs:[BestClockKHz],eax

        movzx eax,byte ptr cs:[TmpP]
        shl eax,16
        movzx edx,word ptr cs:[TmpN]
        shl edx,8
        or eax,edx
        movzx edx,word ptr cs:[TmpM]
        or eax,edx
        mov dword ptr cs:[BestPll],eax

CtpNextN:
        inc word ptr cs:[TmpN]
        cmp word ptr cs:[TmpN],255
        jbe CtpNLoop
        inc word ptr cs:[TmpM]
        cmp byte ptr cs:[TwoStage],0
        je CtpM14
        cmp word ptr cs:[TmpM],13
        jbe CtpMLoop
        jmp short CtpNextP
CtpM14:
        cmp word ptr cs:[TmpM],14
        jbe CtpMLoop
CtpNextP:
        inc byte ptr cs:[TmpP]
        cmp byte ptr cs:[TmpP],6
        jbe CtpPLoop

        cmp dword ptr cs:[BestPll],0
        je CtpFail
        cmp dword ptr cs:[BestDelta],500
        ja CtpFail
        popad
        clc
        ret
CtpFail:
        popad
        stc
        ret
CalcTargetPll endp

; ----------------------------------------------------------------------
; Active VPLL write through the resident protected-mode MMIO path.
; ----------------------------------------------------------------------
WriteActiveVpll proc near
        pushf
        pop word ptr cs:[SavedFlags]
        cli
        in al,70h
        mov byte ptr cs:[SavedPort70],al
        or al,80h
        out 70h,al

        lgdt fword ptr cs:[Gdtr]
        mov eax,cr0
        or al,1
        mov cr0,eax
        db 0EAh
        dw offset WavPmEntry
        dw SEL_CODE16

WavPmEntry:
        mov ax,SEL_DATA16
        mov ss,ax
        mov es,ax
        mov ax,SEL_FLAT
        mov ds,ax

        mov esi,dword ptr es:[MmioBase]
        add esi,PLL_COEFF_SELECT
        mov eax,dword ptr es:[PllSelect]
        MMIO_WRITE_EAX_ESI

        mov esi,dword ptr es:[MmioBase]
        add esi,dword ptr es:[ActiveVpllOffset]
        mov eax,dword ptr es:[BestPll]
        MMIO_WRITE_EAX_ESI

        mov esi,dword ptr es:[MmioBase]
        add esi,dword ptr es:[ActiveVpllBOffset]
        mov eax,dword ptr es:[CurrentVpllB]
        MMIO_WRITE_EAX_ESI

        mov ax,SEL_DATA16
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov eax,cr0
        and al,0FEh
        mov cr0,eax
        db 0EAh
        dw offset WavRmReturn
        dw 0000h
WavReturnSegment equ ($-2)

WavRmReturn:
        mov ax,cs
        mov ds,ax
        mov es,ax
        mov ss,ax
        mov al,byte ptr cs:[SavedPort70]
        out 70h,al
        push word ptr cs:[SavedFlags]
        popf
        ret
WriteActiveVpll endp

; ----------------------------------------------------------------------
; VGA indexed CRTC helpers.
; ----------------------------------------------------------------------
GetCrtcPort proc near
        push ax
        mov dx,03CCh
        in al,dx
        test al,01h
        jz GcpMono
        mov dx,03D4h
        pop ax
        ret
GcpMono:
        mov dx,03B4h
        pop ax
        ret
GetCrtcPort endp

ReadCrtcReg proc near
        out dx,al
        inc dx
        in al,dx
        dec dx
        ret
ReadCrtcReg endp

WriteCrtcReg proc near
        out dx,al
        inc dx
        mov al,ah
        out dx,al
        dec dx
        ret
WriteCrtcReg endp

; ----------------------------------------------------------------------
; Protected mode descriptor preparation.
; ----------------------------------------------------------------------
PrepareProtectedMode proc near
        push ax
        push bx
        push dx
        push eax

        xor eax,eax
        mov ax,cs
        shl eax,4
        mov bx,offset GdtCode16
        call SetDescriptorBase
        mov bx,offset GdtData16
        call SetDescriptorBase
        mov edx,eax
        xor eax,eax
        mov ax,offset GdtStart
        add eax,edx
        mov dword ptr [Gdtr+2],eax
        mov ax,cs
        mov word ptr cs:[RnbReturnSegment],ax
        mov word ptr cs:[WavReturnSegment],ax

        pop eax
        pop dx
        pop bx
        pop ax
        ret
PrepareProtectedMode endp

SetDescriptorBase proc near
        mov word ptr [bx+2],ax
        ror eax,16
        mov byte ptr [bx+4],al
        mov byte ptr [bx+7],ah
        ror eax,16
        ret
SetDescriptorBase endp

; ----------------------------------------------------------------------
; PCI discovery.
; ----------------------------------------------------------------------
FindNvidiaVga proc near
        push ax
        push bx
        push cx
        push dx
        push si
        push di
        push ecx

        xor si,si
FnvNext:
        mov ax,0B103h
        mov ecx,PCI_CLASS_VGA
        int 1Ah
        jc FnvFail
        mov [CandidateBdf],bx

        mov ax,0B10Ah
        mov bx,[CandidateBdf]
        xor di,di
        int 1Ah
        jc FnvAdvance
        cmp cx,NV_VENDOR
        jne FnvAdvance

        mov bx,[CandidateBdf]
        mov [PciBdf],bx
        mov [PciId],ecx
        clc
        jmp short FnvDone
FnvAdvance:
        inc si
        jmp FnvNext
FnvFail:
        stc
FnvDone:
        pop ecx
        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
FindNvidiaVga endp

; ----------------------------------------------------------------------
; Command parser: returns AL='U', 'S', or zero.
; ----------------------------------------------------------------------
GetCommand proc near
        xor ax,ax
        xor bx,bx
        mov bl,byte ptr cs:[80h]
        mov si,81h
GcSkip:
        cmp bx,0
        je GcNone
        mov al,byte ptr cs:[si]
        cmp al,' '
        je GcNext
        cmp al,9
        jne GcHave
GcNext:
        inc si
        dec bx
        jmp GcSkip
GcHave:
        cmp al,'/'
        jne GcNone
        inc si
        mov al,byte ptr cs:[si]
        and al,0DFh
        cmp al,'U'
        je GcDone
        cmp al,'S'
        je GcDone
GcNone:
        xor al,al
GcDone:
        ret
GetCommand endp

; ----------------------------------------------------------------------
; Foreground reports / DOS console helpers.
; ----------------------------------------------------------------------
PrintInstallInfo proc near
        mov dx,offset MsgPciBdf
        call PrintZ
        mov ax,[PciBdf]
        call PrintHex16
        call PrintCRLF
        mov dx,offset MsgPciId
        call PrintZ
        mov eax,[PciId]
        call PrintHex32
        call PrintCRLF
        mov dx,offset MsgBar
        call PrintZ
        mov eax,[MmioBase]
        call PrintHex32
        call PrintCRLF
        mov dx,offset MsgBoot0
        call PrintZ
        mov eax,[PmcBoot0]
        call PrintHex32
        call PrintCRLF
        mov dx,offset MsgChipset
        call PrintZ
        mov al,[Chipset]
        call PrintHex8
        call PrintCRLF
        mov dx,offset MsgCrystal
        call PrintZ
        mov eax,[CrystalKHz]
        call PrintDec32
        mov dx,offset MsgKHz
        call PrintZ
        ret
PrintInstallInfo endp

PrintZ proc near
        push ax
        push si
        mov si,dx
PzLoop:
        lodsb
        or al,al
        jz PzDone
        mov dl,al
        call PutCh
        jmp PzLoop
PzDone:
        pop si
        pop ax
        ret
PrintZ endp

PrintCRLF proc near
        mov dx,offset MsgCRLF
        call PrintZ
        ret
PrintCRLF endp

PutCh proc near
        push ax
        mov ah,02h
        int 21h
        pop ax
        ret
PutCh endp

PrintHex32 proc near
        push eax
        ror eax,16
        call PrintHex16
        ror eax,16
        call PrintHex16
        pop eax
        ret
PrintHex32 endp

PrintHex16 proc near
        push ax
        mov al,ah
        call PrintHex8
        pop ax
        call PrintHex8
        ret
PrintHex16 endp

PrintHex8 proc near
        push ax
        push bx
        mov bl,al
        mov al,bl
        shr al,4
        call PrintNibble
        mov al,bl
        and al,0Fh
        call PrintNibble
        pop bx
        pop ax
        ret
PrintHex8 endp

PrintNibble proc near
        and al,0Fh
        cmp al,9
        jbe PnDigit
        add al,'A'-10
        jmp short PnOut
PnDigit:
        add al,'0'
PnOut:
        mov dl,al
        call PutCh
        ret
PrintNibble endp

PrintDec16 proc near
        push eax
        movzx eax,ax
        call PrintDec32
        pop eax
        ret
PrintDec16 endp

PrintDec32 proc near
        push eax
        push ebx
        push ecx
        push edx
        xor ecx,ecx
        mov ebx,10
        test eax,eax
        jnz Pd32Loop
        mov dl,'0'
        call PutCh
        jmp short Pd32Done
Pd32Loop:
        xor edx,edx
        div ebx
        push dx
        inc cx
        test eax,eax
        jnz Pd32Loop
Pd32Out:
        pop dx
        add dl,'0'
        call PutCh
        loop Pd32Out
Pd32Done:
        pop edx
        pop ecx
        pop ebx
        pop eax
        ret
PrintDec32 endp

; EAX = refresh rate in 0.01 Hz units.  Prints e.g. 8527 as 85.27.
PrintRefresh100 proc near
        push eax
        push ebx
        push ecx
        push edx
        xor edx,edx
        mov ebx,100
        div ebx
        mov ecx,edx
        call PrintDec32
        mov dl,'.'
        call PutCh
        mov eax,ecx
        cmp eax,10
        jae Pr100NoZero
        mov dl,'0'
        call PutCh
Pr100NoZero:
        call PrintDec32
        pop edx
        pop ecx
        pop ebx
        pop eax
        ret
PrintRefresh100 endp

; ----------------------------------------------------------------------
; Protected-mode descriptors.
; ----------------------------------------------------------------------
GdtStart:
        dq 0
GdtCode16:
        dw 0FFFFh,0000h
        db 00h,09Ah,00h,00h
GdtData16:
        dw 0FFFFh,0000h
        db 00h,092h,00h,00h
GdtFlat:
        dw 0FFFFh,0000h
        db 00h,092h,0CFh,00h
GdtEnd:
Gdtr:
        dw GdtEnd-GdtStart-1
        dd 0

; ----------------------------------------------------------------------
; Resident information.  /S and /U access this through INT 2Fh MUX_INFO.
; ----------------------------------------------------------------------
ResidentInfo label byte
OldInt10             dd 0
OldInt2F             dd 0
XmsEntry             dd 0
ResidentEnvironment  dw 0
MmioBase             dd 0
PciBdf               dw 0
PciId                dd 0
PmcBoot0             dd 0
Pextdev0             dd 0
Chipset               db 0
CrystalKHz            dd 0
RequestCount          dw 0
AppliedCount          dw 0
FailedCount           dw 0
LastBx                dw 0
LastBiosAx            dw 0FFFFh
LastResult            db RES_NONE
LastHead              db 0
LastHTotal            dw 0
LastHStart            dw 0
LastHEnd              dw 0
LastVTotal            dw 0
LastVStart            dw 0
LastVEnd              dw 0
LastCrtcFlags         db 0
LastPixelClock        dd 0
LastRefresh           dw 0
LastActualKHz         dd 0
LastActualRefresh     dd 0

RI_OLD10       equ OldInt10-ResidentInfo
RI_OLD2F       equ OldInt2F-ResidentInfo
RI_XMS         equ XmsEntry-ResidentInfo
RI_ENV         equ ResidentEnvironment-ResidentInfo
RI_BAR         equ MmioBase-ResidentInfo
RI_CHIPSET     equ Chipset-ResidentInfo
RI_CRYSTAL     equ CrystalKHz-ResidentInfo
RI_REQUESTS    equ RequestCount-ResidentInfo
RI_APPLIED     equ AppliedCount-ResidentInfo
RI_FAILED      equ FailedCount-ResidentInfo
RI_LASTBX      equ LastBx-ResidentInfo
RI_LASTBIOS    equ LastBiosAx-ResidentInfo
RI_LASTRESULT  equ LastResult-ResidentInfo
RI_LASTHEAD    equ LastHead-ResidentInfo
RI_HTOTAL      equ LastHTotal-ResidentInfo
RI_HSTART      equ LastHStart-ResidentInfo
RI_HEND        equ LastHEnd-ResidentInfo
RI_VTOTAL      equ LastVTotal-ResidentInfo
RI_VSTART      equ LastVStart-ResidentInfo
RI_VEND        equ LastVEnd-ResidentInfo
RI_CRTCFLAGS   equ LastCrtcFlags-ResidentInfo
RI_PIXELCLOCK  equ LastPixelClock-ResidentInfo
RI_REFRESH     equ LastRefresh-ResidentInfo
RI_ACTUALKHZ   equ LastActualKHz-ResidentInfo
RI_ACTREFRESH  equ LastActualRefresh-ResidentInfo

; Runtime resident scratch.
CandidateBdf          dw 0
PllSelect             dd 0
DacClkA               dd 0
Vpll0                 dd 0
Vpll0B                dd 0
Vpll1                 dd 0
Vpll1B                dd 0
ActiveHead            db 0
ActiveVpllOffset      dd 0
ActiveVpllBOffset     dd 0
CurrentVpll           dd 0
CurrentVpllB          dd 0

TargetClockKHz        dd 0
TwoStage              db 0
PllMB                 db 1
PllNB                 db 1
TmpP                  db 0
TmpM                  dw 0
TmpN                  dw 0
TmpPreClock           dd 0
TmpClock              dd 0
BestDelta             dd 0
BestPll               dd 0
BestClockKHz          dd 0

ModeX                 dw 0
ModeY                 dw 0
EffectiveY            dw 0
HTotalCount           dw 0
HDisplay              dw 0
HBlankStart           dw 0
HBlankEnd             dw 0
HSyncStart            dw 0
HSyncEnd              dw 0
VTotalCount           dw 0
VDisplay              dw 0
VBlankStart           dw 0
VBlankEnd             dw 0
VSyncStart            dw 0
VSyncEnd              dw 0
InterlaceH            dw 0

SavedSeq1             db 0
SavedCr11             db 0
SavedExtLock          db 0
SavedOwner            db 0
SavedFlags            dw 0
SavedPort70           db 0
Busy                  db 0
ForceFail             db 0
CoreCarry             db 0
CallerSS              dw 0
CallerSP              dw 0

VbeInfo               db 512 dup (0)
ModeInfo              db 256 dup (0)

LocalStack            db 1024 dup (0)
LocalStackTop label byte

ResidentEnd label byte

; ----------------------------------------------------------------------
; Transient uninstall/status storage.  It is harmless if retained because the
; COM residency paragraph is rounded at ResidentEnd above.
; ----------------------------------------------------------------------
ResidentSegment       dw 0
SavedOldInt10         dd 0
SavedOldInt2F         dd 0
SavedXmsEntry         dd 0
SavedEnvironment      dw 0

; ----------------------------------------------------------------------
; Messages.
; ----------------------------------------------------------------------
MsgTitle          db 'NVCRTC 1.0 - NVIDIA NV4x VBE 3.0 custom CRTC fix',13,10,0
MsgInstalled      db 'NVCRTC resident. Load UniRefresh (if needed) after NVCRTC.',13,10
                  db 'Use /S for status. Remove later TSRs before /U.',13,10,0
MsgStatusHeader   db 'Resident status:',13,10,0
MsgPciBdf         db 'PCI bus:devfn (hex) = ',0
MsgPciId          db 'PCI device/vendor    = ',0
MsgBar            db 'NVIDIA BAR0          = ',0
MsgBoot0          db 'PMC_BOOT_0           = ',0
MsgChipset        db 'NV chipset           = ',0
MsgCrystal        db 'Reference crystal    = ',0
MsgKHz            db ' kHz',13,10,0
MsgHz             db ' Hz',13,10,0
MsgReqCount       db 'Custom CRTC requests = ',0
MsgAppliedCount   db 'Successfully applied = ',0
MsgFailedCount    db 'Failed/skipped       = ',0
MsgLastBx         db 'Last BX mode/flags   = ',0
MsgLastBios       db 'Last BIOS AX return  = ',0
MsgLastResult     db 'Last result code     = ',0
MsgLastHead       db 'Last analog CRTC     = ',0
MsgLastH          db 'Last H total/start/end = ',0
MsgLastV          db 'Last V total/start/end = ',0
MsgLastFlags      db 'Last CRTC flags      = ',0
MsgLastPixel      db 'Requested pixel clock= ',0
MsgLastReqRefresh db 'Requested VFreq      = ',0
MsgLastActRefresh db 'Calculated VFreq     = ',0
MsgLastClock      db 'Programmed clock     = ',0
MsgCRLF           db 13,10,0

MsgAlready        db 'ERROR: NVCRTC is already installed.',13,10,0
MsgNotInstalled   db 'ERROR: NVCRTC is not installed.',13,10,0
MsgNoPci          db 'ERROR: PCI BIOS not available.',13,10,0
MsgNoDevice       db 'ERROR: no NVIDIA VGA-class PCI device found.',13,10,0
MsgPciFail        db 'ERROR: PCI configuration read failed.',13,10,0
MsgNoMemDecode    db 'ERROR: PCI memory decoding is disabled.',13,10,0
MsgBadBar         db 'ERROR: invalid NVIDIA BAR0.',13,10,0
MsgNoVbe3         db 'ERROR: BIOS does not report VBE 3.0.',13,10,0
MsgNoXms          db 'ERROR: XMS/HIMEM not available.',13,10,0
MsgA20Fail        db 'ERROR: XMS global A20 enable failed.',13,10,0
MsgNotNv4x        db 'ERROR: NVIDIA GPU is not NV4x/Curie (chipset 40h..4Fh).',13,10,0
MsgUnsafeUnload   db 'ERROR: NVCRTC is not the last INT 10h/INT 2Fh hook.',13,10
                  db 'Unload UniRefresh/other later TSRs first.',13,10,0
MsgFreeFailed     db 'ERROR: DOS could not free the resident block.',13,10,0
MsgUninstalled    db 'NVCRTC uninstalled.',13,10,0

end start
