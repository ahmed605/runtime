; Licensed to the .NET Foundation under one or more agreements.
; The .NET Foundation licenses this file to you under the MIT license.

#include "ksarm.h"

#include "asmconstants.h"

#include "asmmacros.h"

    IMPORT TheUMEntryPrestubWorker
    IMPORT PreStubWorker
    IMPORT PInvokeImportWorker
    IMPORT VSD_ResolveWorker

    IMPORT CallDescrWorkerUnwindFrameChainHandler
    IMPORT UMEntryPrestubUnwindFrameChainHandler

#ifdef FEATURE_HIJACK
    IMPORT OnHijackWorker
#endif ; FEATURE_HIJACK

    IMPORT GetCurrentSavedRedirectContext

    ;; Import to support cross-module external method invocation in ngen images
    IMPORT ExternalMethodFixupWorker

#ifdef FEATURE_READYTORUN
    IMPORT DynamicHelperWorker
#endif

    IMPORT JIT_RareDisableHelperWorker

    IMPORT JIT_WriteBarrier_Loc

    IMPORT g_TrapReturningThreads
    IMPORT g_pPollGC

#ifdef FEATURE_TIERED_COMPILATION
    IMPORT OnCallCountThresholdReached
#endif

    TEXTAREA

;; LPVOID __stdcall GetCurrentIP(void);
    LEAF_ENTRY GetCurrentIP
        mov     r0, lr
        bx      lr
    LEAF_END

;; LPVOID __stdcall GetCurrentSP(void);
    LEAF_ENTRY GetCurrentSP
        mov     r0, sp
        bx      lr
    LEAF_END

;;-----------------------------------------------------------------------------
;; This helper routine enregisters the appropriate arguments and makes the
;; actual call.
;;-----------------------------------------------------------------------------
;;void CallDescrWorkerInternal(CallDescrData * pCallDescrData);
        NESTED_ENTRY CallDescrWorkerInternal,,CallDescrWorkerUnwindFrameChainHandler
        PROLOG_PUSH         {r4,r5,r7,lr}
        PROLOG_STACK_SAVE   r7

        mov     r5,r0 ; save pCallDescrData in r5

        ldr     r1, [r5,#CallDescrData__numStackSlots]
        cbz     r1, Ldonestack

        ;; Add frame padding to ensure frame size is a multiple of 8 (a requirement of the OS ABI).
        ;; We push four registers (above) and numStackSlots arguments (below). If this comes to an odd number
        ;; of slots we must pad with another. This simplifies to "if the low bit of numStackSlots is set,
        ;; extend the stack another four bytes".
        lsls    r2, r1, #2
        and     r3, r2, #4
        sub     sp, sp, r3

        ;; This loop copies numStackSlots words
        ;; from [pSrcEnd-4,pSrcEnd-8,...] to [sp-4,sp-8,...]
        ldr     r0, [r5,#CallDescrData__pSrc]
        add     r0,r0,r2
Lstackloop
        ldr     r2, [r0,#-4]!
        str     r2, [sp,#-4]!
        subs    r1, r1, #1
        bne     Lstackloop
Ldonestack

        ;; If FP arguments are supplied in registers (r3 != NULL) then initialize all of them from the pointer
        ;; given in r3. Do not use "it" since it faults in floating point even when the instruction is not executed.
        ldr     r3, [r5,#CallDescrData__pFloatArgumentRegisters]
        cbz     r3, LNoFloatingPoint
        vldm    r3, {s0-s15}
LNoFloatingPoint

        ;; Copy [pArgumentRegisters, ..., pArgumentRegisters + 12]
        ;; into r0, ..., r3

        ldr     r4, [r5,#CallDescrData__pArgumentRegisters]
        ldm     r4, {r0-r3}

        CHECK_STACK_ALIGNMENT

        ;; call pTarget
        ;; Note that remoting expect target in r4.
        ldr     r4, [r5,#CallDescrData__pTarget]
        blx     r4
LCallDescrWorkerInternalReturnAddress

        ldr     r3, [r5,#CallDescrData__fpReturnSize]

        ;; Save FP return value if appropriate
        cbz     r3, LFloatingPointReturnDone

        ;; Float return case
        ;; Do not use "it" since it faults in floating point even when the instruction is not executed.
        cmp     r3, #4
        bne     LNoFloatReturn
        vmov    r0, s0
        b       LFloatingPointReturnDone
LNoFloatReturn

        ;; Double return case
        ;; Do not use "it" since it faults in floating point even when the instruction is not executed.
        cmp     r3, #8
        bne     LNoDoubleReturn
        vmov    r0, r1, s0, s1
        b       LFloatingPointReturnDone
LNoDoubleReturn

        add     r2, r5, #CallDescrData__returnValue

        cmp     r3, #16
        bne     LNoFloatHFAReturn
        vstm    r2, {s0-s3}
        b       LReturnDone
LNoFloatHFAReturn

        cmp     r3, #32
        bne     LNoDoubleHFAReturn
        vstm    r2, {d0-d3}
        b       LReturnDone
LNoDoubleHFAReturn

        EMIT_BREAKPOINT ; Unreachable

LFloatingPointReturnDone

        ;; Save return value into retbuf
        str     r0, [r5, #(CallDescrData__returnValue + 0)]
        str     r1, [r5, #(CallDescrData__returnValue + 4)]

LReturnDone

#ifdef _DEBUG
        ;; trash the floating point registers to ensure that the HFA return values
        ;; won't survive by accident
        vldm    sp, {d0-d3}
#endif

        EPILOG_STACK_RESTORE    r7
        EPILOG_POP              {r4,r5,r7,pc}

        ; The offset of the return address of the call to the target above. Used by the runtime to
        ; recognize the CallDescrWorkerInternal frame while walking the stack.
        ALIGN 4
        PATCH_LABEL CallDescrWorkerInternalReturnAddressOffset
        DCD LCallDescrWorkerInternalReturnAddress - CallDescrWorkerInternal

        NESTED_END

; ------------------------------------------------------------------

;
; r12 = UMEntryThunkData*
;
        NESTED_ENTRY TheUMEntryPrestub,,UMEntryPrestubUnwindFrameChainHandler

        PROLOG_PUSH         {r0-r4,lr}
        PROLOG_VPUSH        {d0-d7}

        CHECK_STACK_ALIGNMENT

        mov     r0, r12
        bl      TheUMEntryPrestubWorker

        ; Record real target address in r12.
        mov     r12, r0

        ; Epilog
        EPILOG_VPOP         {d0-d7}
        EPILOG_POP          {r0-r4,lr}
        EPILOG_BRANCH_REG   r12

        NESTED_END

; ------------------------------------------------------------------

        NESTED_ENTRY ThePreStub

        PROLOG_WITH_TRANSITION_BLOCK

        add         r0, sp, #__PWTB_TransitionBlock ; pTransitionBlock
        mov         r1, r12                         ; pMethodDesc

        bl          PreStubWorker

        mov         r12, r0

        EPILOG_WITH_TRANSITION_BLOCK_TAILCALL
        EPILOG_BRANCH_REG   r12

        NESTED_END

; ------------------------------------------------------------------
; This method does nothing. It's just a fixed function for the debugger to put a breakpoint on.
        LEAF_ENTRY ThePreStubPatch
        nop
        GLOBAL_LABEL ThePreStubPatchLabel
        bx      lr
        LEAF_END

; ------------------------------------------------------------------
; The call in PInvokeImportPrecode points to this function.
        NESTED_ENTRY PInvokeImportThunk

        PROLOG_PUSH {r0-r4,lr}                          ; Spill general argument registers, return address and
                                                        ; arbitrary register to keep stack aligned
        PROLOG_VPUSH {d0-d7}                            ; Spill floating point argument registers

        CHECK_STACK_ALIGNMENT

        mov     r0, r12
        bl      PInvokeImportWorker
        mov     r12, r0

        EPILOG_VPOP {d0-d7}
        EPILOG_POP {r0-r4,lr}

        ; If we got back from PInvokeImportWorker, the MD has been successfully
        ; linked. Proceed to execute the original DLL call.
        EPILOG_BRANCH_REG r12

        NESTED_END

; ------------------------------------------------------------------
; void ResolveWorkerAsmStub(r0, r1, r2, r3, r4:IndirectionCellAndFlags, r12:DispatchToken)
;
; The stub dispatch thunk which transfers control to VSD_ResolveWorker.
        NESTED_ENTRY ResolveWorkerAsmStub

        PROLOG_WITH_TRANSITION_BLOCK

        add         r0, sp, #__PWTB_TransitionBlock ; pTransitionBlock
        mov         r2, r12                         ; token

        ; indirection cell in r4 - should be consistent with REG_ARM_STUB_SPECIAL
        bic         r1, r4, #3          ; indirection cell
        and         r3, r4, #3          ; flags

        bl          VSD_ResolveWorker

        mov         r12, r0

        EPILOG_WITH_TRANSITION_BLOCK_TAILCALL
        EPILOG_BRANCH_REG   r12

        NESTED_END

; ------------------------------------------------------------------
; void ResolveWorkerChainLookupAsmStub(r0, r1, r2, r3, r4:IndirectionCellAndFlags, r12:DispatchToken)
        NESTED_ENTRY ResolveWorkerChainLookupAsmStub

        ; ARMSTUB TODO: implement chained lookup
        b           ResolveWorkerAsmStub

        NESTED_END

#ifdef PROFILING_SUPPORTED

        ; ------------------------------------------------------------------
        ; void JIT_ProfilerEnterLeaveTailcallStub(UINT_PTR ProfilerHandle)
        LEAF_ENTRY  JIT_ProfilerEnterLeaveTailcallStub
        bx lr
        LEAF_END

; typedef struct _PROFILE_PLATFORM_SPECIFIC_DATA
; {
;     UINT32      r0;         // Keep r0 & r1 contiguous to make returning 64-bit results easier
;     UINT32      r1;
;     void       *R11;
;     void       *Pc;
;     union                   // Float arg registers as 32-bit (s0-s15) and 64-bit (d0-d7)
;     {
;         UINT32  s[16];
;         UINT64  d[8];
;     };
;     FunctionID  functionId;
;     void       *probeSp;    // stack pointer of managed function
;     void       *profiledSp; // location of arguments on stack
;     LPVOID      hiddenArg;
;     UINT32      flags;
; } PROFILE_PLATFORM_SPECIFIC_DATA, *PPROFILE_PLATFORM_SPECIFIC_DATA;

; ------------------------------------------------------------------
; Macro used to generate profiler helpers. In all cases we push a partially initialized
; PROFILE_PLATFORM_SPECIFIC_DATA structure on the stack and call into a C++ helper to continue processing.
;
; On entry:
;   r0    : clientInfo
;   r1/r2 : return values (in case of leave)
;   frame pointer (r11) must be set (in case of enter)
;   all arguments are on the stack at frame pointer (r11) + 8 bytes (saved lr & prev r11).
;
; On exit:
;   All register values are preserved including volatile registers
;
        MACRO
            GenerateProfileHelper $HelperName, $Flags

        GBLS __ProfilerHelperFunc
__ProfilerHelperFunc SETS "$HelperName":CC:"Naked"

        NESTED_ENTRY $__ProfilerHelperFunc

        IMPORT $HelperName                  ; The C++ helper which does most of the work

        PROLOG_PUSH         {r0,r3,r9,r12}  ; save volatile general purpose registers. remaining r1 & r2 are saved
                                            ; below...saving r9 as it is required for virtual unwinding
        PROLOG_STACK_ALLOC  (6*4)           ; Reserve space for the tail end of the structure (5*4 bytes) and an
                                            ; extra 4 bytes to align the stack at an 8-byte boundary
        PROLOG_VPUSH        {d0-d7}         ; Spill floating point argument registers
        PROLOG_PUSH         {r1,r11,lr}     ; Save possible return value in r1, frame pointer and return address
        PROLOG_PUSH         {r2}            ; Save possible return value in r0. Before calling the Leave hook the
                                            ; JIT moves the contents of r0 to r2, so we push r2 instead of r0. This
                                            ; push cannot be combined with the one above as r2 must be pushed last.

        CHECK_STACK_ALIGNMENT

        ; set the other args, starting with functionID
        str         r0, [sp, #PROFILE_PLATFORM_SPECIFIC_DATA__functionId]

        ; probeSp is the original sp when this stub was called. The PROFILE_PLATFORM_SPECIFIC_DATA occupies the
        ; bottom SIZEOF__PROFILE_PLATFORM_SPECIFIC_DATA bytes of the frame, above which sit the four volatile
        ; registers spilled by the first PROLOG_PUSH.
        add         r2, sp, #(SIZEOF__PROFILE_PLATFORM_SPECIFIC_DATA + 16)
        str         r2, [sp, #PROFILE_PLATFORM_SPECIFIC_DATA__probeSp]

        ; get the address of the arguments from the frame pointer, store in profiledSp
        add         r2, r11, #8
        str         r2, [sp, #PROFILE_PLATFORM_SPECIFIC_DATA__profiledSp]

        ; clear hiddenArg
        movw        r2, #0
        str         r2, [sp, #PROFILE_PLATFORM_SPECIFIC_DATA__hiddenArg]

        ; set the flag to indicate what hook this is
        movw        r2, #($Flags)
        str         r2, [sp, #PROFILE_PLATFORM_SPECIFIC_DATA__flags]

        ; sp is the address of PROFILE_PLATFORM_SPECIFIC_DATA, then call to C++
        mov         r1, sp
        bl          $HelperName

        EPILOG_POP          {r2}
        EPILOG_POP          {r1,r11,lr}
        EPILOG_VPOP         {d0-d7}
        EPILOG_STACK_FREE   (6*4)
        EPILOG_POP          {r0,r3,r9,r12}

        EPILOG_RETURN

        NESTED_END

        MEND

        GenerateProfileHelper ProfileEnter, PROFILE_ENTER
        GenerateProfileHelper ProfileLeave, PROFILE_LEAVE
        GenerateProfileHelper ProfileTailcall, PROFILE_TAILCALL

#endif ; PROFILING_SUPPORTED

; ------------------------------------------------------------------
; Macro to generate Redirection Stubs
;
; $reason : reason for redirection
;                     Eg. GCThreadControl
; NOTE: If you edit this macro, make sure you update GetCONTEXTFromRedirectedStubStackFrame.
; This function is used by both the personality routine and the debugger to retrieve the original CONTEXT.
        MACRO
        GenerateRedirectedHandledJITCaseStub $reason

        GBLS __RedirectionStubFuncName
        GBLS __RedirectionStubEndFuncName
        GBLS __RedirectionFuncName
__RedirectionStubFuncName SETS "RedirectedHandledJITCaseFor":CC:"$reason":CC:"_Stub"
__RedirectionStubEndFuncName SETS "RedirectedHandledJITCaseFor":CC:"$reason":CC:"_StubEnd"
__RedirectionFuncName SETS "|?RedirectedHandledJITCaseFor":CC:"$reason":CC:"@Thread@@CAXXZ|"

        IMPORT $__RedirectionFuncName

        NESTED_ENTRY $__RedirectionStubFuncName

        PROLOG_PUSH {r7,lr}     ; return address
        PROLOG_STACK_ALLOC 4    ; stack slot to save the CONTEXT *
        PROLOG_STACK_SAVE r7

        ;REDIRECTSTUB_SP_OFFSET_CONTEXT is defined in asmconstants.h
        ;If CONTEXT is not saved at 0 offset from SP it must be changed as well.
        ASSERT REDIRECTSTUB_SP_OFFSET_CONTEXT == 0

        ; Runtime check for 8-byte alignment. This check is necessary as this function can be
        ; entered before complete execution of the prolog of another function.
        and r0, r7, #4
        sub sp, sp, r0

        ; stack must be 8 byte aligned
        CHECK_STACK_ALIGNMENT

        ;
        ; Save a copy of the redirect CONTEXT*.
        ; This is needed for the debugger to unwind the stack.
        ;
        bl GetCurrentSavedRedirectContext
        str r0, [r7]

        ;
        ; Fetch the interrupted pc and save it as our return address.
        ;
        ldr r1, [r0, #CONTEXT_Pc]
        str r1, [r7, #8]

        ;
        ; Call target, which will do whatever we needed to do in the context
        ; of the target thread, and will RtlRestoreContext when it is done.
        ;
        bl $__RedirectionFuncName

        EMIT_BREAKPOINT ; Unreachable

; Put a label here to tell the debugger where the end of this function is.
        GLOBAL_LABEL $__RedirectionStubEndFuncName

        NESTED_END

        MEND

; ------------------------------------------------------------------
; Redirection Stub for GC in fully interruptible method
        GenerateRedirectedHandledJITCaseStub GCThreadControl
; ------------------------------------------------------------------
        GenerateRedirectedHandledJITCaseStub DbgThreadControl
; ------------------------------------------------------------------
        GenerateRedirectedHandledJITCaseStub UserSuspend

#ifdef _DEBUG
; ------------------------------------------------------------------
; Redirection Stub for GC Stress
        GenerateRedirectedHandledJITCaseStub GCStress
#endif

; ------------------------------------------------------------------
; Functions to probe for stack space
; Input reg r4 = amount of stack to probe for
; value of reg r4 is preserved on exit from function
; r12 is trashed
; The below two functions were copied from vctools\crt\crtw32\startup\arm\chkstk.asm

    NESTED_ENTRY checkStack
    subs        r12,sp,r4
    mrc         p15,#0,r4,c13,c0,#2 ; get TEB *
    ldr         r4,[r4,#8]          ; get Stack limit
    bcc         checkStack_neg      ; if r12 is less then 0 set it to 0
checkStack_label1
    cmp         r12, r4
    bcc         stackProbe          ; must probe to extend guardpage if r12 is beyond stackLimit
    sub         r4, sp, r12         ; restore value of r4
    EPILOG_RETURN
checkStack_neg
    mov         r12, #0
    b           checkStack_label1
    NESTED_END

    NESTED_ENTRY stackProbe
    PROLOG_PUSH {r5,r6}
    mov         r6, r12
    bfc         r6, #0, #0xc  ; align down (4K)
stackProbe_loop
    sub         r4,r4,#0x1000 ; dec stack Limit by 4K as page size is 4K
    ldr         r5,[r4]       ; try to read ... this should move the guard page
    cmp         r4,r6
    bne         stackProbe_loop
    EPILOG_POP {r5,r6}
    EPILOG_NOP  sub r4,sp,r12
    EPILOG_RETURN
    NESTED_END

;------------------------------------------------
; JIT_RareDisableHelper
;
; The JIT expects this helper to preserve registers used for return values
;
    NESTED_ENTRY JIT_RareDisableHelper

    PROLOG_PUSH {r0-r1, r11, lr} ; save integer return value
    PROLOG_VPUSH {d0-d3}         ; floating point return value

    CHECK_STACK_ALIGNMENT

    bl          JIT_RareDisableHelperWorker

    EPILOG_VPOP {d0-d3}
    EPILOG_POP {r0-r1, r11, pc}

    NESTED_END

;
; GC write barrier support.
;
; There's some complexity here for a couple of reasons:
;
; Firstly, there are a few variations of barrier types (input registers, checked vs unchecked, UP vs MP etc.).
; So first we define a number of helper macros that perform fundamental pieces of a barrier and then we define
; the final barrier functions by assembling these macros in various combinations.
;
; Secondly, for performance reasons we believe it's advantageous to be able to modify the barrier functions
; over the lifetime of the CLR. Specifically ARM has real problems reading the values of external globals (we
; need two memory indirections to do this) so we'd like to be able to directly set the current values of
; various GC globals (e.g. g_lowest_address and g_card_table) into the barrier code itself and then reset them
; every time they change (the GC already calls the VM to inform it of these changes). To handle this without
; creating too much fragility such as hardcoding instruction offsets in the VM update code, we wrap write
; barrier creation and GC globals access in a set of macros that create a table of descriptors describing each
; offset that must be patched.
;

; Many of the following macros need a scratch register. Define a name for it here so it's easy to modify this
; in the future.
        GBLS __wbscratch
__wbscratch SETS "r3"

    ; WRITE_BARRIER_ENTRY
    ;
    ; Declare the start of a write barrier function. Use similarly to LEAF_ENTRY. This is the only legal way
    ; to declare a write barrier function.
    ;
    MACRO
      WRITE_BARRIER_ENTRY $name

        LEAF_ENTRY $name

        ; Record the function name as it's used as the basis for unique label and variable name creation in
        ; some of the macros below.
        GBLS __write_barrier_name
__write_barrier_name SETS "$name"

        ; Declare the per-barrier variables which collect the offsets of the instructions that load GC global
        ; values. Initialize them to 0xffff. The default of zero is unsatisfactory because we could legally
        ; have an offset of zero and we need some way to distinguish unset values (both for debugging and
        ; because some write barriers don't use all the globals).
        GBLA __$name._g_lowest_address_offset
        GBLA __$name._g_highest_address_offset
        GBLA __$name._g_ephemeral_low_offset
        GBLA __$name._g_ephemeral_high_offset
        GBLA __$name._g_card_table_offset
        GBLA __$name._g_write_watch_table_offset
__$name._g_lowest_address_offset SETA 0xffff
__$name._g_highest_address_offset SETA 0xffff
__$name._g_ephemeral_low_offset SETA 0xffff
__$name._g_ephemeral_high_offset SETA 0xffff
__$name._g_card_table_offset SETA 0xffff
__$name._g_write_watch_table_offset SETA 0xffff

    MEND

    ; WRITE_BARRIER_END
    ;
    ; The partner to WRITE_BARRIER_ENTRY, used like LEAF_END.
    ;
    MACRO
      WRITE_BARRIER_END

        LEAF_END_MARKED $__write_barrier_name

    MEND

    ; LOAD_GC_GLOBAL
    ;
    ; Used any time we want to load the value of one of the supported GC globals into a register. This records
    ; the offset of the instructions used to do this (a movw/movt pair) so we can modify the actual value
    ; loaded at runtime.
    ;
    ; Note that a given write barrier can only load a given global at most once (which is compile-time
    ; asserted below).
    ;
    MACRO
      LOAD_GC_GLOBAL $regName, $globalName

        ; Map the GC global name to the name of the variable tracking the offset for this function.
        LCLS __offset_name
__offset_name SETS "__$__write_barrier_name._$globalName._offset"

        ; Ensure that we only attempt to load this global at most once in the current barrier function (we
        ; have this limitation purely because we only record one offset for each GC global).
        ASSERT $__offset_name == 0xffff

        ; Define a unique name for a label we're about to define used in the calculation of the current
        ; function offset.
        LCLS __offset_label_name
__offset_label_name SETS "$__write_barrier_name._$globalName._lbl"

        ; Define the label.
$__offset_label_name

        ; Write the current function offset into the tracking variable.
$__offset_name SETA ($__offset_label_name - $__FuncStartLabel)

        ; Emit the instructions which will be patched to provide the value of the GC global (we start with a
        ; value of zero, so the write barriers have to be patched at least once before first use).
        movw    $regName, #0
        movt    $regName, #0
    MEND

    ; WRITE_BARRIER_DESCRIPTOR
    ;
    ; Emit the descriptor for a write barrier. The order and meaning of these datums must be kept in sync with
    ; the definition of the WriteBarrierDescriptor structure in vm\arm\stubs.cpp. Note that the function start
    ; and end are recorded as offsets relative to the address of the descriptor itself.
    ;
    MACRO
      WRITE_BARRIER_DESCRIPTOR $name

        LCLS __desc_label_name
__desc_label_name SETS "$name._Desc"

$__desc_label_name
        DCD     $name - $__desc_label_name
        DCD     $name._End - $__desc_label_name
        DCD     __$name._g_lowest_address_offset
        DCD     __$name._g_highest_address_offset
        DCD     __$name._g_ephemeral_low_offset
        DCD     __$name._g_ephemeral_high_offset
        DCD     __$name._g_card_table_offset
#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
        DCD     __$name._g_write_watch_table_offset
#endif
    MEND

;
; Now define the macros used in the bodies of write barrier implementations.
;

    ; UPDATE_GC_SHADOW
    ;
    ; Update the GC shadow heap to aid debugging. Not implemented on ARM.
    ;
    MACRO
      UPDATE_GC_SHADOW $ptrReg, $valReg
        ; Todo: implement, debugging helper
    MEND

    ; UPDATE_CARD_TABLE
    ;
    ; Update the card table as necessary (if the object reference being assigned in the barrier refers to an
    ; object in the ephemeral generation). Otherwise this macro is a no-op. Assumes the location being written
    ; lies on the GC heap (either we've already performed the dynamic check or this is statically asserted by
    ; the JIT by calling the unchecked version of the write barrier).
    ;
    ; Additionally this macro can produce a uni-proc or multi-proc variant of the code. This governs whether
    ; we bother to check if the card table has been updated before making our own update (on an MP system it
    ; can be helpful to perform this check to avoid cache line thrashing, on an SP system the code path length
    ; is more important).
    ;
    ;   Input:
    ;       $ptrReg   : register containing the location to be updated
    ;       $valReg   : register containing the value (an objref) to be written to the location above
    ;       $mp       : boolean indicating whether the code will run on an MP system
    ;       $postGrow : boolean: {true} for post-grow version, {false} otherwise
    ;       $tmpReg   : additional register that can be trashed (can alias $ptrReg or $valReg if needed)
    ;
    ;   Output:
    ;       $tmpReg : trashed (defaults to $ptrReg)
    ;       $__wbscratch : trashed
    ;
    MACRO
      UPDATE_CARD_TABLE $ptrReg, $valReg, $mp, $postGrow, $tmpReg
        ASSERT "$ptrReg" != "$__wbscratch"
        ASSERT "$valReg" != "$__wbscratch"
        ASSERT "$tmpReg" != "$__wbscratch"

        ; In most cases the callers of this macro are fine with scratching $ptrReg, the exception being the
        ; ref write barrier, which wants to scratch $valReg instead. Ideally we could set $ptrReg as the
        ; default for the $tmpReg parameter, but limitations in armasm won't allow that. Similarly it doesn't
        ; seem to like us trying to redefine $tmpReg in the body of the macro. Instead we define a new local
        ; string variable and set that either with the value of $tmpReg or $ptrReg if $tmpReg wasn't
        ; specified.
        LCLS tempReg
        IF "$tmpReg" == ""
tempReg     SETS "$ptrReg"
        ELSE
tempReg     SETS "$tmpReg"
        ENDIF

        ; Check whether the value object lies in the ephemeral generations. If not we don't have to update the
        ; card table.
        LOAD_GC_GLOBAL $__wbscratch, g_ephemeral_low
        cmp     $valReg, $__wbscratch
        blo     %FT0
        ; Only in post grow higher generation can be beyond ephemeral segment
        IF $postGrow
            LOAD_GC_GLOBAL $__wbscratch, g_ephemeral_high
            cmp     $valReg, $__wbscratch
            bhs     %FT0
        ENDIF

        ; Update the card table.
        LOAD_GC_GLOBAL $__wbscratch, g_card_table
        add     $__wbscratch, $__wbscratch, $ptrReg, lsr #10

        ; On MP systems make sure the card hasn't already been set first to avoid thrashing cache lines
        ; between CPUs.
        IF $mp
            ldrb    $tempReg, [$__wbscratch]
            cmp     $tempReg, #0xff
            ; armasm generates the IT block automatically
            movne   $tempReg, #0xff
            strbne  $tempReg, [$__wbscratch]
        ELSE
            mov     $tempReg, #0xff
            strb    $tempReg, [$__wbscratch]
        ENDIF
0
    MEND

#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
    ; UPDATE_WRITE_WATCH_TABLE
    ;
    ; Update the software write watch table for the GC heap if it is currently enabled.
    ;
    ;   Input:
    ;       $ptrReg : register containing the location to be updated
    ;       $mp     : boolean indicating whether the code will run on an MP system
    ;       $tmpReg : additional register that can be trashed
    ;
    ;   Output:
    ;       $tmpReg : trashed
    ;       $__wbscratch : trashed
    ;
    MACRO
      UPDATE_WRITE_WATCH_TABLE $ptrReg, $mp, $tmpReg
        ASSERT "$ptrReg" != "$__wbscratch"
        ASSERT "$tmpReg" != "$__wbscratch"

        LOAD_GC_GLOBAL $__wbscratch, g_write_watch_table
        cbz     $__wbscratch, %FT2
        add     $__wbscratch, $__wbscratch, $ptrReg, lsr #0xc  ; SoftwareWriteWatch::AddressToTableByteIndexShift

        IF $mp
            ldrb    $tmpReg, [$__wbscratch]
            cmp     $tmpReg, #0xff
            ; armasm generates the IT block automatically
            movne   $tmpReg, #0xff
            strbne  $tmpReg, [$__wbscratch]
        ELSE
            mov     $tmpReg, #0xff
            strb    $tmpReg, [$__wbscratch]
        ENDIF
2
    MEND
#endif ; FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP

    ; CHECK_GC_HEAP_RANGE
    ;
    ; Verifies that the given value points into the GC heap range. If so the macro will fall through to the
    ; following code. Otherwise (if the value points outside the GC heap) a branch to the supplied label will
    ; be made.
    ;
    ;   Input:
    ;       $ptrReg : register containing the location to be updated
    ;       $label  : label branched to on a range check failure
    ;
    ;   Output:
    ;       $__wbscratch : trashed
    ;
    MACRO
      CHECK_GC_HEAP_RANGE $ptrReg, $label
        ASSERT "$ptrReg" != "$__wbscratch"

        LOAD_GC_GLOBAL $__wbscratch, g_lowest_address
        cmp     $ptrReg, $__wbscratch
        blo     $label
        LOAD_GC_GLOBAL $__wbscratch, g_highest_address
        cmp     $ptrReg, $__wbscratch
        bhs     $label
    MEND

;
; Finally define the write barrier functions themselves. Currently we don't provide variations that use
; different input registers. If the JIT wants this at a later stage in order to improve code quality it would
; be a relatively simple change to implement via an additional macro parameter to WRITE_BARRIER_ENTRY.
;
; The calling convention for the first batch of write barriers is:
;
; On entry:
;   r0  : the destination address (LHS of the assignment)
;   r1  : the object reference (RHS of the assignment)
;
; On exit:
;   r0  : trashed
;   $__wbscratch : trashed
;

    ; If you update any of the write barriers be sure to update the sizes of the patchable
    ; write barriers in vm\arm\patchedcode.asm
    ; see ValidateWriteBarriers()

    ; The write barriers are macros taking arguments like
    ; $name: Name of the write barrier
    ; $mp: {true} for multi-proc, {false} otherwise
    ; $post: {true} for post-grow version, {false} otherwise

    MACRO
        JIT_WRITEBARRIER $name, $mp, $post
    WRITE_BARRIER_ENTRY $name
        IF $mp
            dmb                                 ; Perform a memory barrier
        ENDIF
        str     r1, [r0]                        ; Write the reference
        UPDATE_GC_SHADOW  r0, r1                ; Update the shadow GC heap for debugging
#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
        UPDATE_WRITE_WATCH_TABLE r0, $mp, r12   ; Update the write watch table if necessary
#endif
        UPDATE_CARD_TABLE r0, r1, $mp, $post    ; Update the card table if necessary
        bx      lr
    WRITE_BARRIER_END
    MEND

    MACRO
        JIT_CHECKEDWRITEBARRIER_SP $name, $post
    WRITE_BARRIER_ENTRY $name
        str     r1, [r0]                        ; Write the reference
        CHECK_GC_HEAP_RANGE r0, %F1             ; Check whether the destination is in the GC heap
        UPDATE_GC_SHADOW  r0, r1                ; Update the shadow GC heap for debugging
#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
        UPDATE_WRITE_WATCH_TABLE r0, {false}, r12 ; Update the write watch table if necessary
#endif
        UPDATE_CARD_TABLE r0, r1, {false}, $post; Update the card table if necessary
1
        bx      lr
    WRITE_BARRIER_END
    MEND

    MACRO
        JIT_CHECKEDWRITEBARRIER_MP $name, $post
    WRITE_BARRIER_ENTRY $name
        dmb                                     ; Perform a memory barrier
        str     r1, [r0]                        ; Write the reference
        CHECK_GC_HEAP_RANGE r0, %F1             ; Check whether the destination is in the GC heap
        UPDATE_GC_SHADOW  r0, r1                ; Update the shadow GC heap for debugging
#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
        UPDATE_WRITE_WATCH_TABLE r0, {true}, r12 ; Update the write watch table if necessary
#endif
        UPDATE_CARD_TABLE r0, r1, {true}, $post ; Update the card table if necessary
        bx      lr
1
        str     r1, [r0]                        ; Write the reference
        bx      lr
    WRITE_BARRIER_END
    MEND

; The ByRef write barriers have a slightly different interface:
;
; On entry:
;   r0  : the destination address (object reference written here)
;   r1  : the source address (points to object reference to write)
;
; On exit:
;   r0  : incremented by 4
;   r1  : incremented by 4
;   r2  : trashed
;   $__wbscratch : trashed
;
    MACRO
        JIT_BYREFWRITEBARRIER $name, $mp, $post
    WRITE_BARRIER_ENTRY $name
        IF $mp
            dmb                                 ; Perform a memory barrier
        ENDIF
        ldr     r2, [r1]                        ; Load target object ref from source pointer
        str     r2, [r0]                        ; Write the reference to the destination pointer
        CHECK_GC_HEAP_RANGE r0, %F1             ; Check whether the destination is in the GC heap
        UPDATE_GC_SHADOW  r0, r2                ; Update the shadow GC heap for debugging
#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
        UPDATE_WRITE_WATCH_TABLE r0, $mp, r12   ; Update the write watch table if necessary
#endif
        UPDATE_CARD_TABLE r0, r2, $mp, $post, r2 ; Update the card table if necessary (trash r2 rather than r0)
1
        add     r0, #4                          ; Increment the destination pointer by 4
        add     r1, #4                          ; Increment the source pointer by 4
        bx      lr
    WRITE_BARRIER_END
    MEND

    ; There are 4 versions of each write barrier. A 2x2 combination of multi-proc/single-proc and pre/post grow version
    JIT_WRITEBARRIER JIT_WriteBarrier_SP_Pre,  {false}, {false}
    JIT_WRITEBARRIER JIT_WriteBarrier_SP_Post, {false}, {true}
    JIT_WRITEBARRIER JIT_WriteBarrier_MP_Pre,  {true}, {false}
    JIT_WRITEBARRIER JIT_WriteBarrier_MP_Post, {true}, {true}

    JIT_CHECKEDWRITEBARRIER_SP JIT_CheckedWriteBarrier_SP_Pre,  {false}
    JIT_CHECKEDWRITEBARRIER_SP JIT_CheckedWriteBarrier_SP_Post, {true}
    JIT_CHECKEDWRITEBARRIER_MP JIT_CheckedWriteBarrier_MP_Pre,  {false}
    JIT_CHECKEDWRITEBARRIER_MP JIT_CheckedWriteBarrier_MP_Post, {true}

    JIT_BYREFWRITEBARRIER JIT_ByRefWriteBarrier_SP_Pre,  {false}, {false}
    JIT_BYREFWRITEBARRIER JIT_ByRefWriteBarrier_SP_Post, {false}, {true}
    JIT_BYREFWRITEBARRIER JIT_ByRefWriteBarrier_MP_Pre,  {true},  {false}
    JIT_BYREFWRITEBARRIER JIT_ByRefWriteBarrier_MP_Post, {true},  {true}

; The table of write barrier descriptors. This must live in the same section as the barriers themselves so
; that the assembler can compute the barrier addresses relative to each descriptor. The table is terminated by
; a sentinel entry with a zero function start offset.
        ALIGN 4
        GLOBAL_LABEL g_rgWriteBarrierDescriptors

        WRITE_BARRIER_DESCRIPTOR JIT_WriteBarrier_SP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_WriteBarrier_SP_Post
        WRITE_BARRIER_DESCRIPTOR JIT_WriteBarrier_MP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_WriteBarrier_MP_Post

        WRITE_BARRIER_DESCRIPTOR JIT_CheckedWriteBarrier_SP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_CheckedWriteBarrier_SP_Post
        WRITE_BARRIER_DESCRIPTOR JIT_CheckedWriteBarrier_MP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_CheckedWriteBarrier_MP_Post

        WRITE_BARRIER_DESCRIPTOR JIT_ByRefWriteBarrier_SP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_ByRefWriteBarrier_SP_Post
        WRITE_BARRIER_DESCRIPTOR JIT_ByRefWriteBarrier_MP_Pre
        WRITE_BARRIER_DESCRIPTOR JIT_ByRefWriteBarrier_MP_Post

        ; Sentinel value
        DCD 0

; ------------------------------------------------------------------
; __declspec(naked) void F_CALL_CONV JIT_WriteBarrier_Callable(Object **dst, Object* val)
    LEAF_ENTRY  JIT_WriteBarrier_Callable

    ; Branch to the write barrier
    ldr     r2, =JIT_WriteBarrier_Loc ; or R3? See targetarm.h
    ldr     pc, [r2]

    LEAF_END

    LTORG

#ifdef FEATURE_READYTORUN

    NESTED_ENTRY DelayLoad_MethodCall_FakeProlog

    ; Match what the lazy thunk has pushed. The actual method arguments will be spilled later.
    PROLOG_PUSH         {r1-r3}

        ; This is where execution really starts.
    GLOBAL_LABEL DelayLoad_MethodCall

    PROLOG_PUSH         {r0}

    PROLOG_WITH_TRANSITION_BLOCK 0x0, {true}, DoNotPushArgRegs

    ; Load the helper arguments
    ldr         r5, [sp,#(__PWTB_TransitionBlock+10*4)] ; pModule
    ldr         r6, [sp,#(__PWTB_TransitionBlock+11*4)] ; sectionIndex
    ldr         r8, [sp,#(__PWTB_TransitionBlock+12*4)] ; indirection

    ; Spill the actual method arguments
    str         r1, [sp,#(__PWTB_TransitionBlock+10*4)]
    str         r2, [sp,#(__PWTB_TransitionBlock+11*4)]
    str         r3, [sp,#(__PWTB_TransitionBlock+12*4)]

    add         r0, sp, #__PWTB_TransitionBlock ; pTransitionBlock

    mov         r1, r8          ; pIndirection
    mov         r2, r6          ; sectionIndex
    mov         r3, r5          ; pModule

    bl          ExternalMethodFixupWorker

    ; mov the address we patched to in R12 so that we can tail call to it
    mov         r12, r0

    EPILOG_WITH_TRANSITION_BLOCK_TAILCALL
    EPILOG_BRANCH_REG r12

    NESTED_END

    MACRO
    DynamicHelper $frameFlags, $suffix

        GBLS __FakePrologName
__FakePrologName SETS "DelayLoad_Helper":CC:"$suffix":CC:"_FakeProlog"

        NESTED_ENTRY $__FakePrologName

        ; Match what the lazy thunk has pushed. The actual method arguments will be spilled later.
        PROLOG_PUSH         {r1-r3}

        ; This is where execution really starts.
        GBLS __RealName
__RealName SETS "DelayLoad_Helper":CC:"$suffix"

        GLOBAL_LABEL $__RealName

        PROLOG_PUSH         {r0}

        PROLOG_WITH_TRANSITION_BLOCK 0x4, {false}, DoNotPushArgRegs

        ; Load the helper arguments
        ldr         r5, [sp,#(__PWTB_TransitionBlock+10*4)] ; pModule
        ldr         r6, [sp,#(__PWTB_TransitionBlock+11*4)] ; sectionIndex
        ldr         r8, [sp,#(__PWTB_TransitionBlock+12*4)] ; indirection

        ; Spill the actual method arguments
        str         r1, [sp,#(__PWTB_TransitionBlock+10*4)]
        str         r2, [sp,#(__PWTB_TransitionBlock+11*4)]
        str         r3, [sp,#(__PWTB_TransitionBlock+12*4)]

        add         r0, sp, #__PWTB_TransitionBlock ; pTransitionBlock

        mov         r1, r8          ; pIndirection
        mov         r2, r6          ; sectionIndex
        mov         r3, r5          ; pModule

        mov         r4, #($frameFlags)
        str         r4, [sp,#0]

        bl          DynamicHelperWorker

        cbnz        r0, %FT0
        ldr         r0, [sp,#(__PWTB_TransitionBlock+9*4)]  ; The result is stored in the argument area of the transition block

        EPILOG_WITH_TRANSITION_BLOCK_RETURN

0
        mov         r12, r0
        EPILOG_WITH_TRANSITION_BLOCK_TAILCALL
        EPILOG_BRANCH_REG   r12

        NESTED_END

    MEND

    DynamicHelper DynamicHelperFrameFlags_Default
    DynamicHelper DynamicHelperFrameFlags_ObjectArg, _Obj
    DynamicHelper DynamicHelperFrameFlags_ObjectArg | DynamicHelperFrameFlags_ObjectArg2, _ObjObj

#endif ; FEATURE_READYTORUN

#ifdef FEATURE_HIJACK

; ------------------------------------------------------------------
; Hijack function for functions which return a value type
        NESTED_ENTRY OnHijackTripThread
        ; saving r1 as well, as it can have partial return value when return is > 32 bits
        PROLOG_PUSH {r0,r1,r2,r4-r11,lr}

        PROLOG_VPUSH {d0-d3}    ; saving as d0-d3 can have the floating point return value

        CHECK_STACK_ALIGNMENT

        add r0, sp, #32
        bl OnHijackWorker

        EPILOG_VPOP {d0-d3}

        EPILOG_POP {r0,r1,r2,r4-r11,pc}
        NESTED_END

#endif ; FEATURE_HIJACK

; ------------------------------------------------------------------
; The following helper will access ("probe") a word on each page of the stack
; starting with the page right beneath sp down to the one pointed to by r4.
; The procedure is needed to make sure that the "guard" page is pushed down below the allocated stack frame.
; The call to the helper will be emitted by JIT in the function/funclet prolog when stack frame is larger than an OS page.
; On entry:
;   r4 - points to the lowest address on the stack frame being allocated (i.e. [InitialSp - FrameSize])
;   sp - points to some byte on the last probed page
; On exit:
;   r4 - is preserved
;   r5 - is not preserved
;
; NOTE: this helper will probe at least one page below the one pointed to by sp.
#define PROBE_PAGE_SIZE      4096
#define PROBE_PAGE_SIZE_LOG2 12

        LEAF_ENTRY JIT_StackProbe
        PROLOG_PUSH {r11}
        PROLOG_STACK_SAVE r11

        mov r5, sp                         ; r5 points to some byte on the last probed page
        bfc r5, #0, #PROBE_PAGE_SIZE_LOG2  ; r5 points to the **lowest address** on the last probed page
        mov sp, r5

ProbeLoop
                                           ; Immediate operand for the following instruction can not be greater than 4095.
        sub sp, #(PROBE_PAGE_SIZE - 4)     ; sp points to the **fourth** byte on the **next page** to probe
        ldr r5, [sp, #-4]!                 ; sp points to the lowest address on the **last probed** page
        cmp sp, r4
        bhi ProbeLoop                      ; If (sp > r4), then we need to probe at least one more page.

        EPILOG_STACK_RESTORE r11
        EPILOG_POP {r11}
        EPILOG_BRANCH_REG lr
        LEAF_END_MARKED JIT_StackProbe

#ifdef FEATURE_TIERED_COMPILATION

    NESTED_ENTRY OnCallCountThresholdReachedStub
        PROLOG_WITH_TRANSITION_BLOCK

        add     r0, sp, #__PWTB_TransitionBlock ; TransitionBlock *
        mov     r1, r12 ; stub-identifying token
        bl      OnCallCountThresholdReached
        mov     r12, r0

        EPILOG_WITH_TRANSITION_BLOCK_TAILCALL
        EPILOG_BRANCH_REG r12
    NESTED_END

#endif ; FEATURE_TIERED_COMPILATION

    LEAF_ENTRY JIT_PollGC
        ldr     r2, =g_TrapReturningThreads
        ldr     r2, [r2]
        cbnz    r2, JIT_PollGCRarePath
        bx      lr
JIT_PollGCRarePath
        ldr     r2, =g_pPollGC
        ldr     r2, [r2]
        EPILOG_BRANCH_REG r2
    LEAF_END

    LTORG

; ------------------------------------------------------------------
; r0 - This pointer
; r1 - ReturnBuffer
    LEAF_ENTRY ThisPtrRetBufPrecodeWorker
        ldr  r12, [r12, #ThisPtrRetBufPrecodeData__Target]
        ; Use XOR swap technique to avoid the need to spill to the stack
        eor  r0, r0, r1
        eor  r1, r0, r1
        eor  r0, r0, r1
        EPILOG_BRANCH_REG r12
    LEAF_END

; Must be at very end of file
        END
