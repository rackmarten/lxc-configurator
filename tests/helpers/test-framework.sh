#!/usr/bin/env bash

TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0

pass() {
  printf '[PASS] %s\n' "$1"
  TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
}

assert_success() {
  local description="$1"
  shift
  if ("$@") >/dev/null 2>&1; then pass "${description}"; else fail "${description}"; fi
}

assert_failure() {
  local description="$1"
  shift
  if ("$@") >/dev/null 2>&1; then fail "${description}"; else pass "${description}"; fi
}

assert_equal() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then pass "${description}"; else fail "${description}: expected '${expected}', got '${actual}'"; fi
}

assert_contains() {
  local description="$1" haystack="$2" needle="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then pass "${description}"; else fail "${description}: missing '${needle}'"; fi
}

assert_file_exists() {
  local description="$1" path="$2"
  if [[ -e "${path}" ]]; then pass "${description}"; else fail "${description}: ${path} does not exist"; fi
}

assert_file_not_exists() {
  local description="$1" path="$2"
  if [[ ! -e "${path}" ]]; then pass "${description}"; else fail "${description}: ${path} exists"; fi
}

finish_tests() {
  printf '\n%d passed, %d failed\n' "${TEST_PASS_COUNT}" "${TEST_FAIL_COUNT}"
  [[ ${TEST_FAIL_COUNT} -eq 0 ]]
}
