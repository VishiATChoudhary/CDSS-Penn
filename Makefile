define DESCRIPTION
Code quality (testing, linting/auto-formatting, etc.) and local execution
orchestration for $(PROJECT_NAME).
endef

#################################################################################
# CONFIGURATIONS                                                                #
#################################################################################

MAKEFLAGS += --warn-undefined-variables
SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:
.SUFFIXES:

#################################################################################
# GLOBALS                                                                       #
#################################################################################

PROJECT_DIR := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
PROJECT_NAME := $(shell basename $(PROJECT_DIR))

# List any changed files (excluding submodules)
CHANGED_FILES := $(shell git diff --name-only)

ifeq ($(strip $(CHANGED_FILES)),)
GIT_VERSION := $(shell git describe --tags --long --always)
else
diff_checksum := $(shell git diff | shasum -a 256 | cut -c -6)
GIT_VERSION := $(shell git describe --tags --long --always --dirty)-$(diff_checksum)
endif
TAG := $(shell date +v%Y%m%d)-$(GIT_VERSION)

# Custom certs may be used on HAS infrastructure and requests needs to be
# aware of them
REQUESTS_CA_BUNDLE := /etc/ssl/certs/ca-certificates.crt
#################################################################################
# HELPER TARGETS                                                                #
#################################################################################

.PHONY: get-make-var-%
get-make-var-%:
	@echo $($*)

# Check that given variables are set and all have non-empty values,
# die with an error otherwise.
#
# Params:
#   1. Variable name(s) to test.
#   2. (optional) Error message to print.
check_defined = \
	$(strip $(foreach 1,$1, \
		$(call __check_defined,$1,$(strip $(value 2)))))
__check_defined = \
	$(if $(value $1),, \
	  $(error Undefined $1$(if $2, ($2))))

.PHONY: validate_req_env_vars
validate_req_env_vars:
	$(call check_defined, REQ_ENV_VARS, Error: Required list of env vars to validate as defined not set!)
	$(foreach REQ_ENV_VAR,$(REQ_ENV_VARS),$(call check_defined, $(REQ_ENV_VAR), Error: Required env var not set!))

.PHONY: strong-version-tag
strong-version-tag: get-make-var-TAG

.PHONY: strong-version-tag-dateless
strong-version-tag-dateless: get-make-var-GIT_VERSION

.PHONY: update-dependencies
## Install Python dependencies,
## updating packages in `poetry.lock` with any newer versions specified in
## `pyproject.toml`, and install caumim source code
update-dependencies:
	poetry update --lock
	poetry install --with documentation

.PHONY: generate-requirements
## Generate project requirements.txt files from `pyproject.toml`
generate-requirements:
	poetry export -f requirements.txt --without-hashes > requirements.txt # subset
	poetry export --dev -f requirements.txt --without-hashes > requirements-dev.txt # superset w/o docs
	poetry export --with documentation --dev -f requirements.txt --without-hashes > requirements-all.txt # superset

.PHONY: clean-requirements
## Clean generated project requirements files
clean-requirements:
	find . -maxdepth 1 -type f -name "requirements*.txt" -delete

.PHONY: clean
## Delete all compiled Python files
clean:
	find . -type f -name "*.py[co]" -delete
	find . -type f -name "*.coverage*" -delete
	find . -type d -name "__pycache__" -delete


#################################################################################
# PYTHON                                                                        #
#################################################################################

# Auto-detect python: prefer pyenv 3.10, then system python3
PYTHON := $(shell \
	if [ -x "$$HOME/.pyenv/versions/3.10.20/bin/python" ]; then \
		echo "$$HOME/.pyenv/versions/3.10.20/bin/python"; \
	elif command -v python3 >/dev/null 2>&1; then \
		echo "python3"; \
	else \
		echo "python"; \
	fi)

# Data directories
DATA_DIR      := $(PROJECT_DIR)/data
MIMIC_CSV     := $(DATA_DIR)/mimiciv/3.1
MIMIC_PARQUET := $(DATA_DIR)/mimiciv_as_parquet
COHORT_DIR    := $(DATA_DIR)/cohort
EXPE_DIR      := $(DATA_DIR)/experiences

#################################################################################
# PIPELINE TARGETS                                                              #
#################################################################################

.PHONY: all
## Run the full pipeline end-to-end (Steps 0-5 + reports)
all: data cohort experiments reports
	@echo "\n=== Full pipeline complete ==="

# ---- Step 0: Data Acquisition ----

.PHONY: parquet
## Convert MIMIC-IV CSV.GZ files to Parquet
parquet:
	@echo "=== Step 0a: CSV → Parquet ==="
	$(PYTHON) scripts/csv_to_parquet.py

.PHONY: derived
## Build MIMIC-IV derived concept tables (SOFA, SAPS-II, sepsis3, etc.)
derived:
	@echo "=== Step 0b: Build derived concepts ==="
	$(PYTHON) scripts/build_derived_concepts.py

.PHONY: consolidate
## Consolidate multi-file parquet dirs into single files (for polars 0.17)
consolidate:
	@echo "=== Step 0c: Consolidate derived parquet files ==="
	$(PYTHON) scripts/consolidate_derived_parquet.py

.PHONY: data
## Run all data preparation steps (CSV to Parquet + derived + consolidate)
data: parquet derived consolidate
	@echo "=== Data preparation complete ==="

# ---- Step 1: Framing (Cohort Construction) ----

.PHONY: cohort
## Build the target trial population (1-day observation window)
cohort:
	@echo "=== Step 1: Building target population ==="
	$(PYTHON) -c "\
from caumim.framing.albumin_for_sepsis import COHORT_CONFIG_ALBUMIN_FOR_SEPSIS, get_population; \
get_population(COHORT_CONFIG_ALBUMIN_FOR_SEPSIS); \
print('Cohort built successfully')"

.PHONY: cohort-3d
## Build the 3-day observation cohort (needed for report 0)
cohort-3d:
	@echo "=== Building 3-day observation cohort ==="
	$(PYTHON) -c "\
from copy import deepcopy; \
from caumim.framing.albumin_for_sepsis import COHORT_CONFIG_ALBUMIN_FOR_SEPSIS, get_population; \
c = deepcopy(COHORT_CONFIG_ALBUMIN_FOR_SEPSIS); \
c['min_icu_survival_unit_day'] = 3; \
c['min_los_icu_unit_day'] = 3; \
c['treatment_observation_window_unit_day'] = 3; \
get_population(c)"

# ---- Steps 3-5: Experiments ----

.PHONY: experiments
## Run all experiments (Steps 3, 4, and 5)
experiments: experiment-sensitivity experiment-immortal experiment-feature-agg experiment-confounders experiment-cate experiment-predictive
	@echo "=== All experiments complete ==="

.PHONY: experiment-sensitivity
## Step 3: Main sensitivity analysis (estimator/aggregation grid)
experiment-sensitivity:
	@echo "=== Step 3: Sensitivity analysis ==="
	$(PYTHON) -m caumim.experiments.sensitivity_albumin_for_sepsis

.PHONY: experiment-immortal
## Step 4a: Immortal time bias analysis
experiment-immortal:
	@echo "=== Step 4a: Immortal time bias ==="
	$(PYTHON) -m caumim.experiments.immortal_time_bias_albumin_for_sepis

.PHONY: experiment-feature-agg
## Step 4b: Feature aggregation sensitivity
experiment-feature-agg:
	@echo "=== Step 4b: Feature aggregation sensitivity ==="
	$(PYTHON) -m caumim.experiments.sensitivity_feature_aggregation_albumin_for_sepsis

.PHONY: experiment-confounders
## Step 4c: Confounder sensitivity
experiment-confounders:
	@echo "=== Step 4c: Confounder sensitivity ==="
	$(PYTHON) -m caumim.experiments.sensitivity_confounders_albumin_for_sepsis

.PHONY: experiment-cate
## Step 5: CATE (treatment heterogeneity) exploration
experiment-cate:
	@echo "=== Step 5: CATE exploration ==="
	$(PYTHON) -m caumim.experiments.cate_exploration_albumin_for_sepsis

.PHONY: experiment-predictive
## Predictive failure experiment (motivational example)
experiment-predictive:
	@echo "=== Predictive failure experiment ==="
	$(PYTHON) -m caumim.experiments.sepsis_mortality_predictive_failure
	$(PYTHON) -c "\
from caumim.framing.albumin_for_sepsis import COHORT_CONFIG_ALBUMIN_FOR_SEPSIS; \
from caumim.experiments.configurations import ESTIMATOR_HGB; \
from caumim.experiments.sepsis_mortality_predictive_failure import train_predictive_failure_experiment; \
train_predictive_failure_experiment(COHORT_CONFIG_ALBUMIN_FOR_SEPSIS, \
    {'observation_period_day': 1, 'train_val_random_seeds': list(range(10)), \
     'experiment_name': 'predictive_failure', 'post_treatment_features': True}, ESTIMATOR_HGB); \
train_predictive_failure_experiment(COHORT_CONFIG_ALBUMIN_FOR_SEPSIS, \
    {'observation_period_day': 1, 'train_val_random_seeds': list(range(10)), \
     'experiment_name': 'predictive_failure', 'post_treatment_features': False}, ESTIMATOR_HGB)"

# ---- Reports ----

.PHONY: reports
## Generate all report figures
reports: cohort-3d
	@echo "=== Generating reports ==="
	$(PYTHON) reports/0_description_albumin_for_sepsis.py
	$(PYTHON) reports/1_sensitivity_albumin_for_sepsis_report.py
	$(PYTHON) reports/3_feature_agg_sensitivity_albumin_for_sepsis_report.py
	$(PYTHON) reports/4_cate_albumin_for_sepsis_report.py
	$(PYTHON) reports/5_prediction_failure_report.py
	$(PYTHON) reports/6_confounder_sensitivity_albumin_for_sepsis_report.py
	@echo "=== Reports complete. Figures in docs/source/_static/img/ ==="

# ---- Utilities ----

.PHONY: clean-cache
## Clear the joblib cache (useful after changing covariate extraction)
clean-cache:
	rm -rf cachedir/joblib
	@echo "Joblib cache cleared"

.PHONY: which-python
## Show which python is being used
which-python:
	@echo "$(PYTHON)"
	@$(PYTHON) --version

#################################################################################
# COMMANDS                                                                      #
#################################################################################

## Installation

.PHONY: provision-environment
## Set up Python environment with pip install -e . (pyenv 3.10 recommended)
provision-environment:
	$(PYTHON) -m pip install -e .

.PHONY: install-pre-commit-hooks
## Install git pre-commit hooks locally
install-pre-commit-hooks:
	poetry run pre-commit install

.PHONY: get-project-version-number
## Echo project's canonical version number
get-project-version-number:
	@poetry version --short




.PHONY: jupyter-notebook
## Launches the jupyter notebook server with the correct config
jupyter-notebook:
	cd notebooks
	poetry run jupyter notebook --config=config.py --notebook-dir=notebooks

## Tests/linting/docs

.PHONY: test
## Test via tox in poetry env
test: clean
	poetry run pytest

.PHONY: coverage
## Test via tox in poetry env
coverage: clean
	poetry run pytest --cov=caumim tests/


.PHONY: lint
## Run full static analysis suite for local development
lint:
	$(MAKE) pre-commit

.PHONY: pre-commit
## Lint using pre-commit hooks (see `.pre-commit-config.yaml`)
pre-commit:
	poetry run pre-commit run --all-files


.PHONY: pre-commit-%
## Lint using a single specific pre-commit hook (see `.pre-commit-config.yaml`)
pre-commit-%: export SKIP= # Reset `SKIP` env var to force single hooks to always run
pre-commit-%:
	poetry run pre-commit run $* --all-files


.PHONY: docs-%
## Build documentation in the format specified after `-`
## e.g.,
## `make docs-html` builds the docs in HTML format,
## `make docs-clean` cleans the docs build directory
docs-%:
	$(MAKE) $* -C docs

.PHONY: test-docs
## Test documentation format/syntax
test-docs:
	poetry run sphinx-build -n -T -W -b html -d tmpdir/doctrees docs/source docs/_build/html
	poetry run sphinx-build -n -T -W -b doctest -d tmpdir/doctrees docs/source docs/_build/html
#################################################################################
# Self Documenting Commands                                                     #
#################################################################################

.PHONY: cp-img
cp-img:
	cp -r docs/source/_static/img/* ~/projets/inria/papiers/causal_inference_tuto/img/caumim

.DEFAULT_GOAL := help

# Inspired by <http://marmelab.com/blog/2016/02/29/auto-documented-makefile.html>
# sed script explained:
# /^##/:
# 	* save line in hold space
# 	* purge line
# 	* Loop:
# 		* append newline + line to hold space
# 		* go to next line
# 		* if line starts with doc comment, strip comment character off and loop
# 	* remove target prerequisites
# 	* append hold space (+ newline) to line
# 	* replace newline plus comments by `---`
# 	* print line
# Separate expressions are necessary because labels cannot be delimited by
# semicolon; see <http://stackoverflow.com/a/11799865/1968>
export DESCRIPTION
.PHONY: help
help:
ifdef DESCRIPTION
	@echo "$$(tput bold)Description:$$(tput sgr0)" && echo "$$DESCRIPTION" && echo
endif
	@echo "$$(tput bold)Available rules:$$(tput sgr0)"
	@echo
	@sed -n -e "/^## / { \
		h; \
		s/.*//; \
		:doc" \
		-e "H; \
		n; \
		s/^## //; \
		t doc" \
		-e "s/:.*//; \
		G; \
		s/\\n## /---/; \
		s/\\n/ /g; \
		p; \
	}" ${MAKEFILE_LIST} \
	| LC_ALL='C' sort --ignore-case \
	| awk -F '---' \
		-v ncol=$$(tput cols) \
		-v indent=19 \
		-v col_on="$$(tput setaf 6)" \
		-v col_off="$$(tput sgr0)" \
	'{ \
		printf "%s%*s%s ", col_on, -indent, $$1, col_off; \
		n = split($$2, words, " "); \
		line_length = ncol - indent; \
		for (i = 1; i <= n; i++) { \
			line_length -= length(words[i]) + 1; \
			if (line_length <= 0) { \
				line_length = ncol - indent - length(words[i]) - 1; \
				printf "\n%*s ", -indent, " "; \
			} \
			printf "%s ", words[i]; \
		} \
		printf "\n"; \
	}' \
	| more $(shell test $(shell uname) = Darwin && echo '--no-init --raw-control-chars')
