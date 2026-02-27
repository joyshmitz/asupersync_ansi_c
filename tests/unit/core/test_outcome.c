/*
 * test_outcome.c — unit tests for outcome severity lattice
 *
 * SPDX-License-Identifier: MIT
 */

#include "test_harness.h"
#include <asx/core/outcome.h>

TEST(outcome_severity_of_null) {
    ASSERT_EQ(asx_outcome_severity_of(NULL), ASX_OUTCOME_OK);
}

TEST(outcome_severity_of_ok) {
    asx_outcome o = asx_outcome_make(ASX_OUTCOME_OK);
    ASSERT_EQ(asx_outcome_severity_of(&o), ASX_OUTCOME_OK);
}

TEST(outcome_severity_of_err) {
    asx_outcome o = asx_outcome_make(ASX_OUTCOME_ERR);
    ASSERT_EQ(asx_outcome_severity_of(&o), ASX_OUTCOME_ERR);
}

TEST(outcome_severity_of_cancelled) {
    asx_outcome o = asx_outcome_make(ASX_OUTCOME_CANCELLED);
    ASSERT_EQ(asx_outcome_severity_of(&o), ASX_OUTCOME_CANCELLED);
}

TEST(outcome_severity_of_panicked) {
    asx_outcome o = asx_outcome_make(ASX_OUTCOME_PANICKED);
    ASSERT_EQ(asx_outcome_severity_of(&o), ASX_OUTCOME_PANICKED);
}

TEST(outcome_lattice_order) {
    ASSERT_TRUE(ASX_OUTCOME_OK < ASX_OUTCOME_ERR);
    ASSERT_TRUE(ASX_OUTCOME_ERR < ASX_OUTCOME_CANCELLED);
    ASSERT_TRUE(ASX_OUTCOME_CANCELLED < ASX_OUTCOME_PANICKED);
}

TEST(outcome_join_max_severity) {
    asx_outcome ok = asx_outcome_make(ASX_OUTCOME_OK);
    asx_outcome err = asx_outcome_make(ASX_OUTCOME_ERR);
    asx_outcome result = asx_outcome_join(&ok, &err);
    ASSERT_EQ(asx_outcome_severity_of(&result), ASX_OUTCOME_ERR);
}

TEST(outcome_join_left_bias) {
    /* Equal severity: left operand wins */
    asx_outcome a = asx_outcome_make(ASX_OUTCOME_ERR);
    asx_outcome b = asx_outcome_make(ASX_OUTCOME_ERR);
    asx_outcome result = asx_outcome_join(&a, &b);
    ASSERT_EQ(asx_outcome_severity_of(&result), ASX_OUTCOME_ERR);
}

TEST(outcome_join_null_identity) {
    asx_outcome err = asx_outcome_make(ASX_OUTCOME_ERR);
    asx_outcome result = asx_outcome_join(NULL, &err);
    ASSERT_EQ(asx_outcome_severity_of(&result), ASX_OUTCOME_ERR);
    result = asx_outcome_join(&err, NULL);
    ASSERT_EQ(asx_outcome_severity_of(&result), ASX_OUTCOME_ERR);
}

TEST(outcome_join_both_null) {
    asx_outcome result = asx_outcome_join(NULL, NULL);
    ASSERT_EQ(asx_outcome_severity_of(&result), ASX_OUTCOME_OK);
}

int main(void) {
    fprintf(stderr, "=== test_outcome ===\n");
    RUN_TEST(outcome_severity_of_null);
    RUN_TEST(outcome_severity_of_ok);
    RUN_TEST(outcome_severity_of_err);
    RUN_TEST(outcome_severity_of_cancelled);
    RUN_TEST(outcome_severity_of_panicked);
    RUN_TEST(outcome_lattice_order);
    RUN_TEST(outcome_join_max_severity);
    RUN_TEST(outcome_join_left_bias);
    RUN_TEST(outcome_join_null_identity);
    RUN_TEST(outcome_join_both_null);
    TEST_REPORT();
    return test_failures;
}
