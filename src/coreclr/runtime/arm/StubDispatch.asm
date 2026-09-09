;; Licensed to the .NET Foundation under one or more agreements.
;; The .NET Foundation licenses this file to you under the MIT license.

#include "AsmMacros_Shared.h"

        TEXTAREA

#ifdef FEATURE_CACHED_INTERFACE_DISPATCH

        IMPORT RhpCidResolve
        IMPORT RhpUniversalTransition_DebugStepTailCall

;; Macro that generates code to check a single cache entry.
    MACRO
        CHECK_CACHE_ENTRY $entry, $entries
        ;; Check a single entry in the cache.
        ;;  r1  : Instance MethodTable*
        ;;  r2  : Cache data structure
        ;;  r12 : Trashed. On successful check, set to the target address to jump to.

        ldr          r12, [r2, #(OFFSETOF__InterfaceDispatchCache__m_rgEntries + ($entry * 8))]
        cmp          r1, r12
        bne          %ft0
        ldr          r12, [r2, #(OFFSETOF__InterfaceDispatchCache__m_rgEntries + ($entry * 8) + 4)]
        b            RhpInterfaceDispatch$entries._CacheHit
0
    MEND

;; Macro that generates a stub consuming a cache with the given number of entries.
    MACRO
        DEFINE_INTERFACE_DISPATCH_STUB $entries

    LEAF_ENTRY RhpInterfaceDispatch$entries
        ;; r12 currently contains the indirection cell address. But we need more scratch registers and
        ;; we may A/V on a null this. Store r1 and r2 in the red zone.
        ;;
        ;; NOTE: sp must not be modified anywhere in this helper. When a null this causes an A/V here
        ;; the exception dispatcher unwinds to the caller by simply taking lr (see
        ;; UnwindSimpleHelperToCaller in EHHelpers.cpp), which is only valid while sp is unchanged.
        str          r1, [sp, #-8]
        str          r2, [sp, #-4]

        ;; r12 currently holds the indirection cell address. We need to get the cache structure instead.
        ldr          r2, [r12, #OFFSETOF__InterfaceDispatchCell__m_pCache]

        ;; Load the MethodTable from the object instance in r0.
        GLOBAL_LABEL RhpInterfaceDispatchAVLocation$entries
        ldr          r1, [r0]

    GBLA CurrentEntry
CurrentEntry SETA 0
    WHILE CurrentEntry < $entries
        CHECK_CACHE_ENTRY CurrentEntry, $entries
CurrentEntry SETA CurrentEntry + 1
    WEND

        ;; Point r12 to the indirection cell using the back pointer in the cache block
        ldr          r12, [r2, #OFFSETOF__InterfaceDispatchCache__m_pCell]

        ldr          r1, [sp, #-8]
        ldr          r2, [sp, #-4]
        b.w          RhpInterfaceDispatchSlow

;; Common exit path for cache hits.
RhpInterfaceDispatch$entries._CacheHit
        ;; r2 contains address of the cache block. We store it in the red zone in case the target we jump
        ;; to needs it.
        ;; r12 contains the target address to jump to
        ldr          r1, [sp, #-8]
        ;; We have to store r2 with address of the cache block into the red zone before restoring the
        ;; original r2.
        str          r2, [sp, #-8]
        ldr          r2, [sp, #-4]
        bx           r12

    LEAF_END RhpInterfaceDispatch$entries

    MEND

;; Define all the stub routines we currently need.
;;
;; The mrt100dbi requires these be exported to identify mrt100 code that dispatches back into managed.
;; If you change or add any new dispatch stubs, please also change slr.def and dbi\process.cpp CordbProcess::GetExportStepInfo
;;
    DEFINE_INTERFACE_DISPATCH_STUB 1
    DEFINE_INTERFACE_DISPATCH_STUB 2
    DEFINE_INTERFACE_DISPATCH_STUB 4
    DEFINE_INTERFACE_DISPATCH_STUB 8
    DEFINE_INTERFACE_DISPATCH_STUB 16
    DEFINE_INTERFACE_DISPATCH_STUB 32
    DEFINE_INTERFACE_DISPATCH_STUB 64

;; Initial dispatch on an interface when we don't have a cache yet.
    LEAF_ENTRY RhpInitialInterfaceDispatch
        ;; Just tail call to the cache miss helper.
        b            RhpInterfaceDispatchSlow
    LEAF_END RhpInitialInterfaceDispatch

;; Not an alternate entry due to the missed thumb bit in this case
;; See https://github.com/dotnet/runtime/issues/8608
    LEAF_ENTRY RhpInitialDynamicInterfaceDispatch
        ;; Just tail call to the cache miss helper.
        b            RhpInterfaceDispatchSlow
    LEAF_END RhpInitialDynamicInterfaceDispatch

;; Cache miss case, call the runtime to resolve the target and update the cache.
;; Use universal transition helper to allow an exception to flow out of resolution
    LEAF_ENTRY RhpInterfaceDispatchSlow
        ;; r12 has the interface dispatch cell address in it.
        ;; The calling convention of the universal thunk is that the parameter
        ;; for the universal thunk target is to be placed in sp-8
        ;; and the universal thunk target address is to be placed in sp-4
        str          r12, [sp, #-8]
        PREPARE_EXTERNAL_VAR RhpCidResolve, r12
        str          r12, [sp, #-4]

        ;; jump to universal transition thunk
        b            RhpUniversalTransition_DebugStepTailCall
    LEAF_END RhpInterfaceDispatchSlow

#endif ;; FEATURE_CACHED_INTERFACE_DISPATCH

        END
