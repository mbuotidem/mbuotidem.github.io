# local-invoke and build do not work on this project because we're using the Docker image style lambdas. 
# Will revisit if https://github.com/aws/aws-sam-cli/issues/6802 changes
# local-invoke:
# 	cd ./infrastructure/environments/qa && \
# 	sam local invoke --hook-name terraform "module.lambda_function.aws_lambda_function.this[0]"
# 	# sam local invoke --hook-name terraform 

# build:
# 	cd ./infrastructure/environments/qa && \
# 	sam build --hook-name terraform "module.lambda_function.aws_lambda_function.this[0]"
# 	# sam build --hook-name terraform --terraform-project-root-path infrastructure/environments/qa


venv: src/requirements-dev.txt src/requirements.txt  ## install all dependecies into .venv
	.venv/bin/pip install -U -r $<
.venv:
	@python_version=$$(python3 --version 2>&1); \
	version_number=$$(printf '%s' "$$python_version" | cut -d' ' -f2); \
	major_version=$$(printf '%s' "$$version_number" | cut -d'.' -f1); \
	minor_version=$$(printf '%s' "$$version_number" | cut -d'.' -f2); \
	if [ $$major_version -ne 3 -o $$minor_version -lt 8 ]; then \
		echo "Insufficient python3 version"; exit 1; \
	fi
	@python3 -m venv .venv
	@.venv/bin/python -m pip install --upgrade pip
	@.venv/bin/pip install -U pip-tools
	@echo "\033[0;32mTo activate the virtual environment, run: source .venv/bin/activate\033[0m"

