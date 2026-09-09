// Licensed to the .NET Foundation under one or more agreements.
// The .NET Foundation licenses this file to you under the MIT license.

// This file is used to allow sharing of assembly code between NativeAOT and CoreCLR, which have different conventions about how to ensure that constants offsets are accessible

#ifdef TARGET_WINDOWS
#include "ksarm.h"
#include "asmconstants.h"
#include "asmmacros.h"

    SETALIAS G_FREE_OBJECT_METHOD_TABLE, ?g_pFreeObjectMethodTable@@3PAVMethodTable@@A

    IMPORT g_lowest_address
    IMPORT g_highest_address
    IMPORT g_ephemeral_low
    IMPORT g_ephemeral_high
    IMPORT g_card_table

#ifdef FEATURE_MANUALLY_MANAGED_CARD_BUNDLES
    IMPORT g_card_bundle_table
#endif

#ifdef FEATURE_USE_SOFTWARE_WRITE_WATCH_FOR_GC_HEAP
    IMPORT g_write_watch_table
#endif

    IMPORT $G_FREE_OBJECT_METHOD_TABLE

    IMPORT RhpGcAlloc
    IMPORT RhExceptionHandling_FailedAllocation

#else
#include "asmconstants.h"
#include "unixasmmacros.inc"
#endif
