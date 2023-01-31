#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 
# This script runs GZoltar on a specified D4J project/bug using either manually
# written test cases or automatically generated.
# 
# Usage:
# ./job.sh
#   --project <project_name>
#   --bug <bug_id>
#   --output_dir <path>
#   --tool <developer|evosuite|randoop>
#   [--tests_archive <path>]
#   [--help]
# 
# Environment variables:
# - D4J_HOME            Needs to be set and must point to the Defects4J installation.
# - GZOLTAR_CLI_JAR     Needs to be set and must point to GZoltar command line jar file.
# - GZOLTAR_AGENT_JAR   Needs to be set and must point to GZoltar agent jar file.
# 
# ------------------------------------------------------------------------------

SCRIPT_DIR=`pwd`
# many functions are defined in utils.sh
source "$SCRIPT_DIR/utils.sh" || exit 1

# ------------------------------------------------------------------ Envs & Args

# Check whether D4J_HOME is set
[ "$D4J_HOME" != "" ] || die "D4J_HOME is not set!"
[ -d "$D4J_HOME" ] || die "$D4J_HOME does not exist!"

# Check whether GZOLTAR_CLI_JAR is set
[ "$GZOLTAR_CLI_JAR" != "" ] || die "GZOLTAR_CLI_JAR is not set!"
[ -s "$GZOLTAR_CLI_JAR" ] || die "$GZOLTAR_CLI_JAR does not exist or it is empty!"

# Check whether GZOLTAR_AGENT_JAR is set
[ "$GZOLTAR_AGENT_JAR" != "" ] || die "GZOLTAR_AGENT_JAR is not set!"
[ -s "$GZOLTAR_AGENT_JAR" ] || die "$GZOLTAR_AGENT_JAR does not exist or it is empty!"

USAGE="Usage: ${BASH_SOURCE[0]} --project <project_name> --bug <bug_id> --output_dir <path> --tool <developer|evosuite|randoop> [--tests_archive <path>] [help]"
if [ "$#" -ne "1" ] && [ "$#" -lt "8" ]; then
  die "$USAGE"
fi

PID=""
BID=""
OUTPUT_DIR=""
TOOL=""
TESTS_ARCHIVE=""

while [[ "$1" = --* ]]; do
  OPTION=$1; shift
  case $OPTION in
    (--project)
      PID=$1;
      shift;;
    (--bug)
      BID=$1;
      shift;;
    (--output_dir)
      OUTPUT_DIR=$1;
      shift;;
    (--tool)
      TOOL=$1;
      shift;;
    (--tests_archive)
      TESTS_ARCHIVE=$1;
      shift;;
    (--help)
      echo "$USAGE"
      exit 0;;
    (*)
      die "$USAGE";;
  esac
done

[ "$PID" != "" ] || die "$USAGE"
[ "$BID" != "" ] || die "$USAGE"

[ "$OUTPUT_DIR" != "" ] || die "$USAGE"
[ -d "$OUTPUT_DIR" ] || mkdir -p "$OUTPUT_DIR"

[ "$TOOL" != "" ] || die "$USAGE"
if [ "$TOOL" != "developer" ] && [ "$TOOL" != "evosuite" ] && [ "$TOOL" != "randoop" ]; then
  die "$USAGE"
fi

if [ "$TOOL" == "evosuite" ]; then
  # Check whether EVOSUITE_RUNTIME_JAR is set
  [ "$EVOSUITE_RUNTIME_JAR" != "" ] || die "EVOSUITE_RUNTIME_JAR is not set!"
  [ -s "$EVOSUITE_RUNTIME_JAR" ] || die "$EVOSUITE_RUNTIME_JAR does not exist or it is empty!"
fi

if [ "$TESTS_ARCHIVE" != "" ]; then
  [ -s "$TESTS_ARCHIVE" ] || die "$TESTS_ARCHIVE does not exist!"
fi

LOCAL_TMP_DIR="/tmp/$USER-$PID-$BID-$TOOL-$$"
rm -rf "$LOCAL_TMP_DIR"
mkdir -p "$LOCAL_TMP_DIR" || die

LOCAL_DATA_DIR="$LOCAL_TMP_DIR/gzoltars/$PID/$BID"
mkdir -p "$LOCAL_DATA_DIR" || die

# ------------------------------------------------------------------------- Main

echo "PID: $$"
hostname
java -version

echo ""
echo "[INFO] Run GZoltar on $PID-${BID}b"
# call _run_gzoltar function defined in utils.sh
_run_gzoltar "$PID" "$BID" "$LOCAL_DATA_DIR" "$TOOL" "$TESTS_ARCHIVE"
if [ $? -ne 0 ]; then
  echo "[ERROR] Execution of GZoltar on $PID-${BID}b has failed!"
  rm -rf "$LOCAL_TMP_DIR"
  exit 1
fi

#
# Sanity checks
# designed only for defects4j projects
#

TESTS_FILE="$LOCAL_DATA_DIR/tests"
SPECTRA_FILE="$LOCAL_DATA_DIR/spectra"
MATRIX_FILE="$LOCAL_DATA_DIR/matrix"

echo ""
echo "[INFO] Running a few sanity checks on $PID-${BID}b"
echo ""

if [ "$TOOL" == "developer" ]; then

# 1. Do GZoltar and D4J agree on the number of triggering test cases?

ignore_d4j_list_of_trigger_tests="1" # 0 yes, 1 no

num_triggering_test_cases_gzoltar=$(grep -a ",FAIL," "$TESTS_FILE" | wc -l)
num_triggering_test_cases_d4j=$(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | sort -u | wc -l)

if [ "$num_triggering_test_cases_gzoltar" -ne "$num_triggering_test_cases_d4j" ]; then
  echo "[ERROR] Do GZoltar and D4J agree on the number of triggering test cases? No, D4J: $num_triggering_test_cases_d4j vs GZoltar: $num_triggering_test_cases_gzoltar"
  echo "[DEBUG] D4J triggering test cases:"
  grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | sort -u | cut -f2 -d' '
  echo "[DEBUG] GZoltar triggering test cases:"
  grep -a ",FAIL," "$TESTS_FILE" | cut -f1 -d','

  echo ""
  echo "[INFO] Running each test case annotated by D4J as a trigger test case in isolation"

  tmp_dir=$(_checkout "$PID" "$BID" "b")
  if [ $? -ne 0 ]; then
    echo "[ERROR] Checkout of $PID-${BID}b has failed!"
    rm -rf "$LOCAL_TMP_DIR"
    exit 1
  fi

  pushd . > /dev/null 2>&1
  cd "$tmp_dir"
    "$D4J_HOME/framework/bin/defects4j" compile
    if [ $? -ne 0 ]; then
      echo "[ERROR] Compilation of $PID-${BID}b has failed!"
      rm -rf "$LOCAL_TMP_DIR"
      exit 1
    fi
  popd > /dev/null 2>&1

  pushd . > /dev/null 2>&1
  cd "$tmp_dir"
    while read -r d4j_trigger_test; do
      d4j_trigger_test_name=$(echo "$d4j_trigger_test" | cut -f2 -d' ')
      echo "[DEBUG] Checking $d4j_trigger_test_name annotated by D4J as a trigger test case"

      rm -f "$tmp_dir/failing_tests" && touch "$tmp_dir/failing_tests" && "$D4J_HOME/framework/bin/defects4j" test -t "$d4j_trigger_test_name"
      if [ $? -ne 0 ]; then
        echo "[ERROR] Execution of D4J -- $d4j_trigger_test_name in isolation has failed!"
        rm -rf "$LOCAL_TMP_DIR"
        exit 1
      fi

      trigger_stack_trace_length=$(wc -l "$tmp_dir/failing_tests" | cut -f1 -d' ')
      if [ "$trigger_stack_trace_length" -eq "0" ]; then
        echo "[DEBUG] Test case '$d4j_trigger_test_name' annotated by D4J as a trigger test case does not fail when executed in isolation! Ignoring list of triggering test cases reported by D4J as it does not seem to be consistent for $PID-$BID."
        ignore_d4j_list_of_trigger_tests="0"
        break
      fi
    done < <(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | sort -u)
  popd > /dev/null 2>&1

  echo ""
  echo "[INFO] Running each test case annotated by GZoltar as a failing test case in isolation"

  pushd . > /dev/null 2>&1
  cd "$tmp_dir"
    while read -r gz_trigger_test; do
      gz_trigger_test_name=$(echo "$gz_trigger_test" | cut -f1 -d',' | sed 's/#/::/g')
      echo "[DEBUG] Checking $gz_trigger_test_name annotated by GZoltar as a failing test case"

      rm -f "$tmp_dir/failing_tests" && touch "$tmp_dir/failing_tests" && "$D4J_HOME/framework/bin/defects4j" test -t "$gz_trigger_test_name"
      if [ $? -ne 0 ]; then
        echo "[ERROR] Execution of GZoltar -- $gz_trigger_test_name in isolation has failed!"
        rm -rf "$LOCAL_TMP_DIR"
        exit 1
      fi

      trigger_stack_trace_length=$(wc -l "$tmp_dir/failing_tests" | cut -f1 -d' ')
      if [ "$trigger_stack_trace_length" -eq "0" ]; then
        echo "[ERROR] Test case '$gz_trigger_test_name' annotated by GZoltar as a failing test case does not fail when executed in isolation!"
        rm -rf "$LOCAL_TMP_DIR"
        exit 1
      fi
    done < <(grep -a ",FAIL," "$TESTS_FILE")
  popd > /dev/null 2>&1

  rm -rf "$tmp_dir"

  if [ "$ignore_d4j_list_of_trigger_tests" == "1" ]; then
    echo "[INFO] Do GZoltar and D4J agree on the number of triggering test cases? No, however the list of trigger test cases reported by D4J is correct and the list of failing test cases reported by GZoltar is also correct, which means the set of test cases reported by one tool is a subset of the other!"
  elif [ "$ignore_d4j_list_of_trigger_tests" == "0" ]; then
    echo "[INFO] Do GZoltar and D4J agree on the number of triggering test cases? No, however the list of trigger test cases reported by D4J does not seem to be consistent. (At this point, all failing test cases reported by GZoltar do fail in isolation)"
  fi
else
  echo "[INFO] Do GZoltar and D4J agree on the number of triggering test cases? Yes, D4J: $num_triggering_test_cases_d4j == GZoltar: $num_triggering_test_cases_gzoltar."
fi

# 2. Has GZoltar reported the trigger test cases reported by D4J?

if [ "$ignore_d4j_list_of_trigger_tests" == "1" ]; then
  agree=true
  while read -r trigger_test; do
    class_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f1 -d':')
    unit_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f3 -d':')

    # e.g., org.apache.commons.math.complex.ComplexTest#testMath221,FAIL,3111187,junit.framework.AssertionFailedError:
    if ! grep -a -q -F "$class_test_name#$unit_test_name,FAIL," "$TESTS_FILE"; then
      echo "[ERROR] Triggering test case '$class_test_name#$unit_test_name' has not been reported by GZoltar!"
      agree=false
    fi
  done < <(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | sort -u)

  if [[ $agree == false ]]; then
    if [ "$PID" == "Closure" ]; then
      if [ "$BID" == "13100063" ] || [ "$BID" == "13100064" ] || [ "$BID" == "13100068" ] || [ "$BID" == "13100069" ]; then
        # Some triggering test cases, e.g., com.google.javascript.jscomp.SpecializeModuleTest$SpecializeModuleSpecializationStateTest#testCanFixupFunction,
        # are not in the list of relevant tests and therefore they could not have
        # been executed by GZoltar
        agree=true
        echo "[INFO] Some triggering test cases were not in the list of relevant tests and therefore they could not have been executed by GZoltar."
      fi
    fi
  fi

  if [[ $agree == false ]]; then
    echo "[ERROR] Has GZoltar reported the trigger test cases reported by D4J? No."
    rm -rf "$LOCAL_TMP_DIR"
    exit 1
  else
    echo "[INFO] Has GZoltar reported the trigger test cases reported by D4J? Yes."
  fi
else
  echo "[INFO] Has GZoltar reported the trigger test cases reported by D4J? Check cannot be performed as the list of trigger test cases reported by D4J seems to be inconsistent."
fi

fi # END if [ "$TOOL" == "developer" ]; then

# 3. Has the faulty class(es) been reported?

num_classes_not_reported=0
modified_classes_file="$D4J_HOME/framework/projects/$PID/modified_classes/$BID.src"
while read -r modified_class; do
  echo "[DEBUG] modified_class: $modified_class"
  if grep -q "^$modified_class#" "$SPECTRA_FILE"; then
    echo "[DEBUG] Has '$modified_class' been reported? Yes."
  else
    echo "[DEBUG] Has '$modified_class' been reported? No."
    num_classes_not_reported=$((num_classes_not_reported+1))
  fi
done < <(cat "$modified_classes_file")

if [ "$num_classes_not_reported" -eq "1" ] && [ "$PID" == "Mockito" ] && [ "$BID" == "19" ]; then
  # one of the modified classes of Mockito-19 is an interface without
  # any code. as interfaces with no code have no lines of code in bytecode,
  # GZoltar does not report it in the spectra file
  echo "Mockito-19 excluded from the check on the number of modified classes reported as one modified class is an interface without code to which GZoltar does not report any line."
elif [ "$num_classes_not_reported" -ne "0" ]; then
  echo "[ERROR] Has the faulty class(es) been reported? No."
  rm -rf "$LOCAL_TMP_DIR"
  exit 1
fi

echo "[INFO] Has the faulty class(es) been reported? Yes."

# 4. Does spectra file include at least one buggy-line?

_is_it_a_known_exception "$PID" "$BID"
is_it_a_known_exception="$?" # 0 yes, 1, no, it is not

buggy_lines_file="$SCRIPT_DIR/../analysis/pipeline-scripts/buggy-lines/$PID-$BID.buggy.lines"
[ -s "$buggy_lines_file" ] || die "[ERROR] $buggy_lines_file does not exist or it is empty!"
num_buggy_lines=$(wc -l "$buggy_lines_file" | cut -f1 -d' ')

unrankable_lines_file="$SCRIPT_DIR/../analysis/pipeline-scripts/buggy-lines/$PID-$BID.unrankable.lines"
num_unrankable_lines=0
if [ -f "$unrankable_lines_file" ]; then
  num_unrankable_lines=$(wc -l "$unrankable_lines_file" | cut -f1 -d' ')
fi

candidates_file="$SCRIPT_DIR/../analysis/pipeline-scripts/buggy-lines/$PID-$BID.candidates"

source_code_lines_file="$SCRIPT_DIR/../analysis/pipeline-scripts/source-code-lines/$PID-${BID}b.source-code.lines"
[ -f "$source_code_lines_file" ] || die "[ERROR] $source_code_lines_file does not exist or it is empty!"

source_code_lines_tmp_file="$LOCAL_TMP_DIR/source-code.lines"
cat "$source_code_lines_file" | \
  # Replace / by .
  sed 's/\//./g' | \
  # Remove .java extension
  sed 's/.java#/#/g' > "$source_code_lines_tmp_file" || die

if [ "$is_it_a_known_exception" == "0" ]; then
  echo "[INFO] Does spectra file include at least one buggy-line? It is a known exception therefore check is not performed."
elif [ "$num_buggy_lines" -ne "$num_unrankable_lines" ]; then

  at_least_one_buggy_line_in_spectra_file=false
  while read -r buggy_line; do
    echo "[DEBUG] Buggy line: $buggy_line"
    class_name=$(echo "$buggy_line" | cut -f1 -d'#' | sed 's/.java$//' | tr '/' '.')
    line_number=$(echo "$buggy_line" | cut -f2 -d'#')

    if grep -q ":$class_name#$line_number$" "$source_code_lines_tmp_file"; then
      echo "  [DEBUG] Buggy line '$class_name#$line_number' is part of another line"
      buggy_line=$(grep ":$class_name#$line_number$" "$source_code_lines_tmp_file" | cut -f1 -d':')
      class_name=$(echo "$buggy_line" | cut -f1 -d'#')
      line_number=$(echo "$buggy_line" | cut -f2 -d'#')
    fi
    echo "  [DEBUG] Class name: $class_name"
    echo "  [DEBUG] Line number: $line_number"

    if grep -q "^$class_name#$line_number$" "$SPECTRA_FILE"; then
      echo "  [DEBUG] Buggy line $class_name#$line_number has been reported"
      at_least_one_buggy_line_in_spectra_file=true
      break # break this while loop, as we already know that it
      # is not a false positive
    fi
  done < <(grep -v "FAULT_OF_OMISSION" "$buggy_lines_file")

  if [[ $at_least_one_buggy_line_in_spectra_file == false ]]; then
    # at this point, no buggy line has been found, try to find a
    # suitable candidate line, if any
    if [ -s "$candidates_file" ]; then
      while read -r candidate_line; do
        echo "[DEBUG] Candidate line: $candidate_line"
        candidate=$(echo "$candidate_line" | cut -f2 -d',' | sed 's/.java#/#/' | tr '/' '.')

        if grep -q ":$candidate$" "$source_code_lines_tmp_file"; then
          echo "  [DEBUG] Candidate line '$candidate' is part of another line"
          candidate=$(grep ":$candidate$" "$source_code_lines_tmp_file" | cut -f1 -d':')
        fi
        echo "  [DEBUG] '$candidate'"

        if grep -q "^$candidate$" "$SPECTRA_FILE"; then
          echo "  [DEBUG] Candidate line $candidate has been reported"
          at_least_one_buggy_line_in_spectra_file=true
          break # break this while loop, as we already know that it
          # is not a false positive
        fi
      done < <(cat "$candidates_file")
    fi
  fi

  if [[ $at_least_one_buggy_line_in_spectra_file == false ]]; then
    # last chance to check it
    if [ "$PID" == "Closure" ]; then
      if [ "$BID" == "6900590" ]; then
        if grep -q "^com.google.javascript.jscomp.TypeCheck#1580$" "$SPECTRA_FILE"; then
          echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeCheck#1580 has indeed been reported"
          at_least_one_buggy_line_in_spectra_file=true
        fi
      elif [ "$BID" == "9600528" ]; then
        if grep -q "^com.google.javascript.jscomp.TypeCheck#1408$" "$SPECTRA_FILE"; then
          echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeCheck#1408 has indeed been reported"
          at_least_one_buggy_line_in_spectra_file=true
        fi
      elif [ "$BID" == "11700217" ]; then
        if grep -q "^com.google.javascript.jscomp.TypeValidator#734$" "$SPECTRA_FILE"; then
          echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeValidator#734 has indeed been reported"
          at_least_one_buggy_line_in_spectra_file=true
        fi
      elif [ "$BID" == "11700218" ]; then
        if grep -q "^com.google.javascript.jscomp.TypeValidator#734$" "$SPECTRA_FILE"; then
          echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeValidator#734 has indeed been reported"
          at_least_one_buggy_line_in_spectra_file=true
        fi
      fi
    elif [ "$PID" == "Mockito" ]; then
      if [ "$BID" == "2500018" ]; then
        if grep -q "^org.mockito.internal.stubbing.defaultanswers.ReturnsDeepStubs#88$" "$SPECTRA_FILE"; then
          echo "[DEBUG] Extra candidate org.mockito.internal.stubbing.defaultanswers.ReturnsDeepStubs#88 has indeed been reported"
          at_least_one_buggy_line_in_spectra_file=true
        fi
      fi
    fi
  fi

  if [[ $at_least_one_buggy_line_in_spectra_file == false ]]; then
    echo "[ERROR] Does spectra file include at least one buggy-line? No."
    rm -rf "$LOCAL_TMP_DIR"
    exit 1
  else
    echo "[INFO] Does spectra file include at least one buggy-line? Yes."
  fi
else
  echo "[INFO] Does spectra file include at least one buggy-line? Check cannot be performed as there is not any rankable line."
fi

# 5. Do all test cases cover at least one buggy-line?

if [ "$is_it_a_known_exception" == "0" ]; then
  echo "[INFO] Do all test cases cover at least one buggy-line? It is a known exception therefore check is not performed."
elif [ "$num_buggy_lines" -ne "$num_unrankable_lines" ]; then

  # find out whether all failing test cases cover at least one buggy line
  while read -r test_coverage; do
    false_positive=true

    failing_test_id=$(echo "$test_coverage" | cut -f1 -d':')
    failing_test_name=$(sed "${failing_test_id}q;d" "$TESTS_FILE" | cut -f1 -d',')
    echo "[DEBUG] Test case '$failing_test_name' ($failing_test_id)"

    test_cov_file="$LOCAL_TMP_DIR/$USER-test-$failing_test_id-covered-components-$$.txt"
    echo "$test_coverage" | cut -f2 -d':' | awk '{for (i = 1; i <= NF; ++i) if ($i == 1) print i}' > "$test_cov_file"

    while read -r buggy_line; do
      class_name=$(echo "$buggy_line" | cut -f1 -d'#' | sed 's/.java$//' | tr '/' '.')
      line_number=$(echo "$buggy_line" | cut -f2 -d'#')

      if grep -q ":$class_name#$line_number$" "$source_code_lines_tmp_file"; then
        buggy_line=$(grep ":$class_name#$line_number$" "$source_code_lines_tmp_file" | cut -f1 -d':')
        class_name=$(echo "$buggy_line" | cut -f1 -d'#')
        line_number=$(echo "$buggy_line" | cut -f2 -d'#')
      fi

      if ! grep -q "^$class_name#$line_number$" "$SPECTRA_FILE"; then
        continue
      fi

      spectra_id=$(grep -n "^$class_name#$line_number$" "$SPECTRA_FILE" | cut -f1 -d':')
      echo "  [DEBUG] Spectra id of '$class_name#$line_number' is $spectra_id"

      # Does test case id $failing_test_id touch this buggy line?
      if grep -q "^$spectra_id$" "$test_cov_file"; then
        false_positive=false
        echo "  [DEBUG] it has been covered"
        break # break this while loop, as we already know that it
        # is not a false positive
      fi
    done < <(grep -v "FAULT_OF_OMISSION" "$buggy_lines_file")

    if [[ $false_positive == true ]]; then
      # at this point, no buggy line has been covered, try to find a suitable
      # candidate line, if any
      if [ -s "$candidates_file" ]; then
        while read -r candidate_line; do
          candidate=$(echo "$candidate_line" | cut -f2 -d',' | sed 's/.java#/#/' | tr '/' '.')

          if grep -q ":$candidate$" "$source_code_lines_tmp_file"; then
            candidate=$(grep ":$candidate$" "$source_code_lines_tmp_file" | cut -f1 -d':')
          fi

          if ! grep -q "^$candidate$" "$SPECTRA_FILE"; then
            continue
          fi

          spectra_id=$(grep -n "^$candidate$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "  [DEBUG] Spectra id of candidate '$candidate' is $spectra_id"

          # Does test case id $failing_test_id touch this candidate line?
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            false_positive=false
            echo "  [DEBUG] it has been covered"
            break # break this while loop, as we already know that it
            # is not a false positive
          fi
        done < <(cat "$candidates_file")
      fi
    fi

    if [[ $false_positive == true ]]; then
      # last chance to check it
      if [ "$PID" == "Closure" ]; then
        if [ "$BID" == "6900590" ]; then
          spectra_id=$(grep -n "^com.google.javascript.jscomp.TypeCheck#1580$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "[DEBUG] Spectra id of extra candidate 'com.google.javascript.jscomp.TypeCheck#1580' is $spectra_id"
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeCheck#1580 has indeed been covered"
            false_positive=false
          fi
        elif [ "$BID" == "9600528" ]; then
          spectra_id=$(grep -n "^com.google.javascript.jscomp.TypeCheck#1408$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "[DEBUG] Spectra id of extra candidate 'com.google.javascript.jscomp.TypeCheck#1408' is $spectra_id"
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeCheck#1408 has indeed been covered"
            false_positive=false
          fi
        elif [ "$BID" == "11700217" ]; then
          spectra_id=$(grep -n "^com.google.javascript.jscomp.TypeValidator#734$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "[DEBUG] Spectra id of extra candidate 'com.google.javascript.jscomp.TypeValidator#734' is $spectra_id"
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeValidator#734 has indeed been covered"
            false_positive=false
          fi
        elif [ "$BID" == "11700218" ]; then
          spectra_id=$(grep -n "^com.google.javascript.jscomp.TypeValidator#734$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "[DEBUG] Spectra id of extra candidate 'com.google.javascript.jscomp.TypeValidator#734' is $spectra_id"
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            echo "[DEBUG] Extra candidate com.google.javascript.jscomp.TypeValidator#734 has indeed been covered"
            false_positive=false
          fi
        fi
      elif [ "$PID" == "Mockito" ]; then
        if [ "$BID" == "2500018" ]; then
          spectra_id=$(grep -n "^org.mockito.internal.stubbing.defaultanswers.ReturnsDeepStubs#88$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "[DEBUG] Spectra id of extra candidate 'org.mockito.internal.stubbing.defaultanswers.ReturnsDeepStubs#88' is $spectra_id"
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            echo "[DEBUG] Extra candidate org.mockito.internal.stubbing.defaultanswers.ReturnsDeepStubs#88 has indeed been covered"
            false_positive=false
          fi
        fi
      fi
    fi
    rm -f "$test_cov_file"

    if [[ $false_positive == true ]]; then
      echo "[ERROR] Test case '$failing_test_name' ($failing_test_id) does not cover any buggy line!"
      rm -rf "$LOCAL_TMP_DIR"
      exit 1
    fi
  done < <(grep -n " -$" "$MATRIX_FILE")

  echo "[INFO] Do all test cases cover at least one buggy-line? Yes."
else
  echo "[INFO] Do all test cases cover at least one buggy-line? Check cannot be performed as there is not any rankable line."
fi

#
# Collect and compress data
#

echo ""
echo "[INFO] Collect data & Clean up"

pushd . > /dev/null 2>&1
cd "$LOCAL_TMP_DIR"
  echo "DONE!"

  # get log file so that it can also be in the .tar.gz file
  cp -f "$OUTPUT_DIR/log.txt" "gzoltars/$PID/$BID/" > /dev/null 2>&1

  zip_filename="gzoltar-files.tar.gz"
  tar -czf "$zip_filename" "gzoltars/$PID/$BID/tests" \
                           "gzoltars/$PID/$BID/spectra" \
                           "gzoltars/$PID/$BID/.spectra" \
                           "gzoltars/$PID/$BID/matrix" \
                           "gzoltars/$PID/$BID/gzoltar.ser" \
                           "gzoltars/$PID/$BID/log.txt"
  if [ $? -ne 0 ]; then
    echo "[ERROR] It was not possible to compress directory '$LOCAL_TMP_DIR/gzoltars/'!"

    echo "[INFO] Copying all files from local '$LOCAL_TMP_DIR/gzoltars' to remote '$OUTPUT_DIR' so that anyone can debug them"
    cp -Rv gzoltars/* "$OUTPUT_DIR/"

    popd > /dev/null 2>&1
    rm -rf "$LOCAL_TMP_DIR"
    exit 1
  fi

  cp "$zip_filename" "$OUTPUT_DIR/" > /dev/null 2>&1
  rm -f "$OUTPUT_DIR/log.txt" > /dev/null 2>&1
popd > /dev/null 2>&1

rm -rf "$LOCAL_TMP_DIR" > /dev/null 2>&1 # Clean up
exit 0
