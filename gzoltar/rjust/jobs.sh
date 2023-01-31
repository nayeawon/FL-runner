#!/usr/bin/env bash
#
# ------------------------------------------------------------------------------
# This script submits as many jobs (if executed on a cluster) or background
# processes as the number of projects * number of bugs. Each job runs GZoltar on
# a specified D4J project/bug using either manually written test cases or
# automatically generated.
# 
# Usage:
# ./jobs.sh
#   --output_dir <path>
#   [--tool <developer(default)|evosuite|randoop>]
#   [--tests_dir <path>]
#   [--help]
# 
# Note: When tool=evosuite or tool=randoop, this script expects to find the
# automatically generated tests in a tar.bz2 file in the provided `tests_dir`.
# For example, `tests_dir`/Math/1/Math-1f.tar.bz2.
# 
# Environment variables:
# - D4J_HOME            Needs to be set and must point to the Defects4J installation.
# - GZOLTAR_CLI_JAR     Needs to be set and must point to GZoltar command line jar file.
# - GZOLTAR_AGENT_JAR   Needs to be set and must point to GZoltar agent jar file.
# - EVOSUITE_RUNTIME_JAR Needs to be set and must point to EvoSuite runtime jar file. (only required if tool=evosuite)
# 
# ------------------------------------------------------------------------------

SCRIPT_DIR=$(cd `dirname $0` && pwd)
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

# Check whether BLACKLIST_FILE exists
BLACKLIST_FILE="$SCRIPT_DIR/../data/blacklist.csv"
[ -s "$BLACKLIST_FILE" ] || die "$BLACKLIST_FILE file does not exist or it is empty!"

USAGE="Usage: ${BASH_SOURCE[0]} --output_dir <path> [--tool <developer(default)|evosuite|randoop>] [--tests_dir <path>] [help]"
if [ "$#" -ne "1" ] && [ "$#" -gt "6" ]; then
  die "$USAGE"
fi

OUTPUT_DIR=""
TOOL="developer"
TESTS_DIR=""

while [[ "$1" = --* ]]; do
  OPTION=$1; shift
  case $OPTION in
    (--output_dir)
      OUTPUT_DIR=$1;
      shift;;
    (--tool)
      TOOL=$1;
      shift;;
    (--tests_dir)
      TESTS_DIR=$1;
      shift;;
    (--help)
      echo "$USAGE"
      exit 0;;
    (*)
      die "$USAGE";;
  esac
done

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

if [ "$TESTS_DIR" != "" ]; then
  [ -d "$TESTS_DIR" ] || die "$OUTPUT_DIR does not exist!"
fi

# ------------------------------------------------------------------------- Main

for pid in Chart Closure Lang Math Mockito Time; do

  # it cuts out the first line (field) of the commit-db file separated by commas
  for bid in $(cut -f1 -d',' "$D4J_HOME/framework/projects/$pid/commit-db"); do

    # skip if the project/bug is in the blacklist
    if grep -q "^$pid,.*,$bid," "$BLACKLIST_FILE"; then
      continue
    fi
    
    # if the bug id is greate than 1000, check mutants_in_scope.csv
    if [ "$bid" -gt "1000" ]; then
      MUTANTS_IN_SCOPE="$D4J_HOME/framework/projects/$pid/mutants_in_scope.csv"
      # skip if the project/bug is not in the mutants_in_scope.csv
      if ! grep -q "^$pid,.*,$bid$" "$MUTANTS_IN_SCOPE"; then
        continue # not in scope
      fi
    fi

    bid_dir="$OUTPUT_DIR/gzoltars/$pid/$bid"
    zip_file="$bid_dir/gzoltar-files.tar.gz"
    if [ -s "$zip_file" ]; then
      log_file_tmp="/tmp/log_file_tmp_$pid-$bid-$TOOL-$$.txt"
      tar -xf "$zip_file" gzoltars/$pid/$bid/log.txt -O > "$log_file_tmp"
      if [ $? -ne 0 ]; then
        echo "[ERROR] It was not possible to extract 'log.txt' from '$zip_file', therefore a sanity-check on $pid-$bid could not be performed."
      else
        if grep -q "^DONE\!$" "$log_file_tmp" && ! grep -q " No space left on device$" "$log_file_tmp"; then
          # skip pid-bid if it has completed successfully
          rm -f "$log_file_tmp"
          continue
        fi
      fi

      rm -f "$log_file_tmp"
    fi
    rm -f "$zip_file"

    tests_archive=""
    if [ "$TOOL" != "developer" ]; then
      tests_archive="$TESTS_DIR/$pid/$bid/$pid-${bid}f.tar.bz2"
      if [ ! -s "$tests_archive" ]; then
        echo "[WARN] $tests_archive does not exist or it is empty!"
        continue
      fi
    fi

    echo "$pid-$bid"

    # Create pid-bid data dir
    rm -rf "$bid_dir"; mkdir -p "$bid_dir"

    # Init log file
    log_file="$bid_dir/log.txt"
    echo "$pid-$bid" > "$log_file"

    # Create job
    pushd . > /dev/null 2>&1
    cd "$SCRIPT_DIR"
      # _am_I_a_cluster is a function defined in the script "utils.sh"
      if _am_I_a_cluster; then
        qsub -V -N "_$bid-$pid" -l h_rt=16:00:00 -l rmem=8G -e "$log_file" -o "$log_file" -j y \
          "job.sh" --project "$pid" --bug "$bid" --output_dir "$bid_dir" --tool "$TOOL" --tests_archive "$tests_archive"
      else
        timeout --signal=KILL "16h" bash \
          "job.sh" --project "$pid" --bug "$bid" --output_dir "$bid_dir" --tool "$TOOL" --tests_archive "$tests_archive" > "$log_file" 2>&1 &
        _register_background_process $!
        _can_more_jobs_be_submitted
      fi
    popd > /dev/null 2>&1
  done
done

# It might be the case that there are still jobs running
_wait_for_jobs;

echo "All jobs have been submitted!"
exit 0