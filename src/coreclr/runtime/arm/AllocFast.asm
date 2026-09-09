;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include <AsmMacros_Shared.h>

        TEXTAREA

;; Shared code for RhpNewFast, RhpNewFastAlign8 and RhpNewFastMisalign
;;  r0 == MethodTable
        MACRO
        NEW_FAST $Variation

        ;; r1 = ee_alloc_context pointer, TRASHES r2
        INLINE_GET_ALLOC_CONTEXT_BASE r1, r2

        ldr         r2, [r0, #OFFSETOF__MethodTable__m_uBaseSize]

        ;; Load potential new object address into r3.
        ldr         r3, [r1, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__alloc_ptr)]

        ;; Load and calculate the maximum size of object we can fit.
        ldr         r12, [r1, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__combined_limit)]
        sub         r12, r3

        ;; When doing aligned or misaligned allocation we first check the alignment and skip to the
        ;; regular path if it's already matching the expectation. Otherwise, we try to allocate
        ;; size + ASM_MIN_OBJECT_SIZE and then prepend a dummy free object at the beginning of the
        ;; allocation.
        IF "$Variation" != ""

        tst         r3, #0x7
        IF "$Variation" == "Align8"
        beq         AlreadyAligned$Variation
        ELSE ;; Variation == "Misalign"
        bne         AlreadyAligned$Variation
        ENDIF

        add         r2, #ASM_MIN_OBJECT_SIZE

        ;; Determine whether the end of the object is too big for the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        cmp         r2, r12
        bhi         AllocFailed$Variation

        ;; Update the alloc pointer to account for the allocation.
        add         r2, r3
        str         r2, [r1, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__alloc_ptr)]

        ;; Initialize the padding object preceeding the new object.
        PREPARE_EXTERNAL_VAR_INDIRECT $G_FREE_OBJECT_METHOD_TABLE, r2
        str         r2, [r3, #OFFSETOF__Object__m_pEEType]
        mov         r2, #0
        str         r2, [r3, #OFFSETOF__Array__m_Length]

        ;; Calculate the new object pointer and initialize it.
        add         r3, #ASM_MIN_OBJECT_SIZE
        str         r0, [r3, #OFFSETOF__Object__m_pEEType]

        ;; Return the object allocated in r0.
        mov         r0, r3

        bx          lr

        ENDIF ;; Variation != ""

AlreadyAligned$Variation

        ;; r0: MethodTable pointer
        ;; r1: ee_alloc_context pointer
        ;; r2: base size
        ;; r3: ee_alloc_context.alloc_ptr
        ;; r12: ee_alloc_context.combined_limit - ee_alloc_context.alloc_ptr

        ;; Determine whether the end of the object is too big for the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        cmp         r2, r12
        bhi         AllocFailed$Variation

        ;; Calculate the new alloc pointer to account for the allocation.
        add         r2, r3

        ;; Set the new object's MethodTable pointer.
        str         r0, [r3, #OFFSETOF__Object__m_pEEType]

        ;; Update the alloc pointer to the newly calculated one.
        str         r2, [r1, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__alloc_ptr)]

        ;; Return the object allocated in r0.
        mov         r0, r3

        bx          lr

AllocFailed$Variation
        ;; The MethodTable is still in r0.
        IF "$Variation" == ""
        mov         r1, #0
        ELSE
        IF "$Variation" == "Align8"
        mov         r1, #GC_ALLOC_ALIGN8
        ELSE
        mov         r1, #(GC_ALLOC_ALIGN8 :OR: GC_ALLOC_ALIGN8_BIAS)
        ENDIF
        ENDIF
        b           RhpNewObject

        MEND

;; Allocate non-array, non-finalizable object. If the allocation doesn't fit into the current thread's
;; allocation context then automatically fallback to the slow allocation path.
;;  r0 == MethodTable
        LEAF_ENTRY RhpNewFast
        NEW_FAST
        LEAF_END RhpNewFast

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate simple object (not finalizable, array or value type) on an 8 byte boundary.
;;  r0 == MethodTable
        LEAF_ENTRY RhpNewFastAlign8
        NEW_FAST Align8
        LEAF_END RhpNewFastAlign8

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate a value type object (i.e. box it) on an 8 byte boundary + 4 (so that the value type payload
;; itself is 8 byte aligned).
;;  r0 == MethodTable
        LEAF_ENTRY RhpNewFastMisalign
        NEW_FAST Misalign
        LEAF_END RhpNewFastMisalign

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate non-array object with finalizer.
;;  r0 == MethodTable
        LEAF_ENTRY RhpNewFinalizable
        mov         r1, #GC_ALLOC_FINALIZE
        b           RhpNewObject
        LEAF_END RhpNewFinalizable

;; Allocate a finalizable object (by definition not an array or value type) on an 8 byte boundary.
;;  r0 == MethodTable
        LEAF_ENTRY RhpNewFinalizableAlign8
        mov         r1, #(GC_ALLOC_FINALIZE :OR: GC_ALLOC_ALIGN8)
        b           RhpNewObject
        LEAF_END RhpNewFinalizableAlign8

;; Allocate non-array object.
;;  r0 == MethodTable
;;  r1 == alloc flags
        NESTED_ENTRY RhpNewObject

        PUSH_COOP_PINVOKE_FRAME r3

        ;; r0: MethodTable
        ;; r1: alloc flags
        ;; r3: transition frame

        ;; Preserve the MethodTable in r5.
        mov         r5, r0

        mov         r2, #0              ; numElements

        ;; void* RhpGcAlloc(MethodTable *pEEType, uint32_t uFlags, intptr_t numElements, void * pTransitionFrame)
        blx         RhpGcAlloc

        cbz         r0, NewOutOfMemory

        POP_COOP_PINVOKE_FRAME
        EPILOG_RETURN

NewOutOfMemory
        ;; This is the OOM failure path. We're going to tail-call to a managed helper that will throw
        ;; an out of memory exception that the caller of this allocator understands.

        mov         r0, r5              ; MethodTable pointer
        mov         r1, #0              ; Indicate that we should throw OOM.

        POP_COOP_PINVOKE_FRAME
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewObject

;; Shared code for RhNewString, RhpNewArrayFast and RhpNewPtrArrayFast
;;  r0 == MethodTable
;;  r1 == character/element count
;;  r2 == string/array size
;; Must be used from a method that saved r4 and lr in its prolog.
        MACRO
        NEW_ARRAY_FAST $Name

        mov         r4, r0                              ; Save MethodTable

        ;; r0 = ee_alloc_context pointer, TRASHES r3
        INLINE_GET_ALLOC_CONTEXT_BASE r0, r3

        ;; Load potential new object address into r3.
        ldr         r3, [r0, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__alloc_ptr)]

        ;; Load and calculate the maximum size of object we can fit.
        ldr         r12, [r0, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__combined_limit)]
        sub         r12, r3

        ;; Determine whether the end of the object is too big for the current allocation context. If so,
        ;; we abandon the attempt to allocate the object directly and fall back to the slow helper.
        cmp         r2, r12
        bhi         $Name._RarePath

        ;; Calculate the alloc pointer to account for the allocation.
        add         r2, r3

        ;; Set the new object's MethodTable pointer and element count.
        str         r4, [r3, #OFFSETOF__Object__m_pEEType]
        str         r1, [r3, #OFFSETOF__Array__m_Length]

        ;; Update the alloc pointer to the newly calculated one.
        str         r2, [r0, #(OFFSETOF__ee_alloc_context + OFFSETOF__ee_alloc_context__alloc_ptr)]

        ;; Return the object allocated in r0.
        mov         r0, r3

        EPILOG_POP  {r4,pc}

$Name._RarePath
        ;; r0 == MethodTable
        ;; r1 == element count
        mov         r0, r4
        EPILOG_POP  {r4,lr}
        EPILOG_BRANCH RhpNewVariableSizeObject

        MEND

;; Allocate a string.
;;  r0 == MethodTable
;;  r1 == element/character count
        NESTED_ENTRY RhNewString
        PROLOG_PUSH {r4,lr}

        ;; Make sure computing the overall allocation size won't overflow
        MOV32       r12, MAX_STRING_LENGTH
        cmp         r1, r12
        bhi         StringSizeOverflow

        ;; Compute overall allocation size (align(base size + (element size * elements), 4)).
        mov         r2, #(STRING_BASE_SIZE + 3)
#if STRING_COMPONENT_SIZE == 2
        add         r2, r2, r1, lsl #1                  ; r2 += characters * 2
#else
        NotImplementedComponentSize
#endif
        bic         r2, r2, #3

        NEW_ARRAY_FAST RhNewString

StringSizeOverflow
        ;; We get here if the size of the final string object can't be represented as an unsigned
        ;; 32-bit value. We're going to tail-call to a managed helper that will throw
        ;; an OOM exception that the caller of this allocator understands.

        ;; MethodTable is in r0 already
        mov         r1, #0                              ; Indicate that we should throw OOM
        EPILOG_POP  {r4,lr}
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhNewString

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate one dimensional, zero based array (SZARRAY).
;;  r0 == MethodTable
;;  r1 == element count
        NESTED_ENTRY RhpNewArrayFast
        PROLOG_PUSH {r4,lr}

        ;; Compute overall allocation size (align(base size + (element size * elements), 4)).
        ;; if the element count is <= 0x10000, no overflow is possible because the component
        ;; size is <= 0xffff (it's an unsigned 16-bit value) and thus the product is <= 0xffff0000
        ;; and the base size for the worst case (32 dimensional MdArray) is less than 0xffff.
        ldrh        r2, [r0, #OFFSETOF__MethodTable__m_usComponentSize]
        cmp         r1, #0x10000
        bhi         ArraySizeBig
        umull       r2, r3, r2, r1
        adds        r2, #(SZARRAY_BASE_SIZE + 3)
ArrayAlignSize
        bic         r2, r2, #3

        NEW_ARRAY_FAST RhpNewArrayFast

ArraySizeBig
        ;; if the element count is negative, it's an overflow error
        cmp         r1, #0
        blt         ArraySizeOverflow

        ;; now we know the element count is in the signed int range [0..0x7fffffff]
        ;; overflow in computing the total size of the array size gives an out of memory exception,
        ;; NOT an overflow exception
        ;; we already have the component size in r2
        umull       r2, r3, r2, r1
        cbnz        r3, ArrayOutOfMemoryFinal
        ldr         r3, [r0, #OFFSETOF__MethodTable__m_uBaseSize]
        adds        r2, r3
        bcs         ArrayOutOfMemoryFinal
        adds        r2, #3
        bcs         ArrayOutOfMemoryFinal
        b           ArrayAlignSize

ArrayOutOfMemoryFinal
        ;; MethodTable is in r0 already
        mov         r1, #0                              ; Indicate that we should throw OOM.
        EPILOG_POP  {r4,lr}
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

ArraySizeOverflow
        ;; We get here if the size of the final array object can't be represented as an unsigned
        ;; 32-bit value. We're going to tail-call to a managed helper that will throw
        ;; an overflow exception that the caller of this allocator understands.

        ;; MethodTable is in r0 already
        mov         r1, #1                              ; Indicate that we should throw OverflowException
        EPILOG_POP  {r4,lr}
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewArrayFast

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate one dimensional, zero based array (SZARRAY) of pointer sized elements.
;;  r0 == MethodTable
;;  r1 == element count
        NESTED_ENTRY RhpNewPtrArrayFast
        PROLOG_PUSH {r4,lr}

        ;; Delegate overflow handling to the generic helper conservatively

        mov         r2, #(1 :SHL: 28)                   ; 0x40000000 / sizeof(void*)
        cmp         r1, r2
        bhs         RhpNewPtrArrayFast_RarePath2

        mov         r2, #SZARRAY_BASE_SIZE
        add         r2, r2, r1, lsl #2

        NEW_ARRAY_FAST RhpNewPtrArrayFast

RhpNewPtrArrayFast_RarePath2
        EPILOG_POP  {r4,lr}
        EPILOG_BRANCH RhpNewArrayFast

        NESTED_END RhpNewPtrArrayFast

        INLINE_GET_ALLOC_CONTEXT_BASE_CONSTANT_POOL

;; Allocate variable sized object (eg. array, string) using the slow path that calls a runtime helper.
;;  r0 == MethodTable
;;  r1 == element count
        NESTED_ENTRY RhpNewVariableSizeObject

        PUSH_COOP_PINVOKE_FRAME r3

        ;; Preserve the MethodTable in r5.
        mov         r5, r0

        mov         r2, r1              ; numElements
        mov         r1, #0              ; uFlags

        ;; void* RhpGcAlloc(MethodTable *pEEType, uint32_t uFlags, intptr_t numElements, void * pTransitionFrame)
        blx         RhpGcAlloc

        ;; Test for failure (NULL return).
        cbz         r0, RhpNewVariableSizeObject_OutOfMemory

        POP_COOP_PINVOKE_FRAME
        EPILOG_RETURN

RhpNewVariableSizeObject_OutOfMemory
        mov         r0, r5              ; MethodTable
        mov         r1, #0              ; Indicate that we should throw OOM.

        POP_COOP_PINVOKE_FRAME
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewVariableSizeObject

;; Allocate an array on an 8 byte boundary.
;;  r0 == MethodTable
;;  r1 == element count
        NESTED_ENTRY RhpNewArrayFastAlign8

        PUSH_COOP_PINVOKE_FRAME r3

        ;; Compute overall allocation size (base size + align((element size * elements), 4)).
        ldrh        r2, [r0, #OFFSETOF__MethodTable__m_usComponentSize]
        umull       r2, r4, r2, r1
        cbnz        r4, Array8SizeOverflow
        adds        r2, #3
        bcs         Array8SizeOverflow
        bic         r2, r2, #3
        ldr         r4, [r0, #OFFSETOF__MethodTable__m_uBaseSize]
        adds        r2, r4
        bcs         Array8SizeOverflow

        ;; Preserve the MethodTable in r5.
        mov         r5, r0

        mov         r2, r1                  ; numElements
        mov         r1, #GC_ALLOC_ALIGN8    ; uFlags

        ;; void* RhpGcAlloc(MethodTable *pEEType, uint32_t uFlags, intptr_t numElements, void * pTransitionFrame)
        blx         RhpGcAlloc

        ;; Test for failure (NULL return).
        cbz         r0, Array8OutOfMemory

        POP_COOP_PINVOKE_FRAME
        EPILOG_RETURN

Array8SizeOverflow
        ;; We get here if the size of the final array object can't be represented as an unsigned
        ;; 32-bit value. We're going to tail-call to a managed helper that will throw
        ;; an OOM or overflow exception that the caller of this allocator understands.

        ;; if the element count is non-negative, it's an OOM error
        cmp         r1, #0
        bge         Array8OutOfMemory1

        ;; r0 holds MethodTable pointer already
        mov         r1, #1              ; Indicate that we should throw OverflowException

        POP_COOP_PINVOKE_FRAME
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

Array8OutOfMemory
        ;; This is the OOM failure path. We're going to tail-call to a managed helper that will throw
        ;; an out of memory exception that the caller of this allocator understands.

        mov         r0, r5              ; MethodTable pointer

Array8OutOfMemory1

        mov         r1, #0              ; Indicate that we should throw OOM.

        POP_COOP_PINVOKE_FRAME
        EPILOG_BRANCH RhExceptionHandling_FailedAllocation

        NESTED_END RhpNewArrayFastAlign8

        END
