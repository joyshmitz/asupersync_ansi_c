/*
 * test_transition.c — unit tests for transition authority tables
 *
 * SPDX-License-Identifier: MIT
 */

#include "../../test_harness.h"
#include <asx/core/transition.h>

/* Region transitions */
TEST(region_legal_forward) {
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_OPEN, ASX_REGION_CLOSING), ASX_OK);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSING, ASX_REGION_DRAINING), ASX_OK);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSING, ASX_REGION_FINALIZING), ASX_OK);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_DRAINING, ASX_REGION_FINALIZING), ASX_OK);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_FINALIZING, ASX_REGION_CLOSED), ASX_OK);
}

TEST(region_forbidden_backward) {
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSING, ASX_REGION_OPEN), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_DRAINING, ASX_REGION_OPEN), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_FINALIZING, ASX_REGION_OPEN), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_OPEN), ASX_E_INVALID_TRANSITION);
}

TEST(region_forbidden_skip) {
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_OPEN, ASX_REGION_DRAINING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_OPEN, ASX_REGION_FINALIZING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_OPEN, ASX_REGION_CLOSED), ASX_E_INVALID_TRANSITION);
}

TEST(region_closed_absorbing) {
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_OPEN), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_CLOSING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_DRAINING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_FINALIZING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_region_transition_check(ASX_REGION_CLOSED, ASX_REGION_CLOSED), ASX_E_INVALID_TRANSITION);
}

TEST(region_predicates) {
    ASSERT_TRUE(asx_region_can_spawn(ASX_REGION_OPEN));
    ASSERT_FALSE(asx_region_can_spawn(ASX_REGION_CLOSING));
    ASSERT_FALSE(asx_region_can_spawn(ASX_REGION_FINALIZING));
    ASSERT_TRUE(asx_region_can_accept_work(ASX_REGION_OPEN));
    ASSERT_TRUE(asx_region_can_accept_work(ASX_REGION_FINALIZING));
    ASSERT_FALSE(asx_region_can_accept_work(ASX_REGION_DRAINING));
    ASSERT_TRUE(asx_region_is_closing(ASX_REGION_CLOSING));
    ASSERT_TRUE(asx_region_is_closing(ASX_REGION_DRAINING));
    ASSERT_TRUE(asx_region_is_closing(ASX_REGION_FINALIZING));
    ASSERT_FALSE(asx_region_is_closing(ASX_REGION_OPEN));
    ASSERT_TRUE(asx_region_is_terminal(ASX_REGION_CLOSED));
    ASSERT_FALSE(asx_region_is_terminal(ASX_REGION_OPEN));
}

/* Task transitions */
TEST(task_legal_happy_path) {
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_CREATED, ASX_TASK_RUNNING), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_RUNNING, ASX_TASK_COMPLETED), ASX_OK);
}

TEST(task_legal_cancel_path) {
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_RUNNING, ASX_TASK_CANCEL_REQUESTED), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_CANCEL_REQUESTED, ASX_TASK_CANCELLING), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_CANCELLING, ASX_TASK_FINALIZING), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_FINALIZING, ASX_TASK_COMPLETED), ASX_OK);
}

TEST(task_self_transitions) {
    /* Strengthening (self-transitions) */
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_CANCEL_REQUESTED, ASX_TASK_CANCEL_REQUESTED), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_CANCELLING, ASX_TASK_CANCELLING), ASX_OK);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_FINALIZING, ASX_TASK_FINALIZING), ASX_OK);
}

TEST(task_completed_absorbing) {
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_CREATED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_RUNNING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_CANCEL_REQUESTED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_CANCELLING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_FINALIZING), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_task_transition_check(ASX_TASK_COMPLETED, ASX_TASK_COMPLETED), ASX_E_INVALID_TRANSITION);
}

/* Obligation transitions */
TEST(obligation_legal) {
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_RESERVED, ASX_OBLIGATION_COMMITTED), ASX_OK);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_RESERVED, ASX_OBLIGATION_ABORTED), ASX_OK);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_RESERVED, ASX_OBLIGATION_LEAKED), ASX_OK);
}

TEST(obligation_terminal_absorbing) {
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_COMMITTED, ASX_OBLIGATION_RESERVED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_COMMITTED, ASX_OBLIGATION_COMMITTED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_COMMITTED, ASX_OBLIGATION_ABORTED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_ABORTED, ASX_OBLIGATION_COMMITTED), ASX_E_INVALID_TRANSITION);
    ASSERT_EQ(asx_obligation_transition_check(ASX_OBLIGATION_LEAKED, ASX_OBLIGATION_COMMITTED), ASX_E_INVALID_TRANSITION);
}

int main(void) {
    fprintf(stderr, "=== test_transition ===\n");
    RUN_TEST(region_legal_forward);
    RUN_TEST(region_forbidden_backward);
    RUN_TEST(region_forbidden_skip);
    RUN_TEST(region_closed_absorbing);
    RUN_TEST(region_predicates);
    RUN_TEST(task_legal_happy_path);
    RUN_TEST(task_legal_cancel_path);
    RUN_TEST(task_self_transitions);
    RUN_TEST(task_completed_absorbing);
    RUN_TEST(obligation_legal);
    RUN_TEST(obligation_terminal_absorbing);
    TEST_REPORT();
    return test_failures;
}
