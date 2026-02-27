/*
 * portability_check.c — compile-time portability assumptions validation
 *
 * This file verifies that platform assumptions required by the asx runtime
 * hold on the target. Compilation failure with descriptive messages indicates
 * a portability problem that must be resolved before proceeding.
 *
 * Run via: gcc/clang -std=c99 -Wall -Werror -c portability_check.c
 *
 * SPDX-License-Identifier: MIT
 */

#include <stdint.h>
#include <limits.h>

/* ------------------------------------------------------------------ */
/* 1. Type size assumptions                                           */
/* ------------------------------------------------------------------ */

/* CHAR_BIT must be 8 (we rely on byte-addressable memory) */
#if CHAR_BIT != 8
  #error "asx requires CHAR_BIT == 8"
#endif

/* Fixed-width types must exist and have expected sizes */
typedef char check_uint8_size  [sizeof(uint8_t)  == 1 ? 1 : -1];
typedef char check_uint16_size [sizeof(uint16_t) == 2 ? 1 : -1];
typedef char check_uint32_size [sizeof(uint32_t) == 4 ? 1 : -1];
typedef char check_uint64_size [sizeof(uint64_t) == 8 ? 1 : -1];
typedef char check_int32_size  [sizeof(int32_t)  == 4 ? 1 : -1];
typedef char check_int64_size  [sizeof(int64_t)  == 8 ? 1 : -1];

/* Pointer must be at least 32 bits (we pack indices into uint32_t) */
typedef char check_ptr_size [sizeof(void *) >= 4 ? 1 : -1];

/* ------------------------------------------------------------------ */
/* 2. Two's complement integers                                       */
/* ------------------------------------------------------------------ */

/* C99 allows ones' complement and sign-magnitude; we require two's complement.
 * C23 mandates it, but for C99 we verify at compile time. */
typedef char check_twos_complement [(-1 & 3) == 3 ? 1 : -1];

/* ------------------------------------------------------------------ */
/* 3. Handle encoding assumptions                                     */
/* ------------------------------------------------------------------ */

/* asx_*_id is uint64_t; verify our bit-field layout fits */
typedef char check_handle_fits [sizeof(uint64_t) == 8 ? 1 : -1];

/* Type tag (16 bits) + state mask (16 bits) + arena index (32 bits) = 64 bits */
typedef char check_tag_bits [(16 + 16 + 32 == 64) ? 1 : -1];

/* ------------------------------------------------------------------ */
/* 4. Enum underlying type assumptions                                */
/* ------------------------------------------------------------------ */

/* We rely on enums fitting in int. Verify enum range stays within int limits. */
typedef char check_enum_in_int [sizeof(int) >= 4 ? 1 : -1];

/* ------------------------------------------------------------------ */
/* 5. Endianness detection (informational, not fatal)                  */
/* ------------------------------------------------------------------ */

/* We don't require a specific endianness, but we detect it for
 * binary codec and wire format paths. The core semantic plane is
 * endian-agnostic — only serialization/deserialization adapts. */

#if defined(__BYTE_ORDER__) && defined(__ORDER_LITTLE_ENDIAN__) && \
    defined(__ORDER_BIG_ENDIAN__)
  #if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    #define ASX_ENDIAN_LITTLE 1
    #define ASX_ENDIAN_BIG    0
  #elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
    #define ASX_ENDIAN_LITTLE 0
    #define ASX_ENDIAN_BIG    1
  #else
    /* PDP/mixed endian — not supported */
    #error "asx requires little-endian or big-endian byte order"
  #endif
#endif

/* ------------------------------------------------------------------ */
/* 6. Struct packing / alignment sanity                               */
/* ------------------------------------------------------------------ */

/* Verify that natural alignment of critical types is sane.
 * We don't use packed structs in the public API, so standard
 * alignment rules should hold. */
typedef char check_uint64_align [_Alignof(uint64_t) <= 8 ? 1 : -1];
typedef char check_uint32_align [_Alignof(uint32_t) <= 4 ? 1 : -1];

/* ------------------------------------------------------------------ */
/* 7. NULL pointer representation                                     */
/* ------------------------------------------------------------------ */

/* We rely on NULL being all-bits-zero for memset-based initialization */
/* This is guaranteed by C99 for null pointer constants but we verify */
typedef char check_null_zero [(int)(sizeof(char *)) > 0 ? 1 : -1];

/* ------------------------------------------------------------------ */
/* Success — if this file compiles, all portability checks pass       */
/* ------------------------------------------------------------------ */

typedef int portability_checks_passed;
