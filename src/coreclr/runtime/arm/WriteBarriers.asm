;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include "AsmMacros_Shared.h"

        TEXTAREA

;; Macro used to copy contents of newly updated GC heap locations to a shadow copy of the heap. This is
;; currently not implemented on ARM, the macro is defined so the barrier bodies below stay in sync with
;; the other architectures.
    MACRO
        UPDATE_GC_SHADOW $BASENAME, $REFREG, $DESTREG
        ;; Todo: implement, debugging helper
    MEND

#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
    MACRO
        UPDATE_WRITE_WATCH_TABLE $BASENAME, $ptrReg, $tmpReg, $wbScratch

        PREPARE_EXTERNAL_VAR_INDIRECT g_write_watch_table, $wbScratch
        cbz          $wbScratch, $BASENAME._UpdateWriteWatch_Done
        add          $wbScratch, $wbScratch, $ptrReg, lsr #0xc  ; SoftwareWriteWatch::AddressToTableByteIndexShift

        ldrb         $tmpReg, [$wbScratch]
        cmp          $tmpReg, #0xff
        beq          $BASENAME._UpdateWriteWatch_Done
        mov          $tmpReg, #0xff
        strb         $tmpReg, [$wbScratch]

$BASENAME._UpdateWriteWatch_Done
    MEND
#else
    MACRO
        UPDATE_WRITE_WATCH_TABLE $BASENAME, $ptrReg, $tmpReg, $wbScratch
    MEND
#endif

;; The body shared by all the write barriers. The location to be updated is in r0 and the object reference
;; that was assigned into it is in $REFREG. $TMPREG is an additional scratch register.
    MACRO
        DEFINE_UNCHECKED_WRITE_BARRIER_CORE $BASENAME, $REFREG, $TMPREG

        ;; Update the shadow copy of the heap with the same value just written to the same heap. (A no-op unless
        ;; we're in a debug build and write barrier checking has been enabled).
        UPDATE_GC_SHADOW $BASENAME, $REFREG, r0

        UPDATE_WRITE_WATCH_TABLE $BASENAME, r0, r12, $TMPREG

        ;; If the reference is to an object that's not in an ephemeral generation we have no need to track it
        ;; (since the object won't be collected or moved by an ephemeral collection).
        PREPARE_EXTERNAL_VAR_INDIRECT g_ephemeral_low, r12
        cmp          $REFREG, r12
        blo          $BASENAME._EXIT

        PREPARE_EXTERNAL_VAR_INDIRECT g_ephemeral_high, r12
        cmp          $REFREG, r12
        bhs          $BASENAME._EXIT

        ;; We have a location on the GC heap being updated with a reference to an ephemeral object so we must
        ;; track this write. The location address is translated into an offset in the card table bitmap. We set
        ;; an entire byte in the card table since it's quicker than messing around with bitmasks and we only write
        ;; the byte if it hasn't already been done since writes are expensive and impact scaling.
        PREPARE_EXTERNAL_VAR_INDIRECT g_card_table, r12
        add          r0, r12, r0, lsr #10
        ldrb         r12, [r0]
        cmp          r12, #0x0FF
        bne          $BASENAME._UpdateCardTable

$BASENAME._NoBarrierRequired
        b            $BASENAME._EXIT

;; We get here if it's necessary to update the card table.
$BASENAME._UpdateCardTable
        mov          r12, #0x0FF
        strb         r12, [r0]

$BASENAME._EXIT

    MEND

;; The body shared by the write barriers that also have to check whether the location being updated even
;; lies within the GC heap.
    MACRO
        DEFINE_CHECKED_WRITE_BARRIER_CORE $BASENAME, $REFREG, $TMPREG

        ;; The location being updated might not even lie in the GC heap (a handle or stack location for instance),
        ;; in which case no write barrier is required.
        PREPARE_EXTERNAL_VAR_INDIRECT g_lowest_address, r12
        cmp          r0, r12
        blo          $BASENAME._NoBarrierRequired
        PREPARE_EXTERNAL_VAR_INDIRECT g_highest_address, r12
        cmp          r0, r12
        bhs          $BASENAME._NoBarrierRequired

        DEFINE_UNCHECKED_WRITE_BARRIER_CORE $BASENAME, $REFREG, $TMPREG

    MEND

;; Define a helper with a name of the form RhpAssignRefr1 etc. The location to be updated is in r0. The
;; object reference that will be assigned into that location is in r1.
;;
;; WARNING: Code in EHHelpers.cpp makes assumptions about write barrier code, in particular:
;; - Function "InWriteBarrierHelper" assumes an AV due to passed in null pointer will happen at WriteBarrierFunctionAvLocation
;; - Function "UnwindSimpleHelperToCaller" assumes no registers were pushed and LR contains the return address
        LEAF_ENTRY RhpAssignRefr1

        ;; Export the canonical write barrier under unqualified name as well
        ALTERNATE_ENTRY RhpAssignRef

        ;; Use the GC write barrier as a convenient place to implement the managed memory model for ARM. The
        ;; intent is that writes to the target object (r1) will be visible across all CPUs before the
        ;; write to the destination (r0). This covers most of the common scenarios where the programmer
        ;; might assume strongly ordered accessess, namely where the preceding writes are used to initialize
        ;; the object and the final write, made by this barrier in the instruction following the DMB,
        ;; publishes that object for other threads/cpus to see.
        ;;
        ;; Note that none of this is relevant for single cpu machines. We may choose to implement a
        ;; uniprocessor specific version of this barrier if uni-proc becomes a significant scenario again.
        dmb

        ;; Write the reference into the location. Note that we rely on the fact that no GC can occur between here
        ;; and the card table update we may perform below.
        GLOBAL_LABEL RhpAssignRefAvLocationr1
        GLOBAL_LABEL RhpAssignRefAVLocation
        str          r1, [r0]

        DEFINE_UNCHECKED_WRITE_BARRIER_CORE RhpAssignRef, r1, r3

        bx           lr
        LEAF_END RhpAssignRefr1

;; Define a helper with a name of the form RhpCheckedAssignRefr1 etc. The location to be updated is always
;; in r0. The object reference that will be assigned into that location is in r1.
;;
;; WARNING: Code in EHHelpers.cpp makes assumptions about write barrier code, in particular:
;; - Function "InWriteBarrierHelper" assumes an AV due to passed in null pointer will happen on the first instruction
;; - Function "UnwindSimpleHelperToCaller" assumes no registers were pushed and LR contains the return address
        LEAF_ENTRY RhpCheckedAssignRefr1

        ;; Export the canonical write barrier under unqualified name as well
        ALTERNATE_ENTRY RhpCheckedAssignRef

        ;; See the comment in RhpAssignRef.
        dmb

        ;; Write the reference into the location. Note that we rely on the fact that no GC can occur between here
        ;; and the card table update we may perform below.
        GLOBAL_LABEL RhpCheckedAssignRefAvLocationr1
        GLOBAL_LABEL RhpCheckedAssignRefAVLocation
        str          r1, [r0]

        DEFINE_CHECKED_WRITE_BARRIER_CORE RhpCheckedAssignRef, r1, r3

        bx           lr
        LEAF_END RhpCheckedAssignRefr1

#ifdef FEATURE_NATIVEAOT

;; r0 = destination address
;; r1 = value
;; r2 = comparand
        LEAF_ENTRY RhpCheckedLockCmpXchg

        ;; To implement our chosen memory model for ARM we insert a memory barrier at GC write barriers. This
        ;; barrier must occur before the object reference update, so we have to do it unconditionally even
        ;; though the update may fail below.
        dmb

RhpCheckedLockCmpXchgRetry
        ldrex        r3, [r0]
        cmp          r2, r3
        bne          RhpCheckedLockCmpXchg_NoBarrierRequired
        strex        r3, r1, [r0]
        cmp          r3, #0
        bne          RhpCheckedLockCmpXchgRetry
        mov          r3, r2

        DEFINE_CHECKED_WRITE_BARRIER_CORE RhpCheckedLockCmpXchg, r1, r2

        mov          r0, r3
        bx           lr
        LEAF_END RhpCheckedLockCmpXchg

;; r0 = destination address
;; r1 = value
        LEAF_ENTRY RhpCheckedXchg

        ;; To implement our chosen memory model for ARM we insert a memory barrier at GC write barriers. This
        ;; barrier must occur before the object reference update.
        dmb

RhpCheckedXchgRetry
        ldrex        r2, [r0]
        strex        r3, r1, [r0]
        cmp          r3, #0
        bne          RhpCheckedXchgRetry

        DEFINE_CHECKED_WRITE_BARRIER_CORE RhpCheckedXchg, r1, r3

        ;; The original value is currently in r2. We need to return it in r0.
        mov          r0, r2

        bx           lr
        LEAF_END RhpCheckedXchg

#endif ;; FEATURE_NATIVEAOT

;;
;; RhpByRefAssignRef simulates movs instruction for object references.
;;
;; On entry:
;;      r0: address of ref-field (assigned to)
;;      r1: address of the data (source)
;;      r2, r3: be trashed
;;
;; On exit:
;;      r0, r1 are incremented by 4,
;;      r2, r3: trashed
;;
;; WARNING: Code in EHHelpers.cpp makes assumptions about write barrier code, in particular:
;; - Function "InWriteBarrierHelper" assumes an AV due to passed in null pointer will happen at RhpByRefAssignRefAVLocation1/2
;; - Function "UnwindSimpleHelperToCaller" assumes no registers were pushed and LR contains the return address
        LEAF_ENTRY RhpByRefAssignRef

        ;; See comment in RhpAssignRef
        dmb

        GLOBAL_LABEL RhpByRefAssignRefAVLocation1
        ldr          r2, [r1]
        GLOBAL_LABEL RhpByRefAssignRefAVLocation2
        str          r2, [r0]

        ;; Check whether the writes were even into the heap. If not there's no card update required.
        PREPARE_EXTERNAL_VAR_INDIRECT g_lowest_address, r3
        cmp          r0, r3
        blo          RhpByRefAssignRef_NotInHeap
        PREPARE_EXTERNAL_VAR_INDIRECT g_highest_address, r3
        cmp          r0, r3
        bhs          RhpByRefAssignRef_NotInHeap

        ;; Update the shadow copy of the heap with the same value just written to the same heap. (A no-op unless
        ;; we're in a debug build and write barrier checking has been enabled).
        UPDATE_GC_SHADOW RhpByRefAssignRef, r2, r0

        UPDATE_WRITE_WATCH_TABLE RhpByRefAssignRef, r0, r12, r3

        ;; If the reference is to an object that's not in an ephemeral generation we have no need to track it
        ;; (since the object won't be collected or moved by an ephemeral collection).
        PREPARE_EXTERNAL_VAR_INDIRECT g_ephemeral_low, r3
        cmp          r2, r3
        blo          RhpByRefAssignRef_NotInHeap
        PREPARE_EXTERNAL_VAR_INDIRECT g_ephemeral_high, r3
        cmp          r2, r3
        bhs          RhpByRefAssignRef_NotInHeap

        ;; move current r0 value into r2 and then increment the pointers
        mov          r2, r0
        add          r1, #4
        add          r0, #4

        ;; We have a location on the GC heap being updated with a reference to an ephemeral object so we must
        ;; track this write. The location address is translated into an offset in the card table bitmap. We set
        ;; an entire byte in the card table since it's quicker than messing around with bitmasks and we only write
        ;; the byte if it hasn't already been done since writes are expensive and impact scaling.
        PREPARE_EXTERNAL_VAR_INDIRECT g_card_table, r3
        add          r2, r3, r2, lsr #10
        ldrb         r3, [r2]
        cmp          r3, #0x0FF
        bne          RhpByRefAssignRef_UpdateCardTable
        bx           lr

;; We get here if it's necessary to update the card table.
RhpByRefAssignRef_UpdateCardTable
        mov          r3, #0x0FF
        strb         r3, [r2]
        bx           lr

RhpByRefAssignRef_NotInHeap
        ;; Increment the pointers before leaving
        add          r0, #4
        add          r1, #4
        bx           lr

        LEAF_END RhpByRefAssignRef

        END
