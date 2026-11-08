; NVCRTCD.ASM - NVIDIA NV4x VBE 3.0 custom CRTC compatibility TSR
; Version 1.0
; DPMI/V86 version for JEMM386/JEMMEX with resident HDPMI32.
;
; Repairs VBE 3.0 custom CRTC mode setting on NVIDIA NV4x/Curie BIOSes
; while running in a V86/DPMI environment.  The real-mode INT 10h hook lets
; the original BIOS perform normal mode setup, then a resident DPMI callback
; applies the requested analog VGA CRTC timing and VPLL through BAR0 MMIO.
;
; Build:
;   TASM /m9 NVCRTCD.ASM
;   TLINK /t NVCRTCD.OBJ
;
; Commands:
;   NVCRTCD       install or show short resident state
;   NVCRTCD /S    show detailed status
;   NVCRTCD /D    disable correction; resident DPMI client stays loaded
;   NVCRTCD /U    same as /D
;   NVCRTCD /E    re-enable correction
;   NVCRTCD /?    show help
;
; Requirements:
;   - JEMM386/JEMMEX or compatible V86 environment
;   - resident 32-bit DPMI host such as HDPMI32.EXE -R
;   - NVIDIA NV4x/Curie chipset 40h..4Fh
;   - analog VGA output
;
.model tiny
.386p
.code
org 100h

NV_VENDOR               equ 10DEh
PCI_CLASS_VGA           equ 00030000h

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

NV_CIO_SR_LOCK          equ 1Fh
NV_CIO_SR_UNLOCK        equ 57h
NV_CIO_CRE_LSR          equ 25h
NV_CIO_CRE_HEB          equ 2Dh
NV_CIO_CRE_ILACE        equ 39h
NV_CIO_CRE_EBR          equ 41h
NV_CIO_CRE_OWNER        equ 44h

; BAR0 windows mapped through DPMI.
PMC_PAGE_OFFSET          equ 000000h
PEXT_PAGE_OFFSET         equ 101000h
DAC_PAGE_OFFSET          equ 680000h
CRTC_PAGE_OFFSET         equ 601000h
VIO_PAGE_OFFSET          equ 0C0000h

MAP_4K                  equ 1000h
MAP_DUAL                equ 3000h

; Offsets inside mapped pages.
PEXTDEV_BOOT0_PAGE       equ 000h
PLL_COEFF_SELECT_PAGE    equ 50Ch
VPLL0_COEFF_PAGE         equ 508h
VPLL1_COEFF_PAGE         equ 520h
VPLL0_COEFF_B_PAGE       equ 578h
VPLL1_COEFF_B_PAGE       equ 57Ch
PRAMDAC_DACCLK_A_PAGE    equ 52Ch

CRTC0_INDEX_PAGE         equ 03D4h
CRTC1_INDEX_PAGE         equ 23D4h

VIO0_MISC_WRITE_PAGE     equ 03C2h
VIO0_SEQ_INDEX_PAGE      equ 03C4h
VIO0_SEQ_DATA_PAGE       equ 03C5h
VIO0_MISC_READ_PAGE      equ 03CCh
VIO1_BASE                equ 2000h

; Multiplex IDs reserved for the DPMI version.
MUX_PRESENT              equ 0FED0h
MUX_PRESENT_REPLY        equ 0D0FEh
MUX_INFO                 equ 0FED1h
MUX_INFO_REPLY           equ 0D1FEh
MUX_CONTROL              equ 0FED2h
MUX_CONTROL_REPLY        equ 0D2FEh

; Plain real-mode NVCRTC identification (FEC5 is its info function).
NVCRTC_INFO              equ 0FEC5h
NVCRTC_INFO_REPLY        equ 0C5FEh

STATE_ENABLED            equ 00h
STATE_DISABLED           equ 01h

CMD_MODE                 equ 00h
CMD_DISABLE              equ 01h
CMD_ENABLE               equ 02h

CTL_DISABLED             equ 01h
CTL_ALREADY_DISABLED     equ 02h
CTL_ENABLED              equ 03h
CTL_ALREADY_ENABLED      equ 04h
CTL_BUSY                 equ 05h
CTL_BAD_COMMAND          equ 0FFh

RES_NONE                 equ 0
RES_APPLIED              equ 1
RES_BIOS_FAILED          equ 2
RES_MODEINFO             equ 3
RES_MODE_UNSUPPORTED     equ 4
RES_BAD_TIMING           equ 5
RES_PLL_FAILED           equ 6
RES_WRITE_VERIFY         equ 7

ARG_DEFAULT              equ 00h
ARG_STATUS               equ 01h
ARG_DISABLE              equ 02h
ARG_ENABLE               equ 03h
ARG_HELP                 equ 04h
ARG_INVALID              equ 0FFh

; DPMI real-mode register structure.
RM_EDI                   equ 00h
RM_ESI                   equ 04h
RM_EBP                   equ 08h
RM_RES                   equ 0Ch
RM_EBX                   equ 10h
RM_EDX                   equ 14h
RM_ECX                   equ 18h
RM_EAX                   equ 1Ch
RM_FLAGS                 equ 20h
RM_ES                    equ 22h
RM_DS                    equ 24h
RM_FS                    equ 26h
RM_GS                    equ 28h
RM_IP                    equ 2Ah
RM_CS                    equ 2Ch
RM_SP                    equ 2Eh
RM_SS                    equ 30h
RM_STRUCT_SIZE           equ 32h

HDPMI_PRIVATE_PARAS      equ 0020h

start:
        jmp     InstallerStart

; ==========================================================================
; RESIDENT REGION
; ==========================================================================

; --------------------------------------------------------------------------
; INT 2Fh presence/status/control service.
; --------------------------------------------------------------------------
NewInt2F proc far
        cmp     ax,MUX_PRESENT
        je      MuxPresent
        cmp     ax,MUX_INFO
        je      MuxInfo
        cmp     ax,MUX_CONTROL
        je      MuxControl
        jmp     dword ptr cs:[OldInt2F]

MuxPresent:
        mov     ax,MUX_PRESENT_REPLY
        iret

MuxInfo:
        mov     ax,MUX_INFO_REPLY
        push    cs
        pop     es
        mov     di,offset ResidentInfo
        iret

MuxControl:
        cmp     byte ptr cs:[Busy],0
        jne     MuxBusy
        cmp     bl,CMD_DISABLE
        je      MuxCtlGood
        cmp     bl,CMD_ENABLE
        je      MuxCtlGood
        mov     ax,MUX_CONTROL_REPLY
        mov     bl,CTL_BAD_COMMAND
        iret

MuxCtlGood:
        mov     byte ptr cs:[ControlCommand],bl
        mov     byte ptr cs:[ControlResult],CTL_BAD_COMMAND
        mov     byte ptr cs:[Busy],1
        call    dword ptr cs:[CallbackPtr]
        mov     byte ptr cs:[Busy],0
        mov     bl,byte ptr cs:[ControlResult]
        mov     ax,MUX_CONTROL_REPLY
        iret

MuxBusy:
        mov     ax,MUX_CONTROL_REPLY
        mov     bl,CTL_BUSY
        iret
NewInt2F endp

; --------------------------------------------------------------------------
; Real-mode/V86 INT 10h hook.
; --------------------------------------------------------------------------
NewInt10 proc far
        cmp     ax,4F02h
        jne     HookChain
        test    bx,VBE_CUSTOM_CRTC
        jz      HookChain
        cmp     byte ptr cs:[CorrectionState],STATE_ENABLED
        jne     HookChain
        cmp     byte ptr cs:[Busy],0
        jne     HookChain

        mov     byte ptr cs:[Busy],1

        ; Preserve the exact caller request while capturing CRTCInfoBlock and
        ; querying mode information through the original BIOS.
        pushfd
        pushad
        push    ds
        push    es
        push    fs
        push    gs

        mov     word ptr cs:[LastBx],bx
        mov     ax,word ptr es:[di+00h]
        mov     word ptr cs:[LastHTotal],ax
        mov     ax,word ptr es:[di+02h]
        mov     word ptr cs:[LastHStart],ax
        mov     ax,word ptr es:[di+04h]
        mov     word ptr cs:[LastHEnd],ax
        mov     ax,word ptr es:[di+06h]
        mov     word ptr cs:[LastVTotal],ax
        mov     ax,word ptr es:[di+08h]
        mov     word ptr cs:[LastVStart],ax
        mov     ax,word ptr es:[di+0Ah]
        mov     word ptr cs:[LastVEnd],ax
        mov     al,byte ptr es:[di+0Ch]
        mov     byte ptr cs:[LastCrtcFlags],al
        mov     eax,dword ptr es:[di+0Dh]
        mov     dword ptr cs:[LastPixelClock],eax
        mov     ax,word ptr es:[di+11h]
        mov     word ptr cs:[LastRefresh],ax

        inc     word ptr cs:[RequestCount]
        mov     byte ptr cs:[LastResult],RES_NONE
        mov     byte ptr cs:[LastHead],0FFh
        mov     dword ptr cs:[LastActualKHz],0
        mov     dword ptr cs:[LastActualRefresh],0
        mov     byte ptr cs:[ForceFail],0

        mov     cx,bx
        and     cx,VBE_MODE_MASK
        push    cs
        pop     es
        mov     di,offset ModeInfo
        mov     ax,4F01h
        pushf
        call    dword ptr cs:[OldInt10]
        mov     word ptr cs:[LastModeInfoAx],ax

        pop     gs
        pop     fs
        pop     es
        pop     ds
        popad
        popfd

        ; Original BIOS always performs the normal mode setup first.
        pushf
        call    dword ptr cs:[OldInt10]
        mov     word ptr cs:[LastBiosAx],ax

        ; Preserve BIOS return state while the protected callback repairs CRTC.
        pushfd
        pushad
        push    ds
        push    es
        push    fs
        push    gs

        cmp     ax,004Fh
        jne     HookBiosFailed
        cmp     word ptr cs:[LastModeInfoAx],004Fh
        jne     HookModeInfoFailed

        mov     byte ptr cs:[ControlCommand],CMD_MODE
        call    dword ptr cs:[CallbackPtr]
        jmp     short HookDoneWork

HookBiosFailed:
        mov     byte ptr cs:[LastResult],RES_BIOS_FAILED
        inc     word ptr cs:[FailedCount]
        jmp     short HookDoneWork

HookModeInfoFailed:
        mov     byte ptr cs:[LastResult],RES_MODEINFO
        inc     word ptr cs:[FailedCount]
        mov     byte ptr cs:[ForceFail],1

HookDoneWork:
        mov     byte ptr cs:[Busy],0
        pop     gs
        pop     fs
        pop     es
        pop     ds
        popad
        popfd
        cmp     byte ptr cs:[ForceFail],0
        je      HookIret
        mov     ax,014Fh
HookIret:
        iret

HookChain:
        jmp     dword ptr cs:[OldInt10]
NewInt10 endp

; --------------------------------------------------------------------------
; Protected-mode DPMI callback.
; No DOS or DPMI calls are made here.
; --------------------------------------------------------------------------
CallbackProc:
        mov     ax,word ptr cs:[DataSelector]
        mov     gs,ax

        mov     al,byte ptr gs:[ControlCommand]
        cmp     al,CMD_DISABLE
        je      CallbackDisable
        cmp     al,CMD_ENABLE
        je      CallbackEnable

CallbackMode:
        cmp     byte ptr gs:[CorrectionState],STATE_ENABLED
        jne     CallbackReturn

        mov     byte ptr gs:[ForceFail],0

        call    ValidateAndBuildTimingPm
        jc      CallbackModeFail

        call    ReadNvModeStatePm
        call    SelectActivePllPm

        mov     al,byte ptr gs:[ActiveHead]
        mov     byte ptr gs:[LastHead],al

        mov     eax,dword ptr gs:[LastPixelClock]
        add     eax,500
        xor     edx,edx
        mov     ebx,1000
        div     ebx
        mov     dword ptr gs:[TargetClockKHz],eax

        call    CalcTargetPllPm
        jc      CallbackPllFail

        call    ProgramCrtcTimingPm
        jc      CallbackWriteFail

        mov     eax,dword ptr gs:[BestClockKHz]
        mov     dword ptr gs:[LastActualKHz],eax

        ; Actual VFreq in 0.01 Hz:
        ; clock_kHz * 100000 / (HTotal * VTotal)
        mov     ebx,100000
        mul     ebx
        movzx   ebx,word ptr gs:[LastHTotal]
        movzx   ecx,word ptr gs:[LastVTotal]
        imul    ebx,ecx
        test    ebx,ebx
        jz      CallbackRefreshZero
        div     ebx
        mov     dword ptr gs:[LastActualRefresh],eax
        jmp     short CallbackApplied
CallbackRefreshZero:
        mov     dword ptr gs:[LastActualRefresh],0

CallbackApplied:
        inc     word ptr gs:[AppliedCount]
        mov     byte ptr gs:[LastResult],RES_APPLIED
        jmp     CallbackReturn

CallbackPllFail:
        mov     byte ptr gs:[LastResult],RES_PLL_FAILED
CallbackModeFail:
        inc     word ptr gs:[FailedCount]
        mov     byte ptr gs:[ForceFail],1
        jmp     CallbackReturn

CallbackWriteFail:
        mov     byte ptr gs:[LastResult],RES_WRITE_VERIFY
        inc     word ptr gs:[FailedCount]
        mov     byte ptr gs:[ForceFail],1
        jmp     CallbackReturn

CallbackDisable:
        cmp     byte ptr gs:[CorrectionState],STATE_DISABLED
        je      CallbackDisableAlready
        mov     byte ptr gs:[CorrectionState],STATE_DISABLED
        mov     byte ptr gs:[ControlResult],CTL_DISABLED
        jmp     CallbackReturn
CallbackDisableAlready:
        mov     byte ptr gs:[ControlResult],CTL_ALREADY_DISABLED
        jmp     CallbackReturn

CallbackEnable:
        cmp     byte ptr gs:[CorrectionState],STATE_ENABLED
        je      CallbackEnableAlready
        mov     byte ptr gs:[CorrectionState],STATE_ENABLED
        mov     byte ptr gs:[ControlResult],CTL_ENABLED
        jmp     CallbackReturn
CallbackEnableAlready:
        mov     byte ptr gs:[ControlResult],CTL_ALREADY_ENABLED

; Return from the DPMI callback to the real-mode FAR CALL site.
CallbackReturn:
        mov     ax,word ptr ds:[esi]
        mov     word ptr es:[edi+RM_IP],ax
        mov     ax,word ptr ds:[esi+2]
        mov     word ptr es:[edi+RM_CS],ax
        add     word ptr es:[edi+RM_SP],4
        db      066h,0CFh              ; IRETD - same verified bridge as ASPECTD

ValidateAndBuildTimingPm proc near
        pushad

        mov ax,word ptr gs:[ModeInfo+VBE_MI_ATTR]
        test ax,0001h                    ; mode available
        jz VbtUnsupported
        test ax,0010h                    ; graphics mode
        jz VbtUnsupported
        test ax,0020h                    ; D5=1 means NOT VGA compatible
        jnz VbtUnsupported

        mov al,byte ptr gs:[LastCrtcFlags]
        test al,0F0h
        jnz VbtBad

        ; Respect VBE mode capability bits for doublescan/interlace.
        test al,CRTCF_DBLSCAN
        jz VbtNoDblCheck
        test word ptr gs:[ModeInfo+VBE_MI_ATTR],0100h
        jz VbtUnsupported
VbtNoDblCheck:
        test al,CRTCF_INTERLACE
        jz VbtNoIntCheck
        test word ptr gs:[ModeInfo+VBE_MI_ATTR],0200h
        jz VbtUnsupported
VbtNoIntCheck:

        mov ax,word ptr gs:[ModeInfo+VBE_MI_XRES]
        mov word ptr gs:[ModeX],ax
        mov ax,word ptr gs:[ModeInfo+VBE_MI_YRES]
        mov word ptr gs:[ModeY],ax
        cmp word ptr gs:[ModeX],0
        je VbtBad
        cmp word ptr gs:[ModeY],0
        je VbtBad

        ; NV04/NV4x VGA timing generator is character-clock based horizontally.
        mov ax,word ptr gs:[ModeX]
        test ax,7
        jnz VbtBad
        mov ax,word ptr gs:[LastHTotal]
        test ax,7
        jnz VbtBad
        mov ax,word ptr gs:[LastHStart]
        test ax,7
        jnz VbtBad
        mov ax,word ptr gs:[LastHEnd]
        test ax,7
        jnz VbtBad

        ; Basic horizontal ordering.
        mov ax,word ptr gs:[ModeX]
        cmp word ptr gs:[LastHStart],ax
        jb VbtBad
        mov ax,word ptr gs:[LastHStart]
        cmp word ptr gs:[LastHEnd],ax
        jbe VbtBad
        mov ax,word ptr gs:[LastHEnd]
        cmp word ptr gs:[LastHTotal],ax
        jbe VbtBad

        ; Effective displayed vertical lines.  VBE doublescan timings are
        ; normalized to twice the logical resolution.
        mov ax,word ptr gs:[ModeY]
        test byte ptr gs:[LastCrtcFlags],CRTCF_DBLSCAN
        jz VbtDisplayReady
        shl ax,1
        jc VbtBad
VbtDisplayReady:
        mov word ptr gs:[EffectiveY],ax
        cmp word ptr gs:[LastVStart],ax
        jb VbtBad
        mov ax,word ptr gs:[LastVStart]
        cmp word ptr gs:[LastVEnd],ax
        jbe VbtBad
        mov ax,word ptr gs:[LastVEnd]
        cmp word ptr gs:[LastVTotal],ax
        jbe VbtBad

        ; Hardware counter ranges: horizontal 9-bit extended values, vertical
        ; 12-bit extended values.
        mov ax,word ptr gs:[LastHTotal]
        shr ax,3
        cmp ax,516                       ; (HTotal/8 - 5) <= 511
        ja VbtBad
        mov ax,word ptr gs:[ModeX]
        shr ax,3
        cmp ax,512
        ja VbtBad
        mov ax,word ptr gs:[LastHStart]
        shr ax,3
        inc ax
        cmp ax,511
        ja VbtBad

        cmp word ptr gs:[LastVTotal],4097 ; VTotal-2 <= 4095
        ja VbtBad
        cmp word ptr gs:[EffectiveY],4096
        ja VbtBad
        cmp word ptr gs:[LastVStart],4096
        ja VbtBad

        mov eax,dword ptr gs:[LastPixelClock]
        test eax,eax
        jz VbtBad
        cmp eax,10000000                 ; conservative 10 MHz floor
        jb VbtBad
        cmp eax,400000000                ; conservative NV4x analog ceiling
        ja VbtBad
        mov edx,dword ptr gs:[ModeInfo+VBE_MI_MAXCLOCK]
        test edx,edx
        jz VbtClockOk
        cmp eax,edx
        ja VbtBad
VbtClockOk:

        ; Horizontal derived counters.
        mov ax,word ptr gs:[ModeX]
        shr ax,3
        dec ax
        mov word ptr gs:[HDisplay],ax
        mov word ptr gs:[HBlankStart],ax

        mov ax,word ptr gs:[LastHStart]
        shr ax,3
        inc ax
        mov word ptr gs:[HSyncStart],ax

        mov ax,word ptr gs:[LastHEnd]
        shr ax,3
        inc ax
        mov word ptr gs:[HSyncEnd],ax

        mov ax,word ptr gs:[LastHTotal]
        shr ax,3
        mov bx,ax
        sub ax,5
        mov word ptr gs:[HTotalCount],ax
        mov ax,bx
        dec ax
        mov word ptr gs:[HBlankEnd],ax

        ; Vertical derived counters.
        mov ax,word ptr gs:[EffectiveY]
        dec ax
        mov word ptr gs:[VDisplay],ax
        mov word ptr gs:[VBlankStart],ax

        mov ax,word ptr gs:[LastVStart]
        dec ax
        mov word ptr gs:[VSyncStart],ax
        mov ax,word ptr gs:[LastVEnd]
        dec ax
        mov word ptr gs:[VSyncEnd],ax
        mov ax,word ptr gs:[LastVTotal]
        sub ax,2
        test byte ptr gs:[LastCrtcFlags],CRTCF_INTERLACE
        jz VbtNoOddInterlace
        or ax,1
VbtNoOddInterlace:
        mov word ptr gs:[VTotalCount],ax
        mov ax,word ptr gs:[LastVTotal]
        dec ax
        mov word ptr gs:[VBlankEnd],ax

        popad
        clc
        ret

VbtUnsupported:
        mov byte ptr gs:[LastResult],RES_MODE_UNSUPPORTED
        popad
        stc
        ret
VbtBad:
        mov byte ptr gs:[LastResult],RES_BAD_TIMING
        popad
        stc
        ret
ValidateAndBuildTimingPm endp


; --------------------------------------------------------------------------
; Read BIOS-selected VPLL/routing state after the mode set.
; --------------------------------------------------------------------------
ReadNvModeStatePm proc near
        push    fs

        mov     ax,word ptr gs:[DacSelector]
        mov     fs,ax

        mov     eax,dword ptr fs:[PLL_COEFF_SELECT_PAGE]
        mov     dword ptr gs:[PllSelect],eax
        mov     eax,dword ptr fs:[VPLL0_COEFF_PAGE]
        mov     dword ptr gs:[Vpll0],eax
        mov     eax,dword ptr fs:[VPLL0_COEFF_B_PAGE]
        mov     dword ptr gs:[Vpll0B],eax
        mov     eax,dword ptr fs:[VPLL1_COEFF_PAGE]
        mov     dword ptr gs:[Vpll1],eax
        mov     eax,dword ptr fs:[VPLL1_COEFF_B_PAGE]
        mov     dword ptr gs:[Vpll1B],eax
        mov     eax,dword ptr fs:[PRAMDAC_DACCLK_A_PAGE]
        mov     dword ptr gs:[DacClkA],eax

        pop     fs
        ret
ReadNvModeStatePm endp

SelectActivePllPm proc near
        mov     eax,dword ptr gs:[DacClkA]
        test    eax,00000100h
        jnz     SapPmHead1

        mov     byte ptr gs:[ActiveHead],0
        mov     eax,dword ptr gs:[Vpll0]
        mov     dword ptr gs:[CurrentVpll],eax
        mov     eax,dword ptr gs:[Vpll0B]
        mov     dword ptr gs:[CurrentVpllB],eax
        mov     word ptr gs:[ActiveVpllOffset],VPLL0_COEFF_PAGE
        mov     word ptr gs:[ActiveVpllBOffset],VPLL0_COEFF_B_PAGE
        mov     word ptr gs:[ActiveCrtcIndex],CRTC0_INDEX_PAGE
        mov     word ptr gs:[ActiveVioBase],0000h
        ret

SapPmHead1:
        mov     byte ptr gs:[ActiveHead],1
        mov     eax,dword ptr gs:[Vpll1]
        mov     dword ptr gs:[CurrentVpll],eax
        mov     eax,dword ptr gs:[Vpll1B]
        mov     dword ptr gs:[CurrentVpllB],eax
        mov     word ptr gs:[ActiveVpllOffset],VPLL1_COEFF_PAGE
        mov     word ptr gs:[ActiveVpllBOffset],VPLL1_COEFF_B_PAGE
        mov     word ptr gs:[ActiveCrtcIndex],CRTC1_INDEX_PAGE
        mov     word ptr gs:[ActiveVioBase],VIO1_BASE
        ret
SelectActivePllPm endp

CalcTargetPllPm proc near
        pushad

        mov dword ptr gs:[BestDelta],0FFFFFFFFh
        mov dword ptr gs:[BestPll],0
        mov dword ptr gs:[BestClockKHz],0

        mov eax,dword ptr gs:[CurrentVpllB]
        test eax,80000000h
        jz CtpSingle
        mov bl,al
        mov bh,ah
        test bl,bl
        jz CtpSingle
        test bh,bh
        jz CtpSingle
        mov byte ptr gs:[PllMB],bl
        mov byte ptr gs:[PllNB],bh
        mov byte ptr gs:[TwoStage],1
        jmp short CtpStart
CtpSingle:
        mov byte ptr gs:[PllMB],1
        mov byte ptr gs:[PllNB],1
        mov byte ptr gs:[TwoStage],0

CtpStart:
        mov byte ptr gs:[TmpP],0
CtpPLoop:
        mov word ptr gs:[TmpM],1
CtpMLoop:
        cmp byte ptr gs:[TwoStage],0
        je CtpNInitSingle
        mov word ptr gs:[TmpN],5
        jmp short CtpNLoop
CtpNInitSingle:
        mov word ptr gs:[TmpN],1

CtpNLoop:
        mov eax,dword ptr gs:[CrystalKHz]
        movzx ebx,word ptr gs:[TmpN]
        mul ebx
        movzx ebx,word ptr gs:[TmpM]
        xor edx,edx
        div ebx

        cmp byte ptr gs:[TwoStage],0
        je CtpHavePre
        movzx ebx,byte ptr gs:[PllNB]
        mul ebx
        movzx ebx,byte ptr gs:[PllMB]
        xor edx,edx
        div ebx

CtpHavePre:
        mov dword ptr gs:[TmpPreClock],eax
        cmp byte ptr gs:[TwoStage],0
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
        mov cl,byte ptr gs:[TmpP]
        shr eax,cl
        mov dword ptr gs:[TmpClock],eax

        mov edx,eax
        sub edx,dword ptr gs:[TargetClockKHz]
        jns CtpDeltaReady
        neg edx
CtpDeltaReady:
        cmp edx,dword ptr gs:[BestDelta]
        jae CtpNextN
        mov dword ptr gs:[BestDelta],edx
        mov dword ptr gs:[BestClockKHz],eax

        movzx eax,byte ptr gs:[TmpP]
        shl eax,16
        movzx edx,word ptr gs:[TmpN]
        shl edx,8
        or eax,edx
        movzx edx,word ptr gs:[TmpM]
        or eax,edx
        mov dword ptr gs:[BestPll],eax

CtpNextN:
        inc word ptr gs:[TmpN]
        cmp word ptr gs:[TmpN],255
        jbe CtpNLoop
        inc word ptr gs:[TmpM]
        cmp byte ptr gs:[TwoStage],0
        je CtpM14
        cmp word ptr gs:[TmpM],13
        jbe CtpMLoop
        jmp short CtpNextP
CtpM14:
        cmp word ptr gs:[TmpM],14
        jbe CtpMLoop
CtpNextP:
        inc byte ptr gs:[TmpP]
        cmp byte ptr gs:[TmpP],6
        jbe CtpPLoop

        cmp dword ptr gs:[BestPll],0
        je CtpFail
        cmp dword ptr gs:[BestDelta],500
        ja CtpFail
        popad
        clc
        ret
CtpFail:
        popad
        stc
        ret
CalcTargetPllPm endp


; --------------------------------------------------------------------------
; MMIO indexed-register helpers. FS must select the appropriate mapped page.
; --------------------------------------------------------------------------
PmReadActiveCrtc proc near
        push    bx
        mov     bx,word ptr gs:[ActiveCrtcIndex]
        mov     byte ptr fs:[bx],al
        inc     bx
        mov     al,byte ptr fs:[bx]
        pop     bx
        ret
PmReadActiveCrtc endp

PmWriteActiveCrtc proc near
        push    bx
        mov     bx,word ptr gs:[ActiveCrtcIndex]
        mov     byte ptr fs:[bx],al
        inc     bx
        mov     byte ptr fs:[bx],ah
        pop     bx
        ret
PmWriteActiveCrtc endp

PmReadCrtc0 proc near
        push    bx
        mov     bx,CRTC0_INDEX_PAGE
        mov     byte ptr fs:[bx],al
        inc     bx
        mov     al,byte ptr fs:[bx]
        pop     bx
        ret
PmReadCrtc0 endp

PmWriteCrtc0 proc near
        push    bx
        mov     bx,CRTC0_INDEX_PAGE
        mov     byte ptr fs:[bx],al
        inc     bx
        mov     byte ptr fs:[bx],ah
        pop     bx
        ret
PmWriteCrtc0 endp

; --------------------------------------------------------------------------
; Program standard + NVIDIA extended VGA CRTC state through BAR0 aliases.
; The original BIOS has already configured framebuffer format/pitch/FIFO.
; --------------------------------------------------------------------------
ProgramCrtcTimingPm proc near
        pushad
        push    fs

        mov     byte ptr gs:[WriteVerifyFailed],0

        ; CRTC MMIO page.
        mov     ax,word ptr gs:[CrtcSelector]
        mov     fs,ax

        ; Unlock head 0 extended CRTC and remember its original lock state.
        mov     al,NV_CIO_SR_LOCK
        call    PmReadCrtc0
        mov     byte ptr gs:[SavedExtLock0],al
        mov     ax,571Fh
        call    PmWriteCrtc0

        ; If analog VGA is driven by head 1, unlock that bank too.
        mov     al,byte ptr gs:[ActiveHead]
        or      al,al
        jz      PctPmActiveUnlocked
        mov     al,NV_CIO_SR_LOCK
        call    PmReadActiveCrtc
        mov     byte ptr gs:[SavedExtLockActive],al
        mov     ax,571Fh
        call    PmWriteActiveCrtc
PctPmActiveUnlocked:

        ; CR44 is always written through CRTC0.
        mov     al,NV_CIO_CRE_OWNER
        call    PmReadCrtc0
        mov     byte ptr gs:[SavedOwner],al
        xor     ah,ah
        cmp     byte ptr gs:[ActiveHead],0
        je      PctPmOwnerReady
        mov     ah,3
PctPmOwnerReady:
        mov     al,NV_CIO_CRE_OWNER
        call    PmWriteCrtc0

        ; Blank active VGA head and program sync polarity through PRMVIO.
        mov     ax,word ptr gs:[VioSelector]
        mov     fs,ax
        mov     bx,word ptr gs:[ActiveVioBase]
        add     bx,VIO0_SEQ_INDEX_PAGE
        mov     byte ptr fs:[bx],01h
        inc     bx
        mov     al,byte ptr fs:[bx]
        mov     byte ptr gs:[SavedSeq1],al
        or      al,20h
        mov     byte ptr fs:[bx],al

        mov     bx,word ptr gs:[ActiveVioBase]
        add     bx,VIO0_MISC_READ_PAGE
        mov     al,byte ptr fs:[bx]
        and     al,3Fh
        test    byte ptr gs:[LastCrtcFlags],CRTCF_NHSYNC
        jz      PctPmNoNH
        or      al,40h
PctPmNoNH:
        test    byte ptr gs:[LastCrtcFlags],CRTCF_NVSYNC
        jz      PctPmNoNV
        or      al,80h
PctPmNoNV:
        mov     bx,word ptr gs:[ActiveVioBase]
        add     bx,VIO0_MISC_WRITE_PAGE
        mov     byte ptr fs:[bx],al

        ; Back to active CRTC bank.
        mov     ax,word ptr gs:[CrtcSelector]
        mov     fs,ax

        ; Unlock standard CRTC 00h..07h.
        mov     al,11h
        call    PmReadActiveCrtc
        mov     byte ptr gs:[SavedCr11],al
        and     al,7Fh
        mov     ah,al
        mov     al,11h
        call    PmWriteActiveCrtc

        ; Horizontal timing.
        mov     ax,word ptr gs:[HTotalCount]
        mov     ah,al
        mov     al,00h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[HDisplay]
        mov     ah,al
        mov     al,01h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[HBlankStart]
        mov     ah,al
        mov     al,02h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[HBlankEnd]
        and     al,1Fh
        or      al,80h
        mov     ah,al
        mov     al,03h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[HSyncStart]
        mov     ah,al
        mov     al,04h
        call    PmWriteActiveCrtc

        mov     bx,word ptr gs:[HBlankEnd]
        mov     ax,word ptr gs:[HSyncEnd]
        and     al,1Fh
        test    bx,0020h
        jz      PctPmHbe5Done
        or      al,80h
PctPmHbe5Done:
        mov     ah,al
        mov     al,05h
        call    PmWriteActiveCrtc

        ; Vertical timing.
        mov     ax,word ptr gs:[VTotalCount]
        mov     ah,al
        mov     al,06h
        call    PmWriteActiveCrtc

        xor     bx,bx
        test    word ptr gs:[VTotalCount],0100h
        jz      PctPmOv1
        or      bl,01h
PctPmOv1:
        test    word ptr gs:[VDisplay],0100h
        jz      PctPmOv2
        or      bl,02h
PctPmOv2:
        test    word ptr gs:[VSyncStart],0100h
        jz      PctPmOv3
        or      bl,04h
PctPmOv3:
        test    word ptr gs:[VBlankStart],0100h
        jz      PctPmOv4
        or      bl,08h
PctPmOv4:
        or      bl,10h
        test    word ptr gs:[VTotalCount],0200h
        jz      PctPmOv5
        or      bl,20h
PctPmOv5:
        test    word ptr gs:[VDisplay],0200h
        jz      PctPmOv6
        or      bl,40h
PctPmOv6:
        test    word ptr gs:[VSyncStart],0200h
        jz      PctPmOv7
        or      bl,80h
PctPmOv7:
        mov     ah,bl
        mov     al,07h
        call    PmWriteActiveCrtc

        mov     bl,40h
        test    word ptr gs:[VBlankStart],0200h
        jz      PctPmCr09NoVbs9
        or      bl,20h
PctPmCr09NoVbs9:
        test    byte ptr gs:[LastCrtcFlags],CRTCF_DBLSCAN
        jz      PctPmCr09NoDbl
        or      bl,80h
PctPmCr09NoDbl:
        mov     ah,bl
        mov     al,09h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[VSyncStart]
        mov     ah,al
        mov     al,10h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[VDisplay]
        mov     ah,al
        mov     al,12h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[VBlankStart]
        mov     ah,al
        mov     al,15h
        call    PmWriteActiveCrtc

        mov     ax,word ptr gs:[VBlankEnd]
        mov     ah,al
        mov     al,16h
        call    PmWriteActiveCrtc

        mov     ah,byte ptr gs:[SavedCr11]
        and     ah,0F0h
        mov     al,byte ptr gs:[VSyncEnd]
        and     al,0Fh
        or      ah,al
        mov     al,11h
        call    PmWriteActiveCrtc

        ; CR25: VTotal10,VDisplay10,VSync10,VBlank10,HBlankEnd6.
        xor     bl,bl
        test    word ptr gs:[VTotalCount],0400h
        jz      PctPm25a
        or      bl,01h
PctPm25a:
        test    word ptr gs:[VDisplay],0400h
        jz      PctPm25b
        or      bl,02h
PctPm25b:
        test    word ptr gs:[VSyncStart],0400h
        jz      PctPm25c
        or      bl,04h
PctPm25c:
        test    word ptr gs:[VBlankStart],0400h
        jz      PctPm25d
        or      bl,08h
PctPm25d:
        test    word ptr gs:[HBlankEnd],0040h
        jz      PctPm25e
        or      bl,10h
PctPm25e:
        mov     ah,bl
        mov     al,NV_CIO_CRE_LSR
        call    PmWriteActiveCrtc

        ; CR2D: horizontal bit8 overflow + interlace bit.
        xor     bl,bl
        test    word ptr gs:[HTotalCount],0100h
        jz      PctPm2da
        or      bl,01h
PctPm2da:
        test    word ptr gs:[HDisplay],0100h
        jz      PctPm2db
        or      bl,02h
PctPm2db:
        test    word ptr gs:[HBlankStart],0100h
        jz      PctPm2dc
        or      bl,04h
PctPm2dc:
        test    word ptr gs:[HSyncStart],0100h
        jz      PctPm2dd
        or      bl,08h
PctPm2dd:
        mov     word ptr gs:[InterlaceH],0
        test    byte ptr gs:[LastCrtcFlags],CRTCF_INTERLACE
        jz      PctPm2dNoInt
        mov     ax,word ptr gs:[HTotalCount]
        shr     ax,1
        and     ax,0FFFEh
        mov     word ptr gs:[InterlaceH],ax
        test    ax,0100h
        jz      PctPm2dNoInt
        or      bl,10h
PctPm2dNoInt:
        mov     ah,bl
        mov     al,NV_CIO_CRE_HEB
        call    PmWriteActiveCrtc

        ; CR41: vertical bit11 overflow.
        xor     bl,bl
        test    word ptr gs:[VTotalCount],0800h
        jz      PctPm41a
        or      bl,01h
PctPm41a:
        test    word ptr gs:[VDisplay],0800h
        jz      PctPm41b
        or      bl,04h
PctPm41b:
        test    word ptr gs:[VSyncStart],0800h
        jz      PctPm41c
        or      bl,10h
PctPm41c:
        test    word ptr gs:[VBlankStart],0800h
        jz      PctPm41d
        or      bl,40h
PctPm41d:
        mov     ah,bl
        mov     al,NV_CIO_CRE_EBR
        call    PmWriteActiveCrtc

        test    byte ptr gs:[LastCrtcFlags],CRTCF_INTERLACE
        jz      PctPmNoInterlace
        mov     ax,word ptr gs:[InterlaceH]
        mov     ah,al
        mov     al,NV_CIO_CRE_ILACE
        call    PmWriteActiveCrtc
        jmp     short PctPmInterlaceDone
PctPmNoInterlace:
        mov     ax,0FF39h
        call    PmWriteActiveCrtc
PctPmInterlaceDone:

        ; Program the active VPLL through mapped PRAMDAC.
        mov     ax,word ptr gs:[DacSelector]
        mov     fs,ax

        mov     eax,dword ptr gs:[PllSelect]
        mov     dword ptr fs:[PLL_COEFF_SELECT_PAGE],eax

        xor     bx,bx
        mov     bx,word ptr gs:[ActiveVpllOffset]
        mov     eax,dword ptr gs:[BestPll]
        mov     dword ptr fs:[bx],eax

        mov     bx,word ptr gs:[ActiveVpllBOffset]
        mov     eax,dword ptr gs:[CurrentVpllB]
        mov     dword ptr fs:[bx],eax

        ; Immediate VPLL readback verification.
        mov     bx,word ptr gs:[ActiveVpllOffset]
        mov     eax,dword ptr fs:[bx]
        cmp     eax,dword ptr gs:[BestPll]
        jne     PctPmVerifyFail
        mov     bx,word ptr gs:[ActiveVpllBOffset]
        mov     eax,dword ptr fs:[bx]
        cmp     eax,dword ptr gs:[CurrentVpllB]
        jne     PctPmVerifyFail
        jmp     short PctPmRestore
PctPmVerifyFail:
        mov     byte ptr gs:[WriteVerifyFailed],1

PctPmRestore:
        ; Restore CR44 and extended CRTC locks.
        mov     ax,word ptr gs:[CrtcSelector]
        mov     fs,ax

        mov     ah,byte ptr gs:[SavedOwner]
        mov     al,NV_CIO_CRE_OWNER
        call    PmWriteCrtc0

        cmp     byte ptr gs:[ActiveHead],0
        je      PctPmRestoreHead0Only
        mov     ah,byte ptr gs:[SavedExtLockActive]
        or      ah,ah
        jnz     PctPmRestoreActiveLock
        mov     ah,99h
PctPmRestoreActiveLock:
        mov     al,NV_CIO_SR_LOCK
        call    PmWriteActiveCrtc
PctPmRestoreHead0Only:
        mov     ah,byte ptr gs:[SavedExtLock0]
        or      ah,ah
        jnz     PctPmRestoreLock0
        mov     ah,99h
PctPmRestoreLock0:
        mov     al,NV_CIO_SR_LOCK
        call    PmWriteCrtc0

        ; Unblank using BIOS sequencer value.
        mov     ax,word ptr gs:[VioSelector]
        mov     fs,ax
        mov     bx,word ptr gs:[ActiveVioBase]
        add     bx,VIO0_SEQ_INDEX_PAGE
        mov     byte ptr fs:[bx],01h
        inc     bx
        mov     al,byte ptr gs:[SavedSeq1]
        and     al,0DFh
        mov     byte ptr fs:[bx],al

        cmp     byte ptr gs:[WriteVerifyFailed],0
        jne     PctPmFail

        pop     fs
        popad
        clc
        ret
PctPmFail:
        pop     fs
        popad
        stc
        ret
ProgramCrtcTimingPm endp


; --------------------------------------------------------------------------
; Resident data.
; --------------------------------------------------------------------------
OldInt10              dd 0
OldInt2F              dd 0
CallbackPtr           dd 0

DataSelector          dw 0
PmcSelector           dw 0
PextSelector          dw 0
DacSelector           dw 0
CrtcSelector          dw 0
VioSelector           dw 0

Busy                  db 0
ControlCommand        db CMD_MODE
ControlResult         db 0
ForceFail             db 0

; Public status starts here.
ResidentInfo label byte
CorrectionState       db STATE_ENABLED
ResidentParas         dw 0
PciBdf                dw 0
PciId                 dd 0
MmioBase              dd 0
PmcBoot0              dd 0
Pextdev0              dd 0
Chipset               db 0
CrystalKHz            dd 0
RequestCount          dw 0
AppliedCount          dw 0
FailedCount           dw 0
LastBx                dw 0
LastModeInfoAx        dw 0FFFFh
LastBiosAx            dw 0FFFFh
LastResult            db RES_NONE
LastHead              db 0FFh
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

RI_RES_PARAS          equ ResidentParas-ResidentInfo
RI_PCI_BDF            equ PciBdf-ResidentInfo
RI_PCI_ID             equ PciId-ResidentInfo
RI_BAR                equ MmioBase-ResidentInfo
RI_BOOT0              equ PmcBoot0-ResidentInfo
RI_CHIPSET            equ Chipset-ResidentInfo
RI_CRYSTAL            equ CrystalKHz-ResidentInfo
RI_REQUESTS           equ RequestCount-ResidentInfo
RI_APPLIED            equ AppliedCount-ResidentInfo
RI_FAILED             equ FailedCount-ResidentInfo
RI_LASTBX              equ LastBx-ResidentInfo
RI_MODEINFO            equ LastModeInfoAx-ResidentInfo
RI_LASTBIOS            equ LastBiosAx-ResidentInfo
RI_LASTRESULT          equ LastResult-ResidentInfo
RI_LASTHEAD            equ LastHead-ResidentInfo
RI_HTOTAL              equ LastHTotal-ResidentInfo
RI_HSTART              equ LastHStart-ResidentInfo
RI_HEND                equ LastHEnd-ResidentInfo
RI_VTOTAL              equ LastVTotal-ResidentInfo
RI_VSTART              equ LastVStart-ResidentInfo
RI_VEND                equ LastVEnd-ResidentInfo
RI_CRTCFLAGS           equ LastCrtcFlags-ResidentInfo
RI_PIXELCLOCK          equ LastPixelClock-ResidentInfo
RI_REFRESH             equ LastRefresh-ResidentInfo
RI_ACTUALKHZ           equ LastActualKHz-ResidentInfo
RI_ACTREFRESH          equ LastActualRefresh-ResidentInfo
RI_STATE               equ CorrectionState-ResidentInfo

; Runtime scratch.
PllSelect              dd 0
DacClkA                dd 0
Vpll0                  dd 0
Vpll0B                 dd 0
Vpll1                  dd 0
Vpll1B                 dd 0
ActiveHead             db 0
ActiveVpllOffset       dw 0
ActiveVpllBOffset      dw 0
ActiveCrtcIndex        dw CRTC0_INDEX_PAGE
ActiveVioBase          dw 0
CurrentVpll            dd 0
CurrentVpllB           dd 0

TargetClockKHz         dd 0
TwoStage               db 0
PllMB                  db 1
PllNB                  db 1
TmpP                   db 0
TmpM                   dw 0
TmpN                   dw 0
TmpPreClock            dd 0
TmpClock               dd 0
BestDelta              dd 0
BestPll                dd 0
BestClockKHz           dd 0

ModeX                  dw 0
ModeY                  dw 0
EffectiveY             dw 0
HTotalCount            dw 0
HDisplay               dw 0
HBlankStart            dw 0
HBlankEnd              dw 0
HSyncStart             dw 0
HSyncEnd               dw 0
VTotalCount            dw 0
VDisplay               dw 0
VBlankStart            dw 0
VBlankEnd              dw 0
VSyncStart             dw 0
VSyncEnd               dw 0
InterlaceH             dw 0

SavedSeq1              db 0
SavedCr11              db 0
SavedExtLock0          db 0
SavedExtLockActive     db 0
SavedOwner             db 0
WriteVerifyFailed      db 0

ModeInfo               db 256 dup (0)

; Callback structures must remain resident.
CallbackRmcs           db RM_STRUCT_SIZE dup (0)
TsrRmcs                db RM_STRUCT_SIZE dup (0)
DpmiPrivateAreaRaw     db ((HDPMI_PRIVATE_PARAS*16)+15) dup (0)

ResidentEnd label byte

; ==========================================================================
; TRANSIENT INSTALLER / COMMAND REGION
; ==========================================================================


InstallerStart:
        cli
        mov     ax,cs
        mov     ss,ax
        mov     sp,offset InstallerStackTop
        sti
        mov     ds,ax
        mov     es,ax
        mov     word ptr [RealModeSegment],ax

        call    ParseCommand
        mov     byte ptr [StartupCommand],al

        cmp     al,ARG_HELP
        je      ShowHelp

        ; Existing DPMI copy?
        mov     ax,MUX_PRESENT
        int     2Fh
        cmp     ax,MUX_PRESENT_REPLY
        je      ResidentCommand

        ; /S,/D,/U,/E need an installed copy.
        cmp     byte ptr [StartupCommand],ARG_DEFAULT
        je      BeginInstall
        cmp     byte ptr [StartupCommand],ARG_INVALID
        je      BadUsage
        mov     dx,offset MsgNotResident
        call    PrintZ
        mov     ax,4C01h
        int     21h

ResidentCommand:
        cmp     byte ptr [StartupCommand],ARG_DEFAULT
        je      ShowResidentShort
        cmp     byte ptr [StartupCommand],ARG_STATUS
        je      ShowResidentStatus
        cmp     byte ptr [StartupCommand],ARG_DISABLE
        je      SendDisable
        cmp     byte ptr [StartupCommand],ARG_ENABLE
        je      SendEnable
        jmp     BadUsage

ShowHelp:
        mov     dx,offset MsgHelp
        call    PrintZ
        mov     ax,4C00h
        int     21h

BadUsage:
        mov     dx,offset MsgUsage
        call    PrintZ
        mov     ax,4C01h
        int     21h

ShowResidentShort:
        mov     ax,MUX_INFO
        int     2Fh
        cmp     ax,MUX_INFO_REPLY
        jne     StatusProtocolFail
        mov     dx,offset MsgResident
        call    PrintZ
        mov     al,byte ptr es:[di+RI_STATE]
        cmp     al,STATE_ENABLED
        jne     ShortDisabled
        mov     dx,offset MsgEnabled
        call    PrintZ
        jmp     ShortDone
ShortDisabled:
        mov     dx,offset MsgDisabled
        call    PrintZ
ShortDone:
        mov     ax,4C00h
        int     21h

ShowResidentStatus:
        call    PrintResidentStatus
        mov     ax,4C00h
        int     21h

SendDisable:
        mov     ax,MUX_CONTROL
        mov     bl,CMD_DISABLE
        int     2Fh
        cmp     ax,MUX_CONTROL_REPLY
        jne     StatusProtocolFail
        cmp     bl,CTL_BUSY
        je      ControlBusy
        cmp     bl,CTL_ALREADY_DISABLED
        je      AlreadyDisabled
        mov     dx,offset MsgDisabledNow
        call    PrintZ
        mov     ax,4C00h
        int     21h
AlreadyDisabled:
        mov     dx,offset MsgAlreadyDisabled
        call    PrintZ
        mov     ax,4C00h
        int     21h

SendEnable:
        mov     ax,MUX_CONTROL
        mov     bl,CMD_ENABLE
        int     2Fh
        cmp     ax,MUX_CONTROL_REPLY
        jne     StatusProtocolFail
        cmp     bl,CTL_BUSY
        je      ControlBusy
        cmp     bl,CTL_ALREADY_ENABLED
        je      AlreadyEnabled
        mov     dx,offset MsgEnabledNow
        call    PrintZ
        mov     ax,4C00h
        int     21h
AlreadyEnabled:
        mov     dx,offset MsgAlreadyEnabled
        call    PrintZ
        mov     ax,4C00h
        int     21h

ControlBusy:
        mov     dx,offset MsgBusy
        call    PrintZ
        mov     ax,4C01h
        int     21h

StatusProtocolFail:
        mov     dx,offset MsgProtocolFail
        call    PrintZ
        mov     ax,4C01h
        int     21h

BeginInstall:
        ; Refuse simultaneous use with the plain real-mode version.
        mov     ax,NVCRTC_INFO
        int     2Fh
        cmp     ax,NVCRTC_INFO_REPLY
        je      PlainConflict

        mov     dx,offset MsgTitle
        call    PrintZ

        ; PCI BIOS.
        mov     ax,0B101h
        int     1Ah
        jc      NoPci
        cmp     edx,20494350h
        jne     NoPci

        call    FindNvidiaVga
        jc      NoDevice

        ; PCI memory decoding.
        mov     ax,0B109h
        mov     bx,[PciBdf]
        mov     di,04h
        int     1Ah
        jc      PciFail
        test    cl,02h
        jz      NoMemDecode

        ; BAR0.
        mov     ax,0B10Ah
        mov     bx,[PciBdf]
        mov     di,10h
        int     1Ah
        jc      PciFail
        test    cl,01h
        jnz     BadBar
        mov     eax,ecx
        and     eax,0FFFFFFF0h
        test    eax,eax
        jz      BadBar
        cmp     eax,0FFFFFFF0h
        je      BadBar
        mov     dword ptr [MmioBase],eax

        ; Require VBE 3.0.
        push    cs
        pop     es
        mov     di,offset VbeInfo
        mov     ax,4F00h
        int     10h
        push    cs
        pop     ds
        push    cs
        pop     es
        cmp     ax,004Fh
        jne     NoVbe3
        cmp     word ptr [VbeInfo+4],0300h
        jb      NoVbe3

        ; DPMI host discovery.
        mov     ax,1687h
        int     2Fh
        or      ax,ax
        jnz     NoDpmi
        test    bx,0001h
        jz      NoDpmi32

        mov     word ptr [DpmiEntry],di
        mov     word ptr [DpmiEntry+2],es
        mov     word ptr [PrivateParas],si
        cmp     word ptr [PrivateParas],HDPMI_PRIVATE_PARAS
        ja      PrivateTooLarge

        call    FreeEnvironment

        ; ES:0000 private area, paragraph aligned.
        mov     bx,offset DpmiPrivateAreaRaw
        add     bx,15
        mov     cl,4
        shr     bx,cl
        mov     ax,cs
        add     ax,bx
        mov     es,ax

        mov     ax,0001h              ; 32-bit DPMI client
        call    dword ptr cs:[DpmiEntry]
        jc      DpmiSwitchFail

        mov     word ptr [DataSelector],ds

        ; Map BAR0 regions required by the resident callback.
        mov     eax,dword ptr [MmioBase]
        add     eax,PMC_PAGE_OFFSET
        mov     dword ptr [PmcPhys],eax
        call    MapPmc
        jc      MapFail

        mov     eax,dword ptr [MmioBase]
        add     eax,PEXT_PAGE_OFFSET
        mov     dword ptr [PextPhys],eax
        call    MapPext
        jc      MapFail

        mov     eax,dword ptr [MmioBase]
        add     eax,DAC_PAGE_OFFSET
        mov     dword ptr [DacPhys],eax
        call    MapDac
        jc      MapFail

        mov     eax,dword ptr [MmioBase]
        add     eax,CRTC_PAGE_OFFSET
        mov     dword ptr [CrtcPhys],eax
        call    MapCrtc
        jc      MapFail

        mov     eax,dword ptr [MmioBase]
        add     eax,VIO_PAGE_OFFSET
        mov     dword ptr [VioPhys],eax
        call    MapVio
        jc      MapFail

        ; Read chipset + crystal straps through mapped BAR0.
        mov     ax,word ptr [PmcSelector]
        mov     fs,ax
        mov     eax,dword ptr fs:[0]
        mov     dword ptr [PmcBoot0],eax

        mov     ax,word ptr [PextSelector]
        mov     fs,ax
        mov     eax,dword ptr fs:[PEXTDEV_BOOT0_PAGE]
        mov     dword ptr [Pextdev0],eax
        xor     ax,ax
        mov     fs,ax

        call    DecodeNv4x
        jc      NotNv4x
        call    DetectCrystal

        ; Allocate protected callback.
        push    ds
        push    es
        mov     ax,ds
        mov     es,ax
        xor     edi,edi
        mov     di,offset CallbackRmcs
        mov     ax,cs
        mov     ds,ax
        xor     esi,esi
        mov     si,offset CallbackProc
        mov     ax,0303h
        int     31h
        pop     es
        pop     ds
        jc      CallbackAllocFail

        mov     word ptr [CallbackSeg],cx
        mov     word ptr [CallbackOff],dx
        mov     word ptr [CallbackPtr],dx
        mov     word ptr [CallbackPtr+2],cx
        mov     byte ptr [CallbackActive],1

        ; Capture original real-mode vectors.
        mov     ax,0200h
        mov     bl,10h
        int     31h
        jc      HookInstallFail
        mov     word ptr [OldInt10],dx
        mov     word ptr [OldInt10+2],cx

        mov     ax,0200h
        mov     bl,2Fh
        int     31h
        jc      HookInstallFail
        mov     word ptr [OldInt2F],dx
        mov     word ptr [OldInt2F+2],cx

        ; Install hooks.
        mov     ax,0201h
        mov     bl,10h
        mov     cx,word ptr [RealModeSegment]
        mov     dx,offset NewInt10
        int     31h
        jc      HookInstallFail
        mov     byte ptr [Hook10Active],1

        mov     ax,0201h
        mov     bl,2Fh
        mov     cx,word ptr [RealModeSegment]
        mov     dx,offset NewInt2F
        int     31h
        jc      HookInstallFail
        mov     byte ptr [Hook2FActive],1

        ; Verify hooks.
        mov     ax,0200h
        mov     bl,10h
        int     31h
        cmp     cx,word ptr [RealModeSegment]
        jne     HookVerifyFail
        cmp     dx,offset NewInt10
        jne     HookVerifyFail

        mov     ax,0200h
        mov     bl,2Fh
        int     31h
        cmp     cx,word ptr [RealModeSegment]
        jne     HookVerifyFail
        cmp     dx,offset NewInt2F
        jne     HookVerifyFail

        ; Resident size from PSP through ResidentEnd.
        mov     dx,offset ResidentEnd
        add     dx,15
        mov     cl,4
        shr     dx,cl
        mov     word ptr [ResidentParas],dx

        call    PrintInstallInfo
        mov     dx,offset MsgInstalled
        call    PrintZ

        ; DOS AH=31h via DPMI simulated real-mode interrupt.
        call    ClearTsrRmcs
        mov     dword ptr [TsrRmcs+RM_EAX],00003100h
        xor     eax,eax
        mov     ax,word ptr [ResidentParas]
        mov     dword ptr [TsrRmcs+RM_EDX],eax

        mov     ax,ds
        mov     es,ax
        xor     edi,edi
        mov     di,offset TsrRmcs
        xor     cx,cx
        xor     bh,bh
        mov     bl,21h
        mov     ax,0300h
        int     31h

        ; Should never return.
        mov     dx,offset MsgTsrReturned
        call    PrintZ
        jmp     ExitPm2

PlainConflict:
        mov     dx,offset MsgPlainConflict
        call    PrintZ
        mov     ax,4C01h
        int     21h


; --------------------------------------------------------------------------
; DPMI mapping helpers. Each follows the ASPECTD 0800h + selector pattern.
; --------------------------------------------------------------------------

MapPmc proc near
        mov     eax,dword ptr [PmcPhys]
        mov     edx,MAP_4K
        call    MapRegionCommon
        jc      MapPmcDone
        mov     word ptr [PmcSelector],ax
        mov     dword ptr [PmcLinear],ebx
        mov     byte ptr [PmcMapActive],1
MapPmcDone:
        ret
MapPmc endp

MapPext proc near
        mov     eax,dword ptr [PextPhys]
        mov     edx,MAP_4K
        call    MapRegionCommon
        jc      MapPextDone
        mov     word ptr [PextSelector],ax
        mov     dword ptr [PextLinear],ebx
        mov     byte ptr [PextMapActive],1
MapPextDone:
        ret
MapPext endp

MapDac proc near
        mov     eax,dword ptr [DacPhys]
        mov     edx,MAP_4K
        call    MapRegionCommon
        jc      MapDacDone
        mov     word ptr [DacSelector],ax
        mov     dword ptr [DacLinear],ebx
        mov     byte ptr [DacMapActive],1
MapDacDone:
        ret
MapDac endp

MapCrtc proc near
        mov     eax,dword ptr [CrtcPhys]
        mov     edx,MAP_DUAL
        call    MapRegionCommon
        jc      MapCrtcDone
        mov     word ptr [CrtcSelector],ax
        mov     dword ptr [CrtcLinear],ebx
        mov     byte ptr [CrtcMapActive],1
MapCrtcDone:
        ret
MapCrtc endp

MapVio proc near
        mov     eax,dword ptr [VioPhys]
        mov     edx,MAP_DUAL
        call    MapRegionCommon
        jc      MapVioDone
        mov     word ptr [VioSelector],ax
        mov     dword ptr [VioLinear],ebx
        mov     byte ptr [VioMapActive],1
MapVioDone:
        ret
MapVio endp

; EAX = physical address, EDX = byte size.
; Returns AX = selector, EBX = mapped linear base, CF clear.
MapRegionCommon proc near
        mov     dword ptr [MapWorkPhys],eax
        mov     dword ptr [MapWorkSize],edx
        mov     word ptr [MapWorkSelector],0
        mov     byte ptr [MapWorkMapped],0

        mov     bx,word ptr [MapWorkPhys+2]
        mov     cx,word ptr [MapWorkPhys]
        mov     si,word ptr [MapWorkSize+2]
        mov     di,word ptr [MapWorkSize]
        mov     ax,0800h
        int     31h
        jc      MrcFail

        mov     word ptr [MapWorkLinear],cx
        mov     word ptr [MapWorkLinear+2],bx
        mov     byte ptr [MapWorkMapped],1

        mov     ax,0000h
        mov     cx,1
        int     31h
        jc      MrcCleanupMap
        mov     word ptr [MapWorkSelector],ax

        mov     bx,ax
        mov     cx,word ptr [MapWorkLinear+2]
        mov     dx,word ptr [MapWorkLinear]
        mov     ax,0007h
        int     31h
        jc      MrcCleanupSel

        mov     eax,dword ptr [MapWorkSize]
        dec     eax
        mov     dx,ax
        shr     eax,16
        mov     cx,ax
        mov     bx,word ptr [MapWorkSelector]
        mov     ax,0008h
        int     31h
        jc      MrcCleanupSel

        xor     ebx,ebx
        mov     bx,word ptr [MapWorkLinear+2]
        shl     ebx,16
        mov     bx,word ptr [MapWorkLinear]
        mov     ax,word ptr [MapWorkSelector]
        clc
        ret

MrcCleanupSel:
        mov     bx,word ptr [MapWorkSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [MapWorkSelector],0
MrcCleanupMap:
        cmp     byte ptr [MapWorkMapped],0
        je      MrcFail
        mov     bx,word ptr [MapWorkLinear+2]
        mov     cx,word ptr [MapWorkLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [MapWorkMapped],0
MrcFail:
        stc
        ret
MapRegionCommon endp

; --------------------------------------------------------------------------
; Hardware identification.
; --------------------------------------------------------------------------
DecodeNv4x proc near
        mov     eax,dword ptr [PmcBoot0]
        shr     eax,20
        and     al,0FFh
        mov     byte ptr [Chipset],al
        mov     ah,al
        and     ah,0F0h
        cmp     ah,040h
        jne     DnvBad
        clc
        ret
DnvBad:
        stc
        ret
DecodeNv4x endp

DetectCrystal proc near
        mov     eax,dword ptr [Pextdev0]
        test    eax,00400000h
        jz      DcNot27
        mov     dword ptr [CrystalKHz],27000
        ret
DcNot27:
        test    eax,00000040h
        jz      Dc135
        mov     dword ptr [CrystalKHz],14318
        ret
Dc135:
        mov     dword ptr [CrystalKHz],13500
        ret
DetectCrystal endp

FindNvidiaVga proc near
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ecx

        xor     si,si
FnvNext:
        mov     ax,0B103h
        mov     ecx,PCI_CLASS_VGA
        int     1Ah
        jc      FnvFail
        mov     word ptr [CandidateBdf],bx

        mov     ax,0B10Ah
        mov     bx,word ptr [CandidateBdf]
        xor     di,di
        int     1Ah
        jc      FnvAdvance
        cmp     cx,NV_VENDOR
        jne     FnvAdvance

        mov     bx,word ptr [CandidateBdf]
        mov     word ptr [PciBdf],bx
        mov     dword ptr [PciId],ecx
        clc
        jmp     short FnvDone
FnvAdvance:
        inc     si
        jmp     FnvNext
FnvFail:
        stc
FnvDone:
        pop     ecx
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
FindNvidiaVga endp

; --------------------------------------------------------------------------
; Command parser.
; --------------------------------------------------------------------------
ParseCommand proc near
        push    bx
        push    si

        xor     bx,bx
        mov     bl,byte ptr cs:[80h]
        mov     si,81h
PcSkip:
        cmp     bx,0
        je      PcDefault
        mov     al,byte ptr cs:[si]
        cmp     al,' '
        je      PcSkipOne
        cmp     al,9
        jne     PcPrefix
PcSkipOne:
        inc     si
        dec     bx
        jmp     PcSkip

PcPrefix:
        cmp     al,'/'
        je      PcLetter
        cmp     al,'-'
        jne     PcInvalid
PcLetter:
        inc     si
        dec     bx
        jz      PcInvalid
        mov     al,byte ptr cs:[si]
        and     al,0DFh
        mov     ah,al
        inc     si
        dec     bx

PcTail:
        cmp     bx,0
        je      PcClassify
        mov     al,byte ptr cs:[si]
        cmp     al,' '
        je      PcTailOne
        cmp     al,9
        jne     PcInvalid
PcTailOne:
        inc     si
        dec     bx
        jmp     PcTail

PcClassify:
        mov     al,ARG_INVALID
        cmp     ah,'S'
        je      PcStatus
        cmp     ah,'D'
        je      PcDisable
        cmp     ah,'U'
        je      PcDisable
        cmp     ah,'E'
        je      PcEnable
        cmp     ah,'?'
        je      PcHelp
        jmp     short PcDone
PcStatus:
        mov     al,ARG_STATUS
        jmp     short PcDone
PcDisable:
        mov     al,ARG_DISABLE
        jmp     short PcDone
PcEnable:
        mov     al,ARG_ENABLE
        jmp     short PcDone
PcHelp:
        mov     al,ARG_HELP
        jmp     short PcDone
PcDefault:
        mov     al,ARG_DEFAULT
        jmp     short PcDone
PcInvalid:
        mov     al,ARG_INVALID
PcDone:
        pop     si
        pop     bx
        ret
ParseCommand endp

; --------------------------------------------------------------------------
; Status.
; --------------------------------------------------------------------------
CaptureResidentStatus proc near
        mov     ax,MUX_INFO
        int     2Fh
        cmp     ax,MUX_INFO_REPLY
        jne     CrsFail

        mov     al,byte ptr es:[di+RI_STATE]
        mov     byte ptr [StState],al
        mov     ax,word ptr es:[di+RI_RES_PARAS]
        mov     word ptr [StParas],ax
        mov     ax,word ptr es:[di+RI_PCI_BDF]
        mov     word ptr [StBdf],ax
        mov     eax,dword ptr es:[di+RI_PCI_ID]
        mov     dword ptr [StPciId],eax
        mov     eax,dword ptr es:[di+RI_BAR]
        mov     dword ptr [StBar],eax
        mov     eax,dword ptr es:[di+RI_BOOT0]
        mov     dword ptr [StBoot0],eax
        mov     al,byte ptr es:[di+RI_CHIPSET]
        mov     byte ptr [StChipset],al
        mov     eax,dword ptr es:[di+RI_CRYSTAL]
        mov     dword ptr [StCrystal],eax
        mov     ax,word ptr es:[di+RI_REQUESTS]
        mov     word ptr [StReq],ax
        mov     ax,word ptr es:[di+RI_APPLIED]
        mov     word ptr [StApplied],ax
        mov     ax,word ptr es:[di+RI_FAILED]
        mov     word ptr [StFailed],ax
        mov     ax,word ptr es:[di+RI_LASTBX]
        mov     word ptr [StBx],ax
        mov     ax,word ptr es:[di+RI_MODEINFO]
        mov     word ptr [StModeInfo],ax
        mov     ax,word ptr es:[di+RI_LASTBIOS]
        mov     word ptr [StBios],ax
        mov     al,byte ptr es:[di+RI_LASTRESULT]
        mov     byte ptr [StResult],al
        mov     al,byte ptr es:[di+RI_LASTHEAD]
        mov     byte ptr [StHead],al
        mov     ax,word ptr es:[di+RI_HTOTAL]
        mov     word ptr [StHT],ax
        mov     ax,word ptr es:[di+RI_HSTART]
        mov     word ptr [StHS],ax
        mov     ax,word ptr es:[di+RI_HEND]
        mov     word ptr [StHE],ax
        mov     ax,word ptr es:[di+RI_VTOTAL]
        mov     word ptr [StVT],ax
        mov     ax,word ptr es:[di+RI_VSTART]
        mov     word ptr [StVS],ax
        mov     ax,word ptr es:[di+RI_VEND]
        mov     word ptr [StVE],ax
        mov     al,byte ptr es:[di+RI_CRTCFLAGS]
        mov     byte ptr [StFlags],al
        mov     eax,dword ptr es:[di+RI_PIXELCLOCK]
        mov     dword ptr [StPixel],eax
        mov     ax,word ptr es:[di+RI_REFRESH]
        mov     word ptr [StRefresh],ax
        mov     eax,dword ptr es:[di+RI_ACTUALKHZ]
        mov     dword ptr [StActualKHz],eax
        mov     eax,dword ptr es:[di+RI_ACTREFRESH]
        mov     dword ptr [StActualRefresh],eax
        clc
        ret
CrsFail:
        stc
        ret
CaptureResidentStatus endp

PrintResidentStatus proc near
        call    CaptureResidentStatus
        jc      StatusProtocolFail

        mov     dx,offset MsgStatusHeader
        call    PrintZ

        mov     dx,offset MsgState
        call    PrintZ
        cmp     byte ptr [StState],STATE_ENABLED
        jne     PrsDisabled
        mov     dx,offset MsgEnabled
        call    PrintZ
        jmp     short PrsStateDone
PrsDisabled:
        mov     dx,offset MsgDisabled
        call    PrintZ
PrsStateDone:

        mov     dx,offset MsgPciBdf
        call    PrintZ
        mov     ax,word ptr [StBdf]
        call    PrintHex16
        call    PrintCRLF

        mov     dx,offset MsgPciId
        call    PrintZ
        mov     eax,dword ptr [StPciId]
        call    PrintHex32
        call    PrintCRLF

        mov     dx,offset MsgBar
        call    PrintZ
        mov     eax,dword ptr [StBar]
        call    PrintHex32
        call    PrintCRLF

        mov     dx,offset MsgBoot0
        call    PrintZ
        mov     eax,dword ptr [StBoot0]
        call    PrintHex32
        call    PrintCRLF

        mov     dx,offset MsgChipset
        call    PrintZ
        mov     al,byte ptr [StChipset]
        call    PrintHex8
        call    PrintCRLF

        mov     dx,offset MsgCrystal
        call    PrintZ
        mov     eax,dword ptr [StCrystal]
        call    PrintDec32
        mov     dx,offset MsgKHz
        call    PrintZ

        mov     dx,offset MsgReqCount
        call    PrintZ
        mov     ax,word ptr [StReq]
        call    PrintDec16
        call    PrintCRLF

        mov     dx,offset MsgAppliedCount
        call    PrintZ
        mov     ax,word ptr [StApplied]
        call    PrintDec16
        call    PrintCRLF

        mov     dx,offset MsgFailedCount
        call    PrintZ
        mov     ax,word ptr [StFailed]
        call    PrintDec16
        call    PrintCRLF

        mov     dx,offset MsgLastBx
        call    PrintZ
        mov     ax,word ptr [StBx]
        call    PrintHex16
        call    PrintCRLF

        mov     dx,offset MsgLastModeInfo
        call    PrintZ
        mov     ax,word ptr [StModeInfo]
        call    PrintHex16
        call    PrintCRLF

        mov     dx,offset MsgLastBios
        call    PrintZ
        mov     ax,word ptr [StBios]
        call    PrintHex16
        call    PrintCRLF

        mov     dx,offset MsgLastResult
        call    PrintZ
        mov     al,byte ptr [StResult]
        call    PrintHex8
        call    PrintCRLF

        mov     dx,offset MsgLastHead
        call    PrintZ
        mov     al,byte ptr [StHead]
        call    PrintHex8
        call    PrintCRLF

        mov     dx,offset MsgLastH
        call    PrintZ
        mov     ax,word ptr [StHT]
        call    PrintDec16
        mov     dl,'/'
        call    PutCh
        mov     ax,word ptr [StHS]
        call    PrintDec16
        mov     dl,'/'
        call    PutCh
        mov     ax,word ptr [StHE]
        call    PrintDec16
        call    PrintCRLF

        mov     dx,offset MsgLastV
        call    PrintZ
        mov     ax,word ptr [StVT]
        call    PrintDec16
        mov     dl,'/'
        call    PutCh
        mov     ax,word ptr [StVS]
        call    PrintDec16
        mov     dl,'/'
        call    PutCh
        mov     ax,word ptr [StVE]
        call    PrintDec16
        call    PrintCRLF

        mov     dx,offset MsgLastFlags
        call    PrintZ
        mov     al,byte ptr [StFlags]
        call    PrintHex8
        call    PrintCRLF

        mov     dx,offset MsgLastPixel
        call    PrintZ
        mov     eax,dword ptr [StPixel]
        call    PrintDec32
        mov     dx,offset MsgHz
        call    PrintZ

        mov     dx,offset MsgLastReqRefresh
        call    PrintZ
        movzx   eax,word ptr [StRefresh]
        call    PrintRefresh100
        mov     dx,offset MsgHz
        call    PrintZ

        mov     dx,offset MsgLastClock
        call    PrintZ
        mov     eax,dword ptr [StActualKHz]
        call    PrintDec32
        mov     dx,offset MsgKHz
        call    PrintZ

        mov     dx,offset MsgLastActRefresh
        call    PrintZ
        mov     eax,dword ptr [StActualRefresh]
        call    PrintRefresh100
        mov     dx,offset MsgHz
        call    PrintZ

        ret
PrintResidentStatus endp

; --------------------------------------------------------------------------
; DPMI resource cleanup for installation failures only.
; --------------------------------------------------------------------------
RestoreHooks proc near
        cmp     byte ptr [Hook2FActive],0
        je      RhNo2f
        mov     ax,0201h
        mov     bl,2Fh
        mov     cx,word ptr [OldInt2F+2]
        mov     dx,word ptr [OldInt2F]
        int     31h
        mov     byte ptr [Hook2FActive],0
RhNo2f:
        cmp     byte ptr [Hook10Active],0
        je      RhDone
        mov     ax,0201h
        mov     bl,10h
        mov     cx,word ptr [OldInt10+2]
        mov     dx,word ptr [OldInt10]
        int     31h
        mov     byte ptr [Hook10Active],0
RhDone:
        ret
RestoreHooks endp

CleanupDpmi proc near
        call    RestoreHooks

        cmp     byte ptr [CallbackActive],0
        je      CdNoCb
        mov     cx,word ptr [CallbackSeg]
        mov     dx,word ptr [CallbackOff]
        mov     ax,0304h
        int     31h
        mov     byte ptr [CallbackActive],0
CdNoCb:

        cmp     word ptr [VioSelector],0
        je      CdNoVioSel
        mov     bx,word ptr [VioSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [VioSelector],0
CdNoVioSel:
        cmp     word ptr [CrtcSelector],0
        je      CdNoCrtcSel
        mov     bx,word ptr [CrtcSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [CrtcSelector],0
CdNoCrtcSel:
        cmp     word ptr [DacSelector],0
        je      CdNoDacSel
        mov     bx,word ptr [DacSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [DacSelector],0
CdNoDacSel:
        cmp     word ptr [PextSelector],0
        je      CdNoPextSel
        mov     bx,word ptr [PextSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [PextSelector],0
CdNoPextSel:
        cmp     word ptr [PmcSelector],0
        je      CdNoPmcSel
        mov     bx,word ptr [PmcSelector]
        mov     ax,0001h
        int     31h
        mov     word ptr [PmcSelector],0
CdNoPmcSel:

        cmp     byte ptr [VioMapActive],0
        je      CdNoVioMap
        mov     bx,word ptr [VioLinear+2]
        mov     cx,word ptr [VioLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [VioMapActive],0
CdNoVioMap:
        cmp     byte ptr [CrtcMapActive],0
        je      CdNoCrtcMap
        mov     bx,word ptr [CrtcLinear+2]
        mov     cx,word ptr [CrtcLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [CrtcMapActive],0
CdNoCrtcMap:
        cmp     byte ptr [DacMapActive],0
        je      CdNoDacMap
        mov     bx,word ptr [DacLinear+2]
        mov     cx,word ptr [DacLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [DacMapActive],0
CdNoDacMap:
        cmp     byte ptr [PextMapActive],0
        je      CdNoPextMap
        mov     bx,word ptr [PextLinear+2]
        mov     cx,word ptr [PextLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [PextMapActive],0
CdNoPextMap:
        cmp     byte ptr [PmcMapActive],0
        je      CdDone
        mov     bx,word ptr [PmcLinear+2]
        mov     cx,word ptr [PmcLinear]
        mov     ax,0801h
        int     31h
        mov     byte ptr [PmcMapActive],0
CdDone:
        ret
CleanupDpmi endp

ClearTsrRmcs proc near
        push    ax
        push    cx
        push    di
        push    es
        mov     ax,ds
        mov     es,ax
        mov     di,offset TsrRmcs
        xor     ax,ax
        mov     cx,RM_STRUCT_SIZE/2
        cld
        rep     stosw
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret
ClearTsrRmcs endp

FreeEnvironment proc near
        push    ax
        push    es
        mov     ax,word ptr cs:[2Ch]
        or      ax,ax
        jz      FeDone
        mov     es,ax
        mov     ah,49h
        int     21h
        jc      FeDone
        mov     word ptr cs:[2Ch],0
FeDone:
        pop     es
        pop     ax
        ret
FreeEnvironment endp

; --------------------------------------------------------------------------
; Installer/status console helpers.
; --------------------------------------------------------------------------
PrintInstallInfo proc near
        mov     dx,offset MsgPciBdf
        call    PrintZ
        mov     ax,word ptr [PciBdf]
        call    PrintHex16
        call    PrintCRLF
        mov     dx,offset MsgPciId
        call    PrintZ
        mov     eax,dword ptr [PciId]
        call    PrintHex32
        call    PrintCRLF
        mov     dx,offset MsgBar
        call    PrintZ
        mov     eax,dword ptr [MmioBase]
        call    PrintHex32
        call    PrintCRLF
        mov     dx,offset MsgBoot0
        call    PrintZ
        mov     eax,dword ptr [PmcBoot0]
        call    PrintHex32
        call    PrintCRLF
        mov     dx,offset MsgChipset
        call    PrintZ
        mov     al,byte ptr [Chipset]
        call    PrintHex8
        call    PrintCRLF
        mov     dx,offset MsgCrystal
        call    PrintZ
        mov     eax,dword ptr [CrystalKHz]
        call    PrintDec32
        mov     dx,offset MsgKHz
        call    PrintZ
        ret
PrintInstallInfo endp

PrintZ proc near
        push    ax
        push    si
        mov     si,dx
PzLoop:
        lodsb
        or      al,al
        jz      PzDone
        mov     dl,al
        call    PutCh
        jmp     PzLoop
PzDone:
        pop     si
        pop     ax
        ret
PrintZ endp

PrintCRLF proc near
        mov     dx,offset MsgCRLF
        call    PrintZ
        ret
PrintCRLF endp

PutCh proc near
        push    ax
        mov     ah,02h
        int     21h
        pop     ax
        ret
PutCh endp

PrintHex32 proc near
        push    eax
        ror     eax,16
        call    PrintHex16
        ror     eax,16
        call    PrintHex16
        pop     eax
        ret
PrintHex32 endp

PrintHex16 proc near
        push    ax
        mov     al,ah
        call    PrintHex8
        pop     ax
        call    PrintHex8
        ret
PrintHex16 endp

PrintHex8 proc near
        push    ax
        push    bx
        mov     bl,al
        mov     al,bl
        shr     al,4
        call    PrintNibble
        mov     al,bl
        and     al,0Fh
        call    PrintNibble
        pop     bx
        pop     ax
        ret
PrintHex8 endp

PrintNibble proc near
        and     al,0Fh
        cmp     al,9
        jbe     PnDigit
        add     al,'A'-10
        jmp     short PnOut
PnDigit:
        add     al,'0'
PnOut:
        mov     dl,al
        call    PutCh
        ret
PrintNibble endp

PrintDec16 proc near
        push    eax
        movzx   eax,ax
        call    PrintDec32
        pop     eax
        ret
PrintDec16 endp

PrintDec32 proc near
        push    eax
        push    ebx
        push    ecx
        push    edx
        xor     ecx,ecx
        mov     ebx,10
        test    eax,eax
        jnz     PdLoop
        mov     dl,'0'
        call    PutCh
        jmp     short PdDone
PdLoop:
        xor     edx,edx
        div     ebx
        push    dx
        inc     cx
        test    eax,eax
        jnz     PdLoop
PdOut:
        pop     dx
        add     dl,'0'
        call    PutCh
        loop    PdOut
PdDone:
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax
        ret
PrintDec32 endp

PrintRefresh100 proc near
        push    eax
        push    ebx
        push    ecx
        push    edx
        xor     edx,edx
        mov     ebx,100
        div     ebx
        mov     ecx,edx
        call    PrintDec32
        mov     dl,'.'
        call    PutCh
        mov     eax,ecx
        cmp     eax,10
        jae     PrNoZero
        mov     dl,'0'
        call    PutCh
PrNoZero:
        call    PrintDec32
        pop     edx
        pop     ecx
        pop     ebx
        pop     eax
        ret
PrintRefresh100 endp

; --------------------------------------------------------------------------
; Error exits.
; --------------------------------------------------------------------------
NoPci:
        mov     dx,offset MsgNoPci
        jmp     RealError
NoDevice:
        mov     dx,offset MsgNoDevice
        jmp     RealError
PciFail:
        mov     dx,offset MsgPciFail
        jmp     RealError
NoMemDecode:
        mov     dx,offset MsgNoMemDecode
        jmp     RealError
BadBar:
        mov     dx,offset MsgBadBar
        jmp     RealError
NoVbe3:
        mov     dx,offset MsgNoVbe3
        jmp     RealError
NoDpmi:
        mov     dx,offset MsgNoDpmi
        jmp     RealError
NoDpmi32:
        mov     dx,offset MsgNo32
        jmp     RealError
PrivateTooLarge:
        mov     dx,offset MsgPrivateLarge
        call    PrintZ
        mov     ax,word ptr [PrivateParas]
        call    PrintHex16
        call    PrintCRLF
        mov     ax,4C01h
        int     21h
DpmiSwitchFail:
        mov     dx,offset MsgSwitchFail
        jmp     RealError

RealError:
        call    PrintZ
        mov     ax,4C01h
        int     21h

MapFail:
        mov     dx,offset MsgMapFail
        jmp     PmError
NotNv4x:
        mov     dx,offset MsgNotNv4x
        jmp     PmError
CallbackAllocFail:
        mov     dx,offset MsgCallbackFail
        jmp     PmError
HookInstallFail:
        mov     dx,offset MsgHookFail
        jmp     PmError
HookVerifyFail:
        mov     dx,offset MsgVerifyFail
        jmp     PmError

PmError:
        call    PrintZ
        jmp     ExitPm1

ExitPm2:
        call    CleanupDpmi
        mov     ax,4C02h
        int     21h
ExitPm1:
        call    CleanupDpmi
        mov     ax,4C01h
        int     21h

; --------------------------------------------------------------------------
; Transient variables.
; --------------------------------------------------------------------------
DpmiEntry              dd 0
PrivateParas           dw 0
RealModeSegment        dw 0
CallbackSeg            dw 0
CallbackOff            dw 0
StartupCommand         db ARG_DEFAULT
CandidateBdf           dw 0

PmcPhys                dd 0
PextPhys               dd 0
DacPhys                dd 0
CrtcPhys               dd 0
VioPhys                dd 0

PmcLinear              dd 0
PextLinear             dd 0
DacLinear              dd 0
CrtcLinear             dd 0
VioLinear              dd 0

PmcMapActive           db 0
PextMapActive          db 0
DacMapActive           db 0
CrtcMapActive          db 0
VioMapActive           db 0
CallbackActive         db 0
Hook10Active           db 0
Hook2FActive           db 0

MapWorkPhys            dd 0
MapWorkSize            dd 0
MapWorkLinear          dd 0
MapWorkSelector        dw 0
MapWorkMapped          db 0

VbeInfo                db 512 dup (0)

; Status snapshot.
StState                db 0
StParas                dw 0
StBdf                  dw 0
StPciId                dd 0
StBar                  dd 0
StBoot0                dd 0
StChipset              db 0
StCrystal              dd 0
StReq                  dw 0
StApplied              dw 0
StFailed               dw 0
StBx                   dw 0
StModeInfo             dw 0
StBios                 dw 0
StResult               db 0
StHead                 db 0
StHT                   dw 0
StHS                   dw 0
StHE                   dw 0
StVT                   dw 0
StVS                   dw 0
StVE                   dw 0
StFlags                db 0
StPixel                dd 0
StRefresh              dw 0
StActualKHz            dd 0
StActualRefresh        dd 0

; --------------------------------------------------------------------------
; Messages.
; --------------------------------------------------------------------------
MsgTitle          db 'NVCRTCD 1.0 - NVIDIA NV4x VBE 3.0 custom CRTC fix (DPMI)',13,10,0
MsgInstalled      db 'NVCRTCD resident. Load UniRefresh (if needed) after NVCRTCD.',13,10
                  db 'Use /S for status; /D or /U disables; /E re-enables.',13,10,0
MsgResident       db 'NVCRTCD resident: ',0
MsgEnabled        db 'enabled',13,10,0
MsgDisabled       db 'disabled',13,10,0
MsgDisabledNow    db 'NVCRTCD: disabled (resident client remains loaded).',13,10,0
MsgAlreadyDisabled db 'NVCRTCD: already disabled.',13,10,0
MsgEnabledNow     db 'NVCRTCD: enabled.',13,10,0
MsgAlreadyEnabled db 'NVCRTCD: already enabled.',13,10,0
MsgBusy           db 'ERROR: NVCRTCD is busy with a mode change.',13,10,0
MsgProtocolFail   db 'ERROR: resident control/status protocol failed.',13,10,0
MsgNotResident    db 'ERROR: NVCRTCD is not resident.',13,10,0
MsgPlainConflict  db 'ERROR: plain real-mode NVCRTC is resident. Remove it before NVCRTCD.',13,10,0

MsgStatusHeader   db 'NVCRTCD resident status:',13,10,0
MsgState          db 'State                = ',0
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
MsgLastModeInfo   db 'Last 4F01 AX return  = ',0
MsgLastBios       db 'Last 4F02 AX return  = ',0
MsgLastResult     db 'Last result code     = ',0
MsgLastHead       db 'Last analog CRTC     = ',0
MsgLastH          db 'Last H total/start/end = ',0
MsgLastV          db 'Last V total/start/end = ',0
MsgLastFlags      db 'Last CRTC flags      = ',0
MsgLastPixel      db 'Requested pixel clock= ',0
MsgLastReqRefresh db 'Requested VFreq      = ',0
MsgLastClock      db 'Programmed clock     = ',0
MsgLastActRefresh db 'Calculated VFreq     = ',0
MsgCRLF           db 13,10,0

MsgUsage          db 'Usage: NVCRTCD [/S|/D|/U|/E|/?]',13,10,0
MsgHelp           db 'NVCRTCD      install/show state',13,10
                  db '/S detailed status',13,10
                  db '/D,/U disable (logical; DPMI client stays resident)',13,10
                  db '/E re-enable',13,10,0
MsgNoPci          db 'ERROR: PCI BIOS not available.',13,10,0
MsgNoDevice       db 'ERROR: no NVIDIA VGA-class PCI device found.',13,10,0
MsgPciFail        db 'ERROR: PCI configuration read failed.',13,10,0
MsgNoMemDecode    db 'ERROR: PCI memory decoding is disabled.',13,10,0
MsgBadBar         db 'ERROR: invalid NVIDIA BAR0.',13,10,0
MsgNoVbe3         db 'ERROR: BIOS does not report VBE 3.0.',13,10,0
MsgNoDpmi         db 'ERROR: no resident DPMI host detected.',13,10,0
MsgNo32           db 'ERROR: DPMI host does not support 32-bit clients.',13,10,0
MsgPrivateLarge   db 'ERROR: DPMI private area is larger than supported. Paras=',0
MsgSwitchFail     db 'ERROR: initial DPMI switch failed.',13,10,0
MsgMapFail        db 'ERROR: NVIDIA BAR0 DPMI physical mapping failed.',13,10,0
MsgNotNv4x        db 'ERROR: NVIDIA GPU is not NV4x/Curie (chipset 40h..4Fh).',13,10,0
MsgCallbackFail   db 'ERROR: DPMI real-mode callback allocation failed.',13,10,0
MsgHookFail       db 'ERROR: real-mode interrupt hook installation failed.',13,10,0
MsgVerifyFail     db 'ERROR: installed real-mode vectors did not verify.',13,10,0
MsgTsrReturned    db 'ERROR: DOS TSR request unexpectedly returned; installation rolled back.',13,10,0

InstallerStack         db 1024 dup (0)
InstallerStackTop      label byte

end start
