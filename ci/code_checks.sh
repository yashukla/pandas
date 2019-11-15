#!/bin/bash
#
# Run checks related to code quality.
#
# This script is intended for both the CI and to check locally that code standards are
# respected. We are currently linting (PEP-8 and similar), looking for patterns of
# common mistakes (sphinx directives with missing blank lines, old style classes,
# unwanted imports...), we run doctests here (currently some files only), and we
# validate formatting error in docstrings.
#
# Usage:
#   $ ./ci/code_checks.sh               # run all checks
#   $ ./ci/code_checks.sh lint          # run linting only
#   $ ./ci/code_checks.sh patterns      # check for patterns that should not exist
#   $ ./ci/code_checks.sh code          # checks on imported code
#   $ ./ci/code_checks.sh doctests      # run doctests
#   $ ./ci/code_checks.sh docstrings    # validate docstring errors
#   $ ./ci/code_checks.sh dependencies  # check that dependencies are consistent
#   $ ./ci/code_checks.sh typing	# run static type analysis

[[ -z "$1" || "$1" == "lint" || "$1" == "patterns" || "$1" == "code" || "$1" == "doctests" || "$1" == "docstrings" || "$1" == "dependencies" || "$1" == "typing" ]] || \
    { echo "Unknown command $1. Usage: $0 [lint|patterns|code|doctests|docstrings|dependencies|typing]"; exit 9999; }

BASE_DIR="$(dirname $0)/.."
RET=0
CHECK=$1

function invgrep {
    # grep with inverse exist status and formatting for azure-pipelines
    #
    # This function works exactly as grep, but with opposite exit status:
    # - 0 (success) when no patterns are found
    # - 1 (fail) when the patterns are found
    #
    # This is useful for the CI, as we want to fail if one of the patterns
    # that we want to avoid is found by grep.
    if [[ "$AZURE" == "true" ]]; then
        set -o pipefail
        grep -n "$@" | awk -F ":" '{print "##vso[task.logissue type=error;sourcepath=" $1 ";linenumber=" $2 ";] Found unwanted pattern: " $3}'
    else
        grep "$@"
    fi
    return $((! $?))
}

if [[ "$AZURE" == "true" ]]; then
    FLAKE8_FORMAT="##vso[task.logissue type=error;sourcepath=%(path)s;linenumber=%(row)s;columnnumber=%(col)s;code=%(code)s;]%(text)s"
else
    FLAKE8_FORMAT="default"
fi

### LINTING ###
if [[ -z "$CHECK" || "$CHECK" == "lint" ]]; then

    echo "black --version"
    black --version

    MSG='Checking black formatting' ; echo $MSG
	black . --check
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # `setup.cfg` contains the list of error codes that are being ignored in flake8

    echo "flake8 --version"
    flake8 --version

    # pandas/_libs/src is C code, so no need to search there.
    MSG='Linting .py code' ; echo $MSG
    flake8 --format="$FLAKE8_FORMAT" .
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Linting .pyx code' ; echo $MSG
    flake8 --format="$FLAKE8_FORMAT" pandas --filename=*.pyx --select=E501,E302,E203,E111,E114,E221,E303,E128,E231,E126,E265,E305,E301,E127,E261,E271,E129,W291,E222,E241,E123,F403,C400,C401,C402,C403,C404,C405,C406,C407,C408,C409,C410,C411
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Linting .pxd and .pxi.in' ; echo $MSG
    flake8 --format="$FLAKE8_FORMAT" pandas/_libs --filename=*.pxi.in,*.pxd --select=E501,E302,E203,E111,E114,E221,E303,E231,E126,F403
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    echo "flake8-rst --version"
    flake8-rst --version

    MSG='Linting code-blocks in .rst documentation' ; echo $MSG
    flake8-rst doc/source --filename=*.rst --format="$FLAKE8_FORMAT"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # Check that cython casting is of the form `<type>obj` as opposed to `<type> obj`;
    # it doesn't make a difference, but we want to be internally consistent.
    # Note: this grep pattern is (intended to be) equivalent to the python
    # regex r'(?<![ ->])> '
    MSG='Linting .pyx code for spacing conventions in casting' ; echo $MSG
    invgrep -r -E --include '*.pyx' --include '*.pxi.in' '[a-zA-Z0-9*]> ' pandas/_libs
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # readability/casting: Warnings about C casting instead of C++ casting
    # runtime/int: Warnings about using C number types instead of C++ ones
    # build/include_subdir: Warnings about prefacing included header files with directory

    # We don't lint all C files because we don't want to lint any that are built
    # from Cython files nor do we want to lint C files that we didn't modify for
    # this particular codebase (e.g. src/headers, src/klib, src/msgpack). However,
    # we can lint all header files since they aren't "generated" like C files are.
    MSG='Linting .c and .h' ; echo $MSG
    cpplint --quiet --extensions=c,h --headers=h --recursive --filter=-readability/casting,-runtime/int,-build/include_subdir pandas/_libs/src/*.h pandas/_libs/src/parser pandas/_libs/ujson pandas/_libs/tslibs/src/datetime pandas/io/msgpack pandas/_libs/*.cpp pandas/util
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    echo "isort --version-number"
    isort --version-number

    # Imports - Check formatting using isort see setup.cfg for settings
    MSG='Check import format using isort ' ; echo $MSG
    isort --recursive --check-only pandas asv_bench
    RET=$(($RET + $?)) ; echo $MSG "DONE"

fi

### PATTERNS ###
if [[ -z "$CHECK" || "$CHECK" == "patterns" ]]; then

    # Check for imports from pandas.core.common instead of `import pandas.core.common as com`
    # Check for imports from collections.abc instead of `from collections import abc`
    MSG='Check for non-standard imports' ; echo $MSG
    invgrep -R --include="*.py*" -E "from pandas.core.common import" pandas
    invgrep -R --include="*.py*" -E "from pandas.core import common" pandas
    invgrep -R --include="*.py*" -E "from collections.abc import" pandas
    invgrep -R --include="*.py*" -E "from numpy import nan" pandas

    # Checks for test suite
    # Check for imports from pandas.util.testing instead of `import pandas.util.testing as tm`
    invgrep -R --include="*.py*" -E "from pandas.util.testing import" pandas/tests
    invgrep -R --include="*.py*" -E "from pandas.util import testing as tm" pandas/tests
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for use of exec' ; echo $MSG
    invgrep -R --include="*.py*" -E "[^a-zA-Z0-9_]exec\(" pandas
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for pytest warns' ; echo $MSG
    invgrep -r -E --include '*.py' 'pytest\.warns' pandas/tests/
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for pytest raises without context' ; echo $MSG
    invgrep -r -E --include '*.py' "[[:space:]] pytest.raises" pandas/tests/
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for python2-style file encodings' ; echo $MSG
    invgrep -R --include="*.py" --include="*.pyx" -E "# -\*- coding: utf-8 -\*-" pandas scripts
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for python2-style super usage' ; echo $MSG
    invgrep -R --include="*.py" -E "super\(\w*, (self|cls)\)" pandas
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # Check for the following code in testing: `np.testing` and `np.array_equal`
    MSG='Check for invalid testing' ; echo $MSG
    invgrep -r -E --include '*.py' --exclude testing.py '(numpy|np)(\.testing|\.array_equal)' pandas/tests/
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # Check for the following code in the extension array base tests: `tm.assert_frame_equal` and `tm.assert_series_equal`
    MSG='Check for invalid EA testing' ; echo $MSG
    invgrep -r -E --include '*.py' --exclude base.py 'tm.assert_(series|frame)_equal' pandas/tests/extension/base
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for deprecated messages without sphinx directive' ; echo $MSG
    invgrep -R --include="*.py" --include="*.pyx" -E "(DEPRECATED|DEPRECATE|Deprecated)(:|,|\.)" pandas
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for python2 new-style classes and for empty parentheses' ; echo $MSG
    invgrep -R --include="*.py" --include="*.pyx" -E "class\s\S*\((object)?\):" pandas asv_bench/benchmarks scripts
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for backticks incorrectly rendering because of missing spaces' ; echo $MSG
    invgrep -R --include="*.rst" -E "[a-zA-Z0-9]\`\`?[a-zA-Z0-9]" doc/source/
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for incorrect sphinx directives' ; echo $MSG
    invgrep -R --include="*.py" --include="*.pyx" --include="*.rst" -E "\.\. (autosummary|contents|currentmodule|deprecated|function|image|important|include|ipython|literalinclude|math|module|note|raw|seealso|toctree|versionadded|versionchanged|warning):[^:]" ./pandas ./doc/source
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    # Check for the following code in testing: `unittest.mock`, `mock.Mock()` or `mock.patch`
    MSG='Check that unittest.mock is not used (pytest builtin monkeypatch fixture should be used instead)' ; echo $MSG
    invgrep -r -E --include '*.py' '(unittest(\.| import )mock|mock\.Mock\(\)|mock\.patch)' pandas/tests/
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for wrong space after code-block directive and before colon (".. code-block ::" instead of ".. code-block::")' ; echo $MSG
    invgrep -R --include="*.rst" ".. code-block ::" doc/source
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for wrong space after ipython directive and before colon (".. ipython ::" instead of ".. ipython::")' ; echo $MSG
    invgrep -R --include="*.rst" ".. ipython ::" doc/source
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check for extra blank lines after the class definition' ; echo $MSG
    invgrep -R --include="*.py" --include="*.pyx" -E 'class.*:\n\n( )+"""' .
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Check that no file in the repo contains trailing whitespaces' ; echo $MSG
    set -o pipefail
    if [[ "$AZURE" == "true" ]]; then
        # we exclude all c/cpp files as the c/cpp files of pandas code base are tested when Linting .c and .h files
        ! grep -n '--exclude=*.'{svg,c,cpp,html,js} --exclude-dir=env -RI "\s$" * | awk -F ":" '{print "##vso[task.logissue type=error;sourcepath=" $1 ";linenumber=" $2 ";] Tailing whitespaces found: " $3}'
    else
        ! grep -n '--exclude=*.'{svg,c,cpp,html,js} --exclude-dir=env -RI "\s$" * | awk -F ":" '{print $1 ":" $2 ":Tailing whitespaces found: " $3}'
    fi
    RET=$(($RET + $?)) ; echo $MSG "DONE"
fi

### CODE ###
if [[ -z "$CHECK" || "$CHECK" == "code" ]]; then

    MSG='Check import. No warnings, and blacklist some optional dependencies' ; echo $MSG
    python -W error -c "
import sys
import pandas

blacklist = {'bs4', 'gcsfs', 'html5lib', 'http', 'ipython', 'jinja2', 'hypothesis',
             'lxml', 'matplotlib', 'numexpr', 'openpyxl', 'py', 'pytest', 's3fs', 'scipy',
             'tables', 'urllib.request', 'xlrd', 'xlsxwriter', 'xlwt'}

# GH#28227 for some of these check for top-level modules, while others are
#  more specific (e.g. urllib.request)
import_mods = set(m.split('.')[0] for m in sys.modules) | set(sys.modules)
mods = blacklist & import_mods
if mods:
    sys.stderr.write('err: pandas should not import: {}\n'.format(', '.join(mods)))
    sys.exit(len(mods))
    "
    RET=$(($RET + $?)) ; echo $MSG "DONE"

fi

### DOCTESTS ###
if [[ -z "$CHECK" || "$CHECK" == "doctests" ]]; then

    MSG='Doctests frame.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/frame.py \
        -k" -itertuples -join -reindex -reindex_axis -round"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests series.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/series.py \
        -k"-nonzero -reindex -searchsorted -to_dict"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests generic.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/generic.py \
        -k"-_set_axis_name -_xs -describe -droplevel -groupby -interpolate -pct_change -pipe -reindex -reindex_axis -to_json -transpose -values -xs -to_clipboard"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests groupby.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/groupby/groupby.py -k"-cumcount -describe -pipe"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests datetimes.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/tools/datetimes.py
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests top-level reshaping functions' ; echo $MSG
    pytest -q --doctest-modules \
        pandas/core/reshape/concat.py \
        pandas/core/reshape/pivot.py \
        pandas/core/reshape/reshape.py \
        pandas/core/reshape/tile.py \
        pandas/core/reshape/melt.py \
        -k"-crosstab -pivot_table -cut"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests interval classes' ; echo $MSG
    pytest -q --doctest-modules \
        pandas/core/indexes/interval.py \
        pandas/core/arrays/interval.py \
        -k"-from_arrays -from_breaks -from_intervals -from_tuples -set_closed -to_tuples -interval_range"
    RET=$(($RET + $?)) ; echo $MSG "DONE"

    MSG='Doctests arrays/string_.py' ; echo $MSG
    pytest -q --doctest-modules pandas/core/arrays/string_.py
    RET=$(($RET + $?)) ; echo $MSG "DONE"

fi

### DOCSTRINGS ###
if [[ -z "$CHECK" || "$CHECK" == "docstrings" ]]; then

    MSG='Validate docstrings (GL03, GL04, GL05, GL06, GL07, GL09, GL10, SS04, SS05, PR03, PR04, PR05, PR10, EX04, RT01, RT04, RT05, SA01, SA02, SA03, SA05)' ; echo $MSG
    $BASE_DIR/scripts/validate_docstrings.py --format=azure --errors=GL03,GL04,GL05,GL06,GL07,GL09,GL10,SS04,SS05,PR03,PR04,PR05,PR10,EX04,RT01,RT04,RT05,SA01,SA02,SA03,SA05
    RET=$(($RET + $?)) ; echo $MSG "DONE"

fi

### DEPENDENCIES ###
if [[ -z "$CHECK" || "$CHECK" == "dependencies" ]]; then

    MSG='Check that requirements-dev.txt has been generated from environment.yml' ; echo $MSG
    $BASE_DIR/scripts/generate_pip_deps_from_conda.py --compare --azure
    RET=$(($RET + $?)) ; echo $MSG "DONE"

fi

### TYPING ###
if [[ -z "$CHECK" || "$CHECK" == "typing" ]]; then

    echo "mypy --version"
    mypy --version

    MSG='Performing static analysis using mypy' ; echo $MSG
    mypy pandas
    RET=$(($RET + $?)) ; echo $MSG "DONE"
fi


exit $RET
