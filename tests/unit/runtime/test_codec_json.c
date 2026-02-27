/*
 * test_codec_json.c — JSON codec baseline tests (bd-2n0.1)
 *
 * SPDX-License-Identifier: MIT
 */

#include "../../test_harness.h"
#include <asx/asx.h>
#include <stdlib.h>
#include <string.h>

static char *dup_text(const char *text)
{
    size_t len;
    char *copy;

    len = strlen(text);
    copy = (char *)malloc(len + 1u);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, text, len + 1u);
    return copy;
}

static void populate_fixture(asx_canonical_fixture *fixture)
{
    fixture->scenario_id = dup_text("scenario.codec.json.001");
    fixture->fixture_schema_version = dup_text("fixture-v1");
    fixture->scenario_dsl_version = dup_text("dsl-v1");
    fixture->profile = dup_text("ASX_PROFILE_CORE");
    fixture->codec = ASX_CODEC_KIND_JSON;
    fixture->seed = 42u;
    fixture->input_json = dup_text("{\"ops\":[]}");
    fixture->expected_events_json = dup_text("[]");
    fixture->expected_final_snapshot_json = dup_text("{}");
    fixture->expected_error_codes_json = dup_text("[]");
    fixture->semantic_digest = dup_text(
        "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    fixture->provenance.rust_baseline_commit = dup_text("0123456789abcdef0123456789abcdef01234567");
    fixture->provenance.rust_toolchain_commit_hash = dup_text("toolchain-abcdef12");
    fixture->provenance.rust_toolchain_release = dup_text("rustc 1.90.0");
    fixture->provenance.rust_toolchain_host = dup_text("x86_64-unknown-linux-gnu");
    fixture->provenance.cargo_lock_sha256 = dup_text(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    fixture->provenance.capture_run_id = dup_text("capture-run-0001");
}

TEST(json_round_trip_is_stable) {
    asx_canonical_fixture fixture;
    asx_canonical_fixture decoded;
    asx_codec_buffer json_a;
    asx_codec_buffer json_b;

    asx_canonical_fixture_init(&fixture);
    asx_canonical_fixture_init(&decoded);
    asx_codec_buffer_init(&json_a);
    asx_codec_buffer_init(&json_b);

    populate_fixture(&fixture);

    ASSERT_EQ(asx_canonical_fixture_validate(&fixture), ASX_OK);
    ASSERT_EQ(asx_codec_encode_fixture(ASX_CODEC_KIND_JSON, &fixture, &json_a), ASX_OK);
    ASSERT_NE(json_a.data, NULL);
    ASSERT_TRUE(json_a.len > 0u);

    ASSERT_EQ(asx_codec_decode_fixture(ASX_CODEC_KIND_JSON, json_a.data, &decoded), ASX_OK);
    ASSERT_STR_EQ(decoded.scenario_id, fixture.scenario_id);
    ASSERT_STR_EQ(decoded.profile, fixture.profile);
    ASSERT_EQ(decoded.seed, fixture.seed);
    ASSERT_EQ(decoded.codec, ASX_CODEC_KIND_JSON);

    ASSERT_EQ(asx_codec_encode_fixture(ASX_CODEC_KIND_JSON, &decoded, &json_b), ASX_OK);
    ASSERT_STR_EQ(json_a.data, json_b.data);

    asx_codec_buffer_reset(&json_b);
    asx_codec_buffer_reset(&json_a);
    asx_canonical_fixture_reset(&decoded);
    asx_canonical_fixture_reset(&fixture);
}

TEST(decode_rejects_missing_required_field) {
    const char *missing_scenario =
        "{"
        "\"codec\":\"json\","
        "\"expected_error_codes\":[],"
        "\"expected_events\":[],"
        "\"expected_final_snapshot\":{},"
        "\"fixture_schema_version\":\"fixture-v1\","
        "\"input\":{\"ops\":[]},"
        "\"profile\":\"ASX_PROFILE_CORE\","
        "\"provenance\":{"
          "\"cargo_lock_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
          "\"capture_run_id\":\"capture-run-0001\","
          "\"rust_baseline_commit\":\"0123456789abcdef0123456789abcdef01234567\","
          "\"rust_toolchain_commit_hash\":\"toolchain-abcdef12\","
          "\"rust_toolchain_host\":\"x86_64-unknown-linux-gnu\","
          "\"rust_toolchain_release\":\"rustc 1.90.0\""
        "},"
        "\"scenario_dsl_version\":\"dsl-v1\","
        "\"seed\":42,"
        "\"semantic_digest\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
        "}";
    asx_canonical_fixture fixture;

    asx_canonical_fixture_init(&fixture);
    ASSERT_EQ(asx_codec_decode_fixture(ASX_CODEC_KIND_JSON, missing_scenario, &fixture),
              ASX_E_INVALID_ARGUMENT);
    asx_canonical_fixture_reset(&fixture);
}

TEST(decode_rejects_invalid_digest_pattern) {
    const char *bad_digest =
        "{"
        "\"codec\":\"json\","
        "\"expected_error_codes\":[],"
        "\"expected_events\":[],"
        "\"expected_final_snapshot\":{},"
        "\"fixture_schema_version\":\"fixture-v1\","
        "\"input\":{\"ops\":[]},"
        "\"profile\":\"ASX_PROFILE_CORE\","
        "\"provenance\":{"
          "\"cargo_lock_sha256\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\","
          "\"capture_run_id\":\"capture-run-0001\","
          "\"rust_baseline_commit\":\"0123456789abcdef0123456789abcdef01234567\","
          "\"rust_toolchain_commit_hash\":\"toolchain-abcdef12\","
          "\"rust_toolchain_host\":\"x86_64-unknown-linux-gnu\","
          "\"rust_toolchain_release\":\"rustc 1.90.0\""
        "},"
        "\"scenario_dsl_version\":\"dsl-v1\","
        "\"scenario_id\":\"scenario.codec.json.001\","
        "\"seed\":42,"
        "\"semantic_digest\":\"sha256:XYZ\""
        "}";
    asx_canonical_fixture fixture;

    asx_canonical_fixture_init(&fixture);
    ASSERT_EQ(asx_codec_decode_fixture(ASX_CODEC_KIND_JSON, bad_digest, &fixture),
              ASX_E_INVALID_ARGUMENT);
    asx_canonical_fixture_reset(&fixture);
}

TEST(replay_key_is_deterministic) {
    asx_canonical_fixture fixture;
    asx_codec_buffer key_a;
    asx_codec_buffer key_b;

    asx_canonical_fixture_init(&fixture);
    asx_codec_buffer_init(&key_a);
    asx_codec_buffer_init(&key_b);

    populate_fixture(&fixture);

    ASSERT_EQ(asx_codec_fixture_replay_key(&fixture, &key_a), ASX_OK);
    ASSERT_EQ(asx_codec_fixture_replay_key(&fixture, &key_b), ASX_OK);
    ASSERT_STR_EQ(key_a.data, key_b.data);

    asx_codec_buffer_reset(&key_b);
    asx_codec_buffer_reset(&key_a);
    asx_canonical_fixture_reset(&fixture);
}

TEST(bin_codec_is_explicitly_unsupported) {
    asx_canonical_fixture fixture;
    asx_codec_buffer out;

    asx_canonical_fixture_init(&fixture);
    asx_codec_buffer_init(&out);
    populate_fixture(&fixture);
    fixture.codec = ASX_CODEC_KIND_BIN;

    ASSERT_EQ(asx_codec_encode_fixture(ASX_CODEC_KIND_BIN, &fixture, &out), ASX_E_INVALID_STATE);
    ASSERT_EQ(asx_codec_decode_fixture(ASX_CODEC_KIND_BIN, "{}", &fixture), ASX_E_INVALID_STATE);

    asx_codec_buffer_reset(&out);
    asx_canonical_fixture_reset(&fixture);
}

int main(void) {
    fprintf(stderr, "=== test_codec_json ===\n");
    RUN_TEST(json_round_trip_is_stable);
    RUN_TEST(decode_rejects_missing_required_field);
    RUN_TEST(decode_rejects_invalid_digest_pattern);
    RUN_TEST(replay_key_is_deterministic);
    RUN_TEST(bin_codec_is_explicitly_unsupported);
    TEST_REPORT();
    return test_failures;
}
