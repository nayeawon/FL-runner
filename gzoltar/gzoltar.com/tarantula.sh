#!/usr/bin/env bash
#
# ------------------------------------------------------------------------------
# This script performs fault-localization on a Java project using the GZoltar
# command line interface either using instrumentation 'at runtime' or 'offline'.
#
# Usage:
# ./run.sh
#     --instrumentation <online|offline>
#     [--help]
#
# Requirements:
# - `java` and `javac` needs to be set and must point to the Java installation.
#
# ------------------------------------------------------------------------------

# SCRIPT_DIR=/Users/nayeawon/Documents/HGU/ISEL/jChecker/dataset/2022-1-HW2-Eng
SCRIPT_DIR=$(cd `dirname ${BASH_SOURCE[0]}` && pwd)

#
# Print error message and exit
#
die() {
  echo "$@" >&2
  exit 1
}

# ------------------------------------------------------------------ Envs & Args

GZOLTAR_VERSION="1.7.2"

# Check whether GZOLTAR_CLI_JAR is set
export GZOLTAR_CLI_JAR="/Users/nayeawon/Documents/HGU/ISEL/jChecker/TRANSFER/gzoltar-1.7.2/lib/gzoltarcli.jar"
[ "$GZOLTAR_CLI_JAR" != "" ] || die "GZOLTAR_CLI is not set!"
[ -s "$GZOLTAR_CLI_JAR" ] || die "$GZOLTAR_CLI_JAR does not exist or it is empty! Please go to '$SCRIPT_DIR/..' and run 'mvn clean install'."

export GZOLTAR_AGENT_RT_JAR="/Users/nayeawon/Documents/HGU/ISEL/jChecker/TRANSFER/gzoltar-1.7.2/lib/gzoltaragent.jar"
[ "$GZOLTAR_AGENT_RT_JAR" != "" ] || die "GZOLTAR_AGENT_RT_JAR is not set!"
[ -s "$GZOLTAR_AGENT_RT_JAR" ] || die "$GZOLTAR_AGENT_RT_JAR does not exist or it is empty! Please go to '$SCRIPT_DIR/..' and run 'mvn clean install'."

USAGE="Usage: ${BASH_SOURCE[0]} --target <student-id> [--help]"
if [ "$#" -eq "0" ]; then
  die "$USAGE"
fi
mod_of_two=$(expr $# % 2)
if [ "$#" -ne "1" ] && [ "$mod_of_two" -ne "0" ]; then
  die "$USAGE"
fi

TARGET=""

while [[ "$1" = --* ]]; do
  OPTION=$1; shift
  case $OPTION in
    (--target)
      TARGET=$1;
      shift;;
    (--help)
      echo "$USAGE";
      exit 0;;
    (*)
      die "$USAGE";;
  esac
done

re="^[0-9]+"
[ "$TARGET" != "" ] || die "$USAGE"
[[ ! "$TARGET" =~ "[0-9]+" ]] || die "$USAGE"

#
# Reset SCRIPT_DIR with TARGET student id
#

SCRIPT_DIR="$SCRIPT_DIR/$TARGET"

#
# Prepare runtime dependencies
#
LIB_DIR="$SCRIPT_DIR/lib"
mkdir -p "$LIB_DIR" || die "Failed to create $LIB_DIR!"
[ -d "$LIB_DIR" ] || die "$LIB_DIR does not exist!"

JUNIT_JAR="$LIB_DIR/junit.jar"
if [ ! -s "$JUNIT_JAR" ]; then
  wget "https://repo1.maven.org/maven2/junit/junit/4.12/junit-4.12.jar" -O "$JUNIT_JAR" || die "Failed to get junit-4.12.jar from https://repo1.maven.org!"
fi
[ -s "$JUNIT_JAR" ] || die "$JUNIT_JAR does not exist or it is empty!"

HAMCREST_JAR="$LIB_DIR/hamcrest-core.jar"
if [ ! -s "$HAMCREST_JAR" ]; then
  wget -np -nv "https://repo1.maven.org/maven2/org/hamcrest/hamcrest-core/1.3/hamcrest-core-1.3.jar" -O "$HAMCREST_JAR" || die "Failed to get hamcrest-core-1.3.jar from https://repo1.maven.org!"
fi
[ -s "$HAMCREST_JAR" ] || die "$HAMCREST_JAR does not exist or it is empty!"

BUILD_DIR="$SCRIPT_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" || die "Failed to create $BUILD_DIR!"

SRC_DIR="$SCRIPT_DIR/src"
TEST_DIR="$SCRIPT_DIR/test"

# ------------------------------------------------------------------------- Main

#
# Compile
#

echo "Compile source and test cases ..."

cd "$SRC_DIR" || die "Failed to change directory to $SRC_DIR!"
javac "./edu/handong/csee/java/hw2/MathDriver.java" -d "$BUILD_DIR" || die "Failed to compile source code!"

cd "$TEST_DIR" || die "Failed to change directory to $TEST_DIR!"
javac -cp $JUNIT_JAR:$BUILD_DIR "./edu/handong/csee/java/hw2/MathDriverTest.java" -d "$BUILD_DIR" || die "Failed to compile test cases!"

cd "$SCRIPT_DIR" || die "Failed to change directory to $SCRIPT_DIR!"

#
# Collect list of unit test cases to run
#

echo "Collect list of unit test cases to run ..."

UNIT_TESTS_FILE="$BUILD_DIR/tests.txt"

java -cp $BUILD_DIR:$JUNIT_JAR:$HAMCREST_JAR:$GZOLTAR_CLI_JAR \
  com.gzoltar.cli.Main listTestMethods $BUILD_DIR \
    --outputFile "$UNIT_TESTS_FILE" \
    --includes "edu.handong.csee.java.hw2.MathDriverTest#*" || die "Collection of unit test cases has failed!"
[ -s "$UNIT_TESTS_FILE" ] || die "$UNIT_TESTS_FILE does not exist or it is empty!"

#
# Collect coverage
#

SER_FILE="$BUILD_DIR/gzoltar.ser"

echo "Perform offline instrumentation ..."

# Backup original classes
BUILD_BACKUP_DIR="$SCRIPT_DIR/.build"
rm -rf "$BUILD_BACKUP_DIR"
mv "$BUILD_DIR" "$BUILD_BACKUP_DIR" || die "Backup of original classes has failed!"
mkdir -p "$BUILD_DIR"

# Perform offline instrumentation
java -cp $BUILD_BACKUP_DIR:$GZOLTAR_AGENT_RT_JAR:$GZOLTAR_CLI_JAR \
  com.gzoltar.cli.Main instrument \
  --outputDirectory "$BUILD_DIR" \
  $BUILD_BACKUP_DIR || die "Offline instrumentation has failed!"

echo "Run each unit test case in isolation ..."

# Run each unit test case in isolation
java -cp $BUILD_DIR:$JUNIT_JAR:$HAMCREST_JAR:$GZOLTAR_AGENT_RT_JAR:$GZOLTAR_CLI_JAR \
  -Dgzoltar-agent.destfile=$SER_FILE \
  -Dgzoltar-agent.output="file" \
  com.gzoltar.cli.Main runTestMethods \
    --testMethods "$UNIT_TESTS_FILE" \
    --offline \
    --collectCoverage || die "Coverage collection has failed!"

# Restore original classes
cp -R $BUILD_BACKUP_DIR/* "$BUILD_DIR" || die "Restore of original classes has failed!"
rm -rf "$BUILD_BACKUP_DIR"


[ -s "$SER_FILE" ] || die "$SER_FILE does not exist or it is empty!"

#
# Create fault localization report
#

echo "Create fault localization report ..."

OUTPUT_DIR="$SCRIPT_DIR/report"

SPECTRA_FILE="$OUTPUT_DIR/tarantula/sfl/txt/spectra.csv"
MATRIX_FILE="$OUTPUT_DIR/tarantula/sfl/txt/matrix.txt"
TESTS_FILE="$OUTPUT_DIR/tarantula/sfl/txt/tests.csv"

java -cp $BUILD_DIR:$JUNIT_JAR:$HAMCREST_JAR:$GZOLTAR_CLI_JAR \
  com.gzoltar.cli.Main faultLocalizationReport \
    --buildLocation "$BUILD_DIR" \
    --granularity "line" \
    --inclPublicMethods \
    --inclStaticConstructors \
    --inclDeprecatedMethods \
    --dataFile "$SER_FILE" \
    --outputDirectory "$OUTPUT_DIR/tarantula" \
    --family "sfl" \
    --formula "tarantula" \
    --metric "entropy" \
    --formatter "txt" || die "Generation of fault-localization report has failed!"

[ -s "$SPECTRA_FILE" ] || die "$SPECTRA_FILE does not exist or it is empty!"
[ -s "$MATRIX_FILE" ] || die "$MATRIX_FILE does not exist or it is empty!"
[ -s "$TESTS_FILE" ] || die "$TESTS_FILE does not exist or it is empty!"

echo "DONE!"
exit 0
