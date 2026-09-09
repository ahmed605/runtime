;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include "AsmMacros.h"

        TEXTAREA

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; RhpPInvoke
;;
;; IN:  R0: address of pinvoke frame
;;
;; TRASHES: R1, R2, R3
;;
;; This helper assumes that its callsite is as good to start the stackwalk as the actual PInvoke callsite.
;; The codegenerator must treat the callsite of this helper as GC triggering and generate the GC info for it.
;; Also, the codegenerator must ensure that there are no live GC references in callee saved registers.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        LEAF_ENTRY RhpPInvoke

        str     lr, [r0, #OFFSETOF__PInvokeTransitionFrame__m_RIP]
        str     r11, [r0, #OFFSETOF__PInvokeTransitionFrame__m_FramePointer]
        ;; We need to save R9 which could be frame pointer if the caller method uses stackalloc (REG_SAVED_LOCALLOC_SP)
        str     r9, [r0, #OFFSETOF__PInvokeTransitionFrame__m_PreservedRegs]
        str     sp, [r0, #(OFFSETOF__PInvokeTransitionFrame__m_PreservedRegs + 4)]
        mov     r3, #(PTFF_SAVE_R9 + PTFF_SAVE_SP)
        str     r3, [r0, #OFFSETOF__PInvokeTransitionFrame__m_Flags]

        ;; r1 = GetThread()
        INLINE_GETTHREAD r1, r2

        str     r1, [r0, #OFFSETOF__PInvokeTransitionFrame__m_pThread]
        str     r0, [r1, #OFFSETOF__Thread__m_pTransitionFrame]

        bx      lr

        LEAF_END RhpPInvoke

        INLINE_GETTHREAD_CONSTANT_POOL

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; RhpPInvokeReturn
;;
;; IN:  R0: address of pinvoke frame
;;
;; TRASHES: R2, R3
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
        LEAF_ENTRY RhpPInvokeReturn

        ldr     r3, [r0, #OFFSETOF__PInvokeTransitionFrame__m_pThread]

        mov     r2, #0
        str     r2, [r3, #OFFSETOF__Thread__m_pTransitionFrame]

        PREPARE_EXTERNAL_VAR_INDIRECT RhpTrapThreads, r3
        cbnz    r3, %ft0                ;; TrapThreadsFlags_None = 0

        bx      lr
0
        ;; passing transition frame pointer in r0
        b       RhpWaitForGC2

        LEAF_END RhpPInvokeReturn

        END
