;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include "AsmMacros.h"

        TEXTAREA

;; ------------------------------------------------------------------
;; The following helper will access ("probe") a word on each page of the stack
;; starting with the page right beneath sp down to the one pointed to by r4.
;; The procedure is needed to make sure that the "guard" page is pushed down below the allocated stack frame.
;; The call to the helper will be emitted by JIT in the function/funclet prolog when stack frame is larger than an OS page.
;; On entry:
;;   r4 - points to the lowest address on the stack frame being allocated (i.e. [InitialSp - FrameSize])
;;   sp - points to some byte on the last probed page
;; On exit:
;;   r4 - is preserved
;;   r5 - is not preserved
;;
;; NOTE: this helper will probe at least one page below the one pointed to by sp.
PROBE_STEP      equ 4096
PROBE_STEP_LOG2 equ 12

        LEAF_ENTRY RhpStackProbe
        PROLOG_PUSH {r11}
        PROLOG_STACK_SAVE r11

        mov     r5, sp                          ;; r5 points to some byte on the last probed page
        bfc     r5, #0, #PROBE_STEP_LOG2        ;; r5 points to the **lowest address** on the last probed page
        mov     sp, r5

RhpStackProbeLoop
                                                ;; Immediate operand for the following instruction can not be greater than 4095.
        sub     sp, sp, #(PROBE_STEP - 4)       ;; sp points to the **fourth** byte on the **next page** to probe
        ldr     r5, [sp, #-4]!                  ;; sp points to the lowest address on the **last probed** page
        cmp     sp, r4
        bhi     RhpStackProbeLoop               ;; If (sp > r4), then we need to probe at least one more page.

        EPILOG_STACK_RESTORE r11
        EPILOG_POP {r11}
        EPILOG_BRANCH_REG lr
        LEAF_END RhpStackProbe

        END
